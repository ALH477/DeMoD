-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/selftest.lua — headless asserts for the pure core.
  No dm.* / no display:

      ~/demod-ui/demod-ui patches/demod-pitch-runner/selftest.lua

  Exits non-zero on the first batch of failures.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local INST = dofile(HERE .. "instruments.lua")
local TRK = dofile(HERE .. "track.lua")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

local guitar = INST.by_id("guitar")
local piano = INST.by_id("piano")

-- fret math: open low-E is string 1 / fret 0; one semitone up is fret 1
do
	local f = INST.note_to_fret(guitar, 40)
	check(f and f.string == 1 and f.fret == 0, "guitar midi40 -> string1 fret0")
	local g = INST.note_to_fret(guitar, 41)
	check(g and g.string == 1 and g.fret == 1, "guitar midi41 -> string1 fret1")
	-- midi45 (A2) is fret5 on string1 but open string2 -> lowest position wins
	local a = INST.note_to_fret(guitar, 45)
	check(a and a.string == 2 and a.fret == 0, "guitar midi45 -> string2 fret0 (lowest position)")
	check(INST.note_to_fret(guitar, 39) == nil, "guitar midi39 is off the board")
end

-- ranges + playability
do
	local lo, hi = INST.range(guitar)
	check(lo == 40 and hi == 64 + 15, "guitar range = 40..79")
	check(INST.playable(guitar, 40) and not INST.playable(guitar, 39), "guitar low bound")
	check(INST.playable(guitar, 79) and not INST.playable(guitar, 80), "guitar high bound")
	check(INST.playable(piano, 60) and not INST.playable(piano, 47), "piano range bound")
	check(INST.lanes(guitar) == 6, "guitar has 6 lanes (strings)")
	check(INST.lanes(piano) == 5, "keyboard instruments use 5 register bands")
end

-- generation: deterministic, in-scale, in-range, lanes valid
do
	local maj = { steps = { 0, 2, 4, 5, 7, 9, 11 } }
	local a = TRK.generate(7, { profile = guitar, scale = maj, root = 48, bars = 8 })
	local b = TRK.generate(7, { profile = guitar, scale = maj, root = 48, bars = 8 })
	check(#a > 0, "generate produced notes")
	local same = #a == #b
	for i = 1, #a do
		if a[i].note ~= b[i].note or a[i].beat ~= b[i].beat or a[i].lane ~= b[i].lane then
			same = false
		end
	end
	check(same, "generate is deterministic for a fixed seed")

	local inscale = {}
	for _, s in ipairs(maj.steps) do
		inscale[s % 12] = true
	end
	local lo, hi = INST.range(guitar)
	local ok_scale, ok_range, ok_lane, ok_mono = true, true, true, true
	local last = -1
	for _, n in ipairs(a) do
		if not inscale[(n.note - 48) % 12] then
			ok_scale = false
		end
		if n.note < lo or n.note > hi then
			ok_range = false
		end
		if n.lane < 0 or n.lane > INST.lanes(guitar) - 1 then
			ok_lane = false
		end
		if n.beat < last then
			ok_mono = false
		end
		last = n.beat
	end
	check(ok_scale, "every generated note is in scale")
	check(ok_range, "every generated note is in the instrument range")
	check(ok_lane, "every lane is within 0..lanes-1")
	check(ok_mono, "beats are monotonic non-decreasing")
end

-- judging: timing-only (PRACTICE) and combined (PERFORM)
do
	check(TRK.judge(0, nil, 120) == "perfect", "PRACTICE exact = perfect")
	check(TRK.judge(0.15, nil, 120) == "good", "PRACTICE 0.075s = good")
	check(TRK.judge(0.5, nil, 120) == "miss", "PRACTICE 0.25s = miss")
	check(TRK.judge(0, 5, 120) == "perfect", "PERFORM on-time + in-tune = perfect")
	check(TRK.judge(0, 30, 120) == "good", "PERFORM on-time + slightly off = good")
	check(TRK.judge(0, 60, 120) == "miss", "PERFORM on-time but very out of tune = miss")
	check(TRK.judge(0.15, 5, 120) == "good", "PERFORM good-timing caps at good")
end

if fails == 0 then
	print("pitch-runner selftest: ALL PASS")
	os.exit(0)
else
	io.stderr:write("pitch-runner selftest: " .. fails .. " FAILED\n")
	os.exit(1)
end
