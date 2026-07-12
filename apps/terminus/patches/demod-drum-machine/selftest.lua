-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/selftest.lua — headless asserts for the pure core.
  No dm.* / no display:

      ~/demod-ui/demod-ui patches/demod-drum-machine/selftest.lua

  Exits non-zero on any failure.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local Pattern = dofile(HERE .. "pattern.lua")
local VOICES = dofile(HERE .. "voices.lua")
local SMF = dofile(HERE .. "../../midi/smf.lua")
local midi = dofile(HERE .. "../../midi/init.lua")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

local function approx(a, b)
	return math.abs(a - b) < 1e-6
end

-- voice table integrity: 8 voices, distinct gate indices, plausible bounds
do
	check(VOICES.count == 8, "8 voices")
	local seen = {}
	for i, v in ipairs(VOICES.list) do
		check(v.short and #v.short <= 4, "voice " .. i .. " short tag <=4 chars")
		check(v.gate and v.gate >= 0 and v.gate <= 36, "voice " .. i .. " gate idx in 0..36")
		check(not seen[v.gate], "voice " .. i .. " gate idx is unique")
		seen[v.gate] = true
		check(v.note and v.note >= 0 and v.note <= 127, "voice " .. i .. " GM note in range")
		check(VOICES[v.accent] == nil, "accent is a token, not a stray field") -- sanity
	end
end

-- toggle / set / clear
do
	local p = Pattern.new(8, 16, 4)
	check(not p:cell(1, 1).on, "fresh cell off")
	p:toggle(1, 1)
	check(p:cell(1, 1).on, "toggle turns on")
	check(approx(p:cell(1, 1).vel, Pattern.VEL[3]), "toggle-on defaults to hi vel")
	p:toggle(1, 1)
	check(not p:cell(1, 1).on, "toggle turns off")
	p:set(2, 5, true, 0.5)
	check(p:cell(2, 5).on and approx(p:cell(2, 5).vel, 0.5), "set with vel")
	p:clear()
	check(not p:cell(2, 5).on, "clear empties active bank")
end

-- velocity cycle only affects on-cells, and cycles through the 3 levels
do
	local p = Pattern.new(8, 16, 4)
	p:cycle_vel(1, 1)
	check(not p:cell(1, 1).on, "cycle_vel leaves an off cell off")
	p:set(1, 1, true, Pattern.VEL[1])
	p:cycle_vel(1, 1)
	check(approx(p:cell(1, 1).vel, Pattern.VEL[2]), "lo -> med")
	p:cycle_vel(1, 1)
	check(approx(p:cell(1, 1).vel, Pattern.VEL[3]), "med -> hi")
	p:cycle_vel(1, 1)
	check(approx(p:cell(1, 1).vel, Pattern.VEL[1]), "hi -> lo (wrap)")
end

-- banks are independent
do
	local p = Pattern.new(8, 16, 4)
	p:set_bank(1)
	p:toggle(1, 1)
	p:set_bank(2)
	check(not p:cell(1, 1).on, "bank B does not see bank A edits")
	p:set_bank(1)
	check(p:cell(1, 1).on, "bank A retained its edit")
end

-- transport: step_dur + advance step boundaries
do
	local p = Pattern.new(8, 16, 4)
	p:set_bpm(120)
	check(approx(p:step_dur(), 0.125), "120bpm/4spb -> 0.125s per step")
	-- not playing: no fires
	check(#p:advance(1.0) == 0, "stopped transport fires nothing")
	p:start()
	check(p.pos == 15, "start parks playhead so first advance lands on step 0")
	local f = p:advance(0.125)
	check(#f == 1 and f[1] == 0, "one step boundary -> enters step 0")
	local f2 = p:advance(0.124)
	check(#f2 == 0, "sub-step dt fires nothing")
	local f3 = p:advance(0.30) -- ~2.4 steps accumulated
	check(#f3 >= 2, "a large dt can cross multiple steps")
end

-- hits_at reports the on-voices at a step
do
	local p = Pattern.new(8, 16, 4)
	p:set(1, 1, true, 0.8)
	p:set(3, 1, true, 0.5)
	local h = p:hits_at(0) -- 0-based step 0 == column 1
	check(#h == 2, "two voices on at step 1")
	local notes = { [h[1].v] = true, [h[2].v] = true }
	check(notes[1] and notes[3], "the right voices fired")
end

-- serialize round-trips the whole grid + survives velocity
do
	local p = Pattern.new(8, 16, 4)
	for v, steps in pairs(VOICES.default_groove()) do
		for _, st in ipairs(steps) do
			p:set(v, st, true, Pattern.VEL[2])
		end
	end
	p:set_bank(3)
	p:set(8, 16, true, Pattern.VEL[1])
	p:set_bank(1)
	local str = p:serialize()
	local q = Pattern.new(8, 16, 4):deserialize(str)
	local ok = true
	for b = 1, 4 do
		for v = 1, 8 do
			for s = 1, 16 do
				local a, c = p.banks[b][v][s], q.banks[b][v][s]
				if a.on ~= c.on or (a.on and not approx(a.vel, c.vel)) then
					ok = false
				end
			end
		end
	end
	check(ok, "serialize -> deserialize is lossless across banks/velocity")
end

-- GM note → voice map + live MIDI parse
do
	check(VOICES.gm_to_voice(36) == 1, "GM 36 -> KICK")
	check(VOICES.gm_to_voice(38) == 2, "GM 38 -> SNARE")
	check(VOICES.gm_to_voice(42) == 4, "GM 42 -> CLOSED HAT")
	check(VOICES.gm_to_voice(43) == 6, "GM 43 (tom) -> TOM")
	check(VOICES.gm_to_voice(60) == nil, "GM 60 (non-drum) unmapped")

	-- Live MIDI now decodes through the shared subsystem; verify decode + the GM
	-- fold via a captured event (the drum machine maps note→voice with gm_to_voice).
	local last
	midi.on_note(function(ev)
		last = ev
	end)
	midi.dispatch(0x90, 36, 100)
	check(
		last.kind == "note_on" and VOICES.gm_to_voice(last.note) == 1 and math.abs(last.vel - 100 / 127) < 1e-9,
		"note_on -> KICK vel"
	)
	midi.dispatch(0x90, 36, 0)
	check(last.kind == "note_off" and VOICES.gm_to_voice(last.note) == 1, "note_on vel0 -> note_off")
	midi.dispatch(0x80, 38, 0)
	check(last.kind == "note_off" and VOICES.gm_to_voice(last.note) == 2, "note_off -> SNARE")
	last = nil
	midi.dispatch(0xB0, 7, 100)
	check(last == nil, "control change is not a note")
	midi.dispatch(0x90, 60, 100)
	check(last.kind == "note_on" and VOICES.gm_to_voice(last.note) == nil, "unmapped note has no voice")
end

-- SMF export → import round-trips the on-cells (velocity within quantization)
do
	local p = Pattern.new(VOICES.count, 16, 4)
	p:set_bpm(140)
	local want = {
		{ 1, 1, Pattern.VEL[3] },
		{ 1, 9, Pattern.VEL[1] },
		{ 2, 5, Pattern.VEL[2] },
		{ 4, 3, Pattern.VEL[3] },
		{ 8, 16, Pattern.VEL[2] },
	}
	for _, w in ipairs(want) do
		p:set(w[1], w[2], true, w[3])
	end
	local tmp = os.tmpname()
	local ok = SMF.export(tmp, p, VOICES)
	check(ok, "SMF export succeeded")
	local iok, res = SMF.import(tmp, VOICES)
	os.remove(tmp)
	check(iok and res, "SMF import succeeded")
	if res then
		check(res.bpm == 140, "tempo round-trips (140 bpm)")
		-- build a lookup of imported hits
		local got = {}
		for _, h in ipairs(res.hits) do
			got[h.v .. ":" .. h.s] = h.vel
		end
		local n = 0
		for _ in pairs(got) do
			n = n + 1
		end
		check(n == #want, "same number of on-cells round-tripped (" .. n .. ")")
		local allok = true
		for _, w in ipairs(want) do
			local g = got[w[1] .. ":" .. w[2]]
			if not g or math.abs(g - w[3]) > 1 / 32 then
				allok = false
			end
		end
		check(allok, "every on-cell round-trips at the right voice/step/velocity")
	end
end

if fails == 0 then
	print("drum-machine selftest: ALL PASS")
	os.exit(0)
else
	io.stderr:write("drum-machine selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
