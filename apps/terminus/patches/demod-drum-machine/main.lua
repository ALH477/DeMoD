-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/main.lua — DRUM MACHINE: a step sequencer.

  The proven per-voice horizontal grid (8 voices x 16 steps) on the demod-ui
  framebuffer: 4-step group shading, a downbeat marker, an animated playhead,
  velocity drawn as brightness + a height bar, and a soft-button transport row.

  One linear FOCUS FIELD spans every grid cell then the transport buttons, so a
  bare rotary encoder (prev/next/activate) reaches everything; gamepad/keyboard
  additionally get tab/tab_prev as a voice/button accelerator and a secondary
  action (X / "wet") to cycle a step's velocity.

  Audio is a real demod-drums kit when one is loaded (per-voice gate triggers),
  else GM-note playback through the gamekit bridge, else fully visual. Pure model
  + transport live in pattern.lua; the voice/gate table in voices.lua.

  Three ways to drive it: the focus field (encoder/keyboard/gamepad/touch), a
  live MIDI controller (on_midi → GM notes mapped to voices; LIVE mode records),
  and a saved-beats library of .mid files (the BEATS menu, also a .mid importer).

  Env hooks: DEMOD_DM_PLAY=1 start playing, DEMOD_DM_BANK=A..D,
  DEMOD_DM_MODE=STEP|LIVE, DEMOD_DM_FOCUS=bar|grid, DEMOD_DM_SCREEN=beats,
  DEMOD_DM_MIDI=<rawmidi/fifo> open a controller, DEMOD_DM_IMPORT=<file.mid>
  load a beat on boot. (Framework also auto-opens DEMOD_MIDI.)

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local K = dofile(HERE .. "../games/gamekit.lua")
local Pattern = dofile(HERE .. "pattern.lua")
local VOICES = dofile(HERE .. "voices.lua")
local Audio = dofile(HERE .. "audio.lua")
local midi = dofile(HERE .. "../../midi/init.lua") -- shared MIDI subsystem (owns on_midi)
local SMF = dofile(HERE .. "../../midi/smf.lua") -- shared SMF importer/exporter
local Beats = dofile(HERE .. "beats.lua")
Beats.init(SMF, VOICES)

local floor, max, min = math.floor, math.max, math.min
local COL = K.COL
local NV, NS, NB = VOICES.count, 16, 4
local SAVE_ID = "demod-drum-machine"

-- resolve a voice's accent token to an actual color
local function acc(v)
	return COL[VOICES.list[v].accent] or COL.turq
end

-- ── transport button set ─────────────────────────────────────────────────────
local BTN = { "play", "bpmdn", "bpmup", "mode", "bank", "clear", "beats", "smp" }
local NBTN = #BTN

-- ── state ────────────────────────────────────────────────────────────────────
local pat = Pattern.new(NV, NS, NB)
local audio = nil -- opened lazily once dm/dsp are live
local S = {
	t = 0,
	screen = "grid", -- grid | beats | samples
	mode = "STEP", -- STEP | LIVE
	region = "grid", -- grid | bar
	fi = 1, -- 1..NV*NS in grid; structured below
	bsel = 1, -- focused button index when region=="bar"
	v = 1, -- focused voice (grid)
	s = 1, -- focused step (grid)
	flash = {}, -- per-voice trigger flash level for the row header
	beats = {}, -- cached saved-beat names (BEATS screen)
	bidx = 0, -- BEATS cursor: 0 = "save current", 1..#beats = a beat
	samples = {}, -- voice index -> bound library sample id (sampler mode)
	smap_applied = false, -- pushed S.samples into the audio bridge yet?
	smplib = {}, -- cached library list (SAMPLES picker)
	sidx = 0, -- SAMPLES cursor: 0 = "no sample", 1..N = a library sample
	smp_target = 1, -- voice the picker is assigning to
	msg = nil, -- transient status line
	msg_t = 0,
}

local BANK_NAME = { "A", "B", "C", "D" }
local function bank_index(name)
	for i, n in ipairs(BANK_NAME) do
		if n == name then
			return i
		end
	end
	return 1
end

-- ── persistence ──────────────────────────────────────────────────────────────
local function smap_serialize()
	local out = {}
	for v, id in pairs(S.samples) do
		out[#out + 1] = v .. "=" .. id
	end
	return table.concat(out, ",")
end

local function persist()
	K.save(SAVE_ID, {
		bpm = pat.bpm,
		bank = pat.bank,
		mode = S.mode,
		data = pat:serialize(),
		samples = smap_serialize(),
	})
end

local function load_or_seed()
	local d = K.load(SAVE_ID)
	if type(d.data) == "string" and #d.data > 0 then
		pat:deserialize(d.data)
		if tonumber(d.bpm) then
			pat:set_bpm(tonumber(d.bpm))
		end
		if tonumber(d.bank) then
			pat:set_bank(tonumber(d.bank))
		end
		if d.mode == "LIVE" or d.mode == "STEP" then
			S.mode = d.mode
		end
		if type(d.samples) == "string" then
			for v, id in d.samples:gmatch("(%d+)=([^,]+)") do
				S.samples[tonumber(v)] = id
			end
		end
	else
		-- stamp the default demo groove into bank A
		for v, steps in pairs(VOICES.default_groove()) do
			for _, st in ipairs(steps) do
				pat:set(v, st, true, Pattern.VEL[3])
			end
		end
	end
end

-- ── focus helpers ────────────────────────────────────────────────────────────
local function sync_grid_from_vs()
	S.v = max(1, min(NV, S.v))
	S.s = max(1, min(NS, S.s))
	S.fi = (S.v - 1) * NS + S.s
end

-- linear ring step (encoder-friendly): walk all cells then all buttons
local function ring_step(dir)
	local total = NV * NS + NBTN
	if S.region == "grid" then
		local cur = (S.v - 1) * NS + S.s
		local nxt = ((cur - 1 + dir) % total) + 1
		if nxt <= NV * NS then
			S.region = "grid"
			S.v = floor((nxt - 1) / NS) + 1
			S.s = (nxt - 1) % NS + 1
		else
			S.region = "bar"
			S.bsel = nxt - NV * NS
		end
	else
		local cur = NV * NS + S.bsel
		local nxt = ((cur - 1 + dir) % total) + 1
		if nxt <= NV * NS then
			S.region = "grid"
			S.v = floor((nxt - 1) / NS) + 1
			S.s = (nxt - 1) % NS + 1
		else
			S.region = "bar"
			S.bsel = nxt - NV * NS
		end
	end
end

-- tab accelerator: jump voice-row in the grid / button in the bar; cross over
-- at the edges so directional pads still reach every region.
local function tab_step(dir)
	if S.region == "grid" then
		local nv = S.v + dir
		if nv < 1 then
			S.region = "bar"
			S.bsel = NBTN
		elseif nv > NV then
			S.region = "bar"
			S.bsel = 1
		else
			S.v = nv
		end
	else
		local nb = S.bsel + dir
		if nb < 1 then
			S.region = "grid"
			S.v, S.s = NV, S.s
		elseif nb > NBTN then
			S.region = "grid"
			S.v, S.s = 1, S.s
		else
			S.bsel = nb
		end
	end
end

local function set_msg(m)
	S.msg = m
	S.msg_t = 2.0
end

-- stamp a set of imported hits ({v,s,vel}) onto the active bank
local function apply_hits(res, replace)
	if not res then
		return
	end
	if replace then
		pat:clear()
	end
	for _, h in ipairs(res.hits) do
		pat:set(h.v, h.s, true, h.vel)
	end
	if tonumber(res.bpm) then
		pat:set_bpm(res.bpm)
	end
	persist()
end

-- ── BEATS library menu ────────────────────────────────────────────────────────
local function refresh_beats()
	S.beats = Beats.list()
	if S.bidx > #S.beats then
		S.bidx = #S.beats
	end
	if S.bidx < 0 then
		S.bidx = 0
	end
end

local function enter_beats()
	S.screen = "beats"
	S.bidx = 0
	refresh_beats()
end

local function nav_beats(action)
	local n = #S.beats
	if action == "next" or action == "tab" then
		S.bidx = (S.bidx + 1) % (n + 1)
	elseif action == "prev" or action == "tab_prev" then
		S.bidx = (S.bidx - 1) % (n + 1)
	elseif action == "back" then
		S.screen = "grid"
	elseif action == "activate" then
		if S.bidx == 0 then -- save current bank as a new .mid
			local name = Beats.save_new(pat)
			refresh_beats()
			if name then
				set_msg("saved " .. name .. ".mid")
				for i, nm in ipairs(S.beats) do
					if nm == name then
						S.bidx = i
					end
				end
			else
				set_msg("save failed")
			end
		else
			local nm = S.beats[S.bidx]
			local ok, res = Beats.load(nm)
			if ok then
				apply_hits(res, true)
				set_msg("loaded " .. nm)
				S.screen = "grid" -- back to the grid to play it
			else
				set_msg("load failed: " .. tostring(res))
			end
		end
	elseif action == "wet" then -- secondary: delete the focused beat
		if S.bidx >= 1 and S.beats[S.bidx] then
			local nm = S.beats[S.bidx]
			Beats.delete(nm)
			set_msg("deleted " .. nm)
			refresh_beats()
		end
	end
end

-- ── SAMPLES picker (bind a library sample to the focused voice) ────────────────
local function enter_samples(v)
	S.screen = "samples"
	S.smp_target = v
	S.sidx = 0
	S.smplib = (audio and audio.lib_list) and audio.lib_list() or {}
	-- start the cursor on the currently-bound sample if any
	local cur = S.samples[v]
	if cur then
		for i, m in ipairs(S.smplib) do
			if m.id == cur then
				S.sidx = i
			end
		end
	end
end

local function nav_samples(action)
	local n = #S.smplib
	local v = S.smp_target
	if action == "next" or action == "tab" then
		S.sidx = (S.sidx + 1) % (n + 1)
	elseif action == "prev" or action == "tab_prev" then
		S.sidx = (S.sidx - 1) % (n + 1)
	elseif action == "back" then
		S.screen = "grid"
	elseif action == "activate" then
		if S.sidx == 0 then -- unbind: voice plays its kit/note sound again
			S.samples[v] = nil
			if audio then
				audio.bind(v, nil)
			end
			set_msg(VOICES.list[v].short .. " -> kit")
		else
			local m = S.smplib[S.sidx]
			S.samples[v] = m.id
			if audio then
				audio.bind(v, m.id)
			end
			set_msg(VOICES.list[v].short .. " -> " .. (m.name or m.id))
		end
		persist()
		S.screen = "grid"
	end
end

-- ── actions ──────────────────────────────────────────────────────────────────
local function trigger(v, vel) -- fire a voice now (live preview / playback)
	if audio then
		audio.fire(v, vel)
	end
	S.flash[v] = 1.0
end

local function nearest_playstep()
	-- quantize the live tap to the closest step to the playhead position
	local frac = pat.acc / pat:step_dur() -- 0..1 into the current step
	local s0 = pat.pos
	if frac > 0.5 then
		s0 = (pat.pos + 1) % NS
	end
	return s0 + 1
end

local function do_activate()
	if S.region == "grid" then
		if S.mode == "LIVE" and pat.playing then
			local st = nearest_playstep()
			pat:set(S.v, st, true, Pattern.VEL[3])
			trigger(S.v, Pattern.VEL[3])
		else
			pat:toggle(S.v, S.s)
			local c = pat:cell(S.v, S.s)
			if c and c.on then
				trigger(S.v, c.vel)
			end
		end
		persist()
		return
	end
	-- bar buttons
	local id = BTN[S.bsel]
	if id == "play" then
		if pat.playing then
			pat:stop()
		else
			pat:start()
		end
	elseif id == "bpmdn" then
		pat:set_bpm(pat.bpm - 5)
		persist()
	elseif id == "bpmup" then
		pat:set_bpm(pat.bpm + 5)
		persist()
	elseif id == "mode" then
		S.mode = (S.mode == "STEP") and "LIVE" or "STEP"
		persist()
	elseif id == "bank" then
		pat:set_bank((pat.bank % NB) + 1)
		persist()
	elseif id == "clear" then
		pat:clear()
		persist()
	elseif id == "beats" then
		enter_beats()
	elseif id == "smp" then
		enter_samples(S.v)
	end
end

local function do_secondary() -- X / "wet": velocity nudge on the focused cell
	if S.region == "grid" then
		pat:cycle_vel(S.v, S.s)
		local c = pat:cell(S.v, S.s)
		if c and c.on then
			trigger(S.v, c.vel)
		end
		persist()
	end
end

-- ── input funnel ─────────────────────────────────────────────────────────────
local function nav(action)
	if S.screen == "beats" then
		nav_beats(action)
		dm.redraw()
		return
	end
	if S.screen == "samples" then
		nav_samples(action)
		dm.redraw()
		return
	end
	if action == "next" then
		ring_step(1)
	elseif action == "prev" then
		ring_step(-1)
	elseif action == "tab" then
		tab_step(1)
	elseif action == "tab_prev" then
		tab_step(-1)
	elseif action == "activate" then
		do_activate()
	elseif action == "wet" then
		do_secondary()
	elseif action == "back" then
		if dm.quit then
			dm.quit()
		end
	end
	if S.region == "grid" then
		sync_grid_from_vs()
	end
	dm.redraw()
end

function on_nav(action)
	nav(action)
end

-- Live MIDI is handled by the shared subsystem (midi.on_note), wired up in the
-- boot section below once trigger()/persist() are in scope. The global on_midi is
-- owned by midi/init.lua — defining our own here would clobber the router.

function on_input(evt, btn, val)
	if evt == "ENC_CW" or evt == "ENC_ACCEL_CW" then
		nav("next")
	elseif evt == "ENC_CCW" or evt == "ENC_ACCEL_CCW" then
		nav("prev")
	elseif evt == "DOWN" then
		if btn == "NAV_BACK" then
			nav("back")
		elseif btn == "NAV_OK" or btn == "ENC_PUSH" then
			nav("activate")
		elseif btn == "NAV_PREV" then
			nav("prev")
		elseif btn == "NAV_NEXT" then
			nav("next")
		elseif btn == "NAV_UP" then
			nav("tab_prev")
		elseif btn == "NAV_DOWN" then
			nav("tab")
		end
	end
	dm.redraw()
end

-- ── layout (responsive) ──────────────────────────────────────────────────────
local function bucket(W, H)
	if W < 540 or H < 380 then
		return "compact"
	elseif W < 960 then
		return "standard"
	end
	return "wide"
end

local function compute()
	local W, H = dm.width(), dm.height()
	local bk = bucket(W, H)
	local top = 24
	local barh = (bk == "compact") and 44 or 54
	local lblW = (bk == "compact") and 40 or (bk == "wide" and 60 or 48)
	local mpad = (bk == "compact") and 4 or 10
	local gy = top + ((bk == "compact") and 2 or 6)
	local barY = H - barh
	local gx = lblW
	local gw = W - lblW - mpad
	local gh = barY - gy - ((bk == "compact") and 2 or 6)
	return {
		W = W,
		H = H,
		bk = bk,
		top = top,
		lblW = lblW,
		gx = gx,
		gy = gy,
		gw = gw,
		gh = gh,
		cw = gw / NS,
		ch = gh / NV,
		barY = barY,
		barh = barh,
		infoH = 16,
	}
end

-- ── draw ─────────────────────────────────────────────────────────────────────
local function draw_grid(L)
	local cw, ch = L.cw, L.ch
	-- 4-step group background shading + downbeat marker
	for s = 1, NS do
		local cx = L.gx + (s - 1) * cw
		local group = floor((s - 1) / 4)
		local shade = (group % 2 == 0) and 26 or 14
		K.rect(cx, L.gy, cw, L.gh, COL.panel, shade)
		if (s - 1) % 4 == 0 then -- beat divider; beat 1 brighter
			local a = (s == 1) and 150 or 70
			K.line(cx, L.gy - 2, cx, L.gy + L.gh + 1, COL.turq, a)
		end
	end
	K.line(L.gx + NS * cw, L.gy - 2, L.gx + NS * cw, L.gy + L.gh + 1, COL.dim, 60)

	-- playhead column (the "alive" affordance)
	if pat.playing then
		local cx = L.gx + pat.pos * cw
		K.rect(cx, L.gy, cw, L.gh, COL.white, 26)
		K.line(cx, L.gy - 2, cx, L.gy + L.gh + 1, COL.white, 120)
		K.line(cx + cw, L.gy - 2, cx + cw, L.gy + L.gh + 1, COL.white, 120)
	end

	-- rows: header + cells
	for v = 1, NV do
		local ry = L.gy + (v - 1) * ch
		local c = acc(v)
		-- row header tag (brightens briefly when the voice fires)
		local fl = S.flash[v] or 0
		local ha = floor(150 + fl * 105)
		K.textr(L.lblW - 3, floor(ry + ch / 2 - 8), VOICES.list[v].short, c, ha)
		if fl > 0.01 then
			K.line(0, ry, L.lblW - 4, ry, c, floor(fl * 120))
		end
		-- cells
		for s = 1, NS do
			local cx = L.gx + (s - 1) * cw
			local cell = pat:cell(v, s)
			local ix, iy = cx + 1, ry + 1
			local iw, ih = cw - 2, ch - 2
			if cell and cell.on then
				-- velocity → brightness + height bar (redundant encoding)
				local vel = cell.vel or 1.0
				local bright = floor(110 + vel * 145)
				local bh = max(3, floor(ih * (0.4 + vel * 0.6)))
				K.rect(ix, iy, iw, ih, c, floor(40 + vel * 50)) -- faint full-cell wash
				K.rect(ix, iy + (ih - bh), iw, bh, c, bright) -- the height bar
				K.frame(ix, iy, iw, ih, c, 200)
			else
				K.frame(ix, iy, iw, ih, COL.dim, 50) -- empty: dim outline
			end
		end
	end

	-- focus highlight
	if S.region == "grid" then
		local fx = L.gx + (S.s - 1) * cw
		local fy = L.gy + (S.v - 1) * ch
		K.frame(fx - 1, fy - 1, cw + 1, ch + 1, COL.white, 255)
		K.frame(fx, fy, cw - 1, ch - 1, acc(S.v), 200)
	end
end

local function draw_bar(L)
	local W = L.W
	-- info line
	local iy = L.barY
	K.rect(0, iy, W, L.barh, COL.panel, 150)
	K.line(0, iy, W, iy, COL.turq, 80)
	local info = string.format("BPM %d   BANK %s   %s", pat.bpm, BANK_NAME[pat.bank], S.mode)
	K.text(8, iy + 3, info, COL.white, 210)
	local amode = audio and audio.label or "VISUAL"
	if S.mode == "LIVE" then
		K.textr(W - 8, iy + 3, (pat.playing and "REC TAP  " or "LIVE  ") .. amode, COL.red, 200)
	else
		K.textr(W - 8, iy + 3, amode, COL.turq, 170)
	end

	-- buttons
	local by = iy + L.infoH
	local bh = L.barh - L.infoH
	local bw = W / NBTN
	for i = 1, NBTN do
		local bx = (i - 1) * bw
		local id = BTN[i]
		local label, lc, fill = "", COL.white, 24
		if id == "play" then
			label = pat.playing and "STOP" or "PLAY"
			lc = pat.playing and COL.red or COL.green
			fill = pat.playing and 70 or 40
		elseif id == "bpmdn" then
			label = "BPM-"
		elseif id == "bpmup" then
			label = "BPM+"
		elseif id == "mode" then
			label = S.mode
			lc = (S.mode == "LIVE") and COL.red or COL.turq
		elseif id == "bank" then
			label = "BANK " .. BANK_NAME[pat.bank]
			lc = COL.violet
		elseif id == "clear" then
			label = "CLEAR"
			lc = COL.yellow
		elseif id == "beats" then
			label = "BEATS"
			lc = COL.green
		elseif id == "smp" then
			label = "SAMPLE"
			lc = (audio and audio.bound_count and audio.bound_count() > 0) and COL.turq or COL.dim
		end
		K.rect(bx + 2, by + 2, bw - 4, bh - 4, COL.panel, fill)
		K.frame(bx + 2, by + 2, bw - 4, bh - 4, COL.dim, 120)
		K.textc(bx + bw / 2, by + (bh - 10) / 2, label, lc, 230)
		if S.region == "bar" and S.bsel == i then
			K.frame(bx + 1, by + 1, bw - 2, bh - 2, COL.white, 255)
			K.frame(bx + 2, by + 2, bw - 4, bh - 4, lc, 160)
		end
	end
end

-- ── BEATS library screen ─────────────────────────────────────────────────────
local function draw_beats(L)
	local W, H = L.W, L.H
	K.chrome("DRUM MACHINE", "BEATS", nil)
	K.textc(floor(W / 2), 30, "BEATS LIBRARY", COL.turq, 230)
	K.textc(floor(W / 2), 46, Beats.dir(), COL.dim, 120)

	local n = #S.beats -- items are 0..n (0 = save-current)
	local listY = 64
	local rowh = (L.bk == "compact") and 18 or 22
	local foot = H - 26
	local maxrows = max(3, floor((foot - listY) / rowh))
	-- scroll so the cursor stays visible
	local off = 0
	if S.bidx >= maxrows then
		off = S.bidx - maxrows + 1
	end

	for vis = 0, maxrows - 1 do
		local idx = off + vis
		if idx > n then
			break
		end
		local ry = listY + vis * rowh
		local sel = (idx == S.bidx)
		local label, lc
		if idx == 0 then
			label = "+  SAVE CURRENT BANK AS .mid"
			lc = COL.green
		else
			label = string.format("%2d.  %s", idx, S.beats[idx])
			lc = COL.white
		end
		if sel then
			K.rect(20, ry - 2, W - 40, rowh, COL.panel, 150)
			K.frame(20, ry - 2, W - 40, rowh, lc, 200)
		end
		K.text(30, ry + (rowh - 16) / 2, label, lc, sel and 240 or 180)
		if idx > 0 and sel then
			K.textr(W - 30, ry + (rowh - 16) / 2, "[*] load   [X] delete", COL.dim, 150)
		end
	end

	if n == 0 then
		K.textc(floor(W / 2), listY + rowh + 8, "(no saved beats yet - drop a .mid here, or save one)", COL.dim, 140)
	end

	-- footer: status message + hint
	if S.msg and S.msg_t > 0 then
		K.textc(floor(W / 2), foot, S.msg, COL.yellow, floor(120 + 100 * min(1, S.msg_t)))
	else
		K.textc(floor(W / 2), foot, n .. " beat(s)   [*] select   [X] delete   [back] grid", COL.dim, 150)
	end
end

local function draw_samples(L)
	local W, H = L.W, L.H
	K.chrome("DRUM MACHINE", "SAMPLER", nil)
	local vlabel = VOICES.list[S.smp_target].short
	K.textc(floor(W / 2), 30, "VOICE " .. vlabel .. "  ->  SAMPLE", acc(S.smp_target), 230)
	local n = #S.smplib
	local listY = 52
	local rowh = (L.bk == "compact") and 18 or 22
	local foot = H - 26
	local maxrows = max(3, floor((foot - listY) / rowh))
	local off = (S.sidx >= maxrows) and (S.sidx - maxrows + 1) or 0
	for vis = 0, maxrows - 1 do
		local idx = off + vis
		if idx > n then
			break
		end
		local ry = listY + vis * rowh
		local sel = (idx == S.sidx)
		local label, lc
		if idx == 0 then
			label, lc = "-  (no sample: play the kit/note sound)", COL.dim
		else
			local m = S.smplib[idx]
			label = string.format("%2d.  %s   %dms", idx, m.name or m.id, m.dur_ms or 0)
			lc = COL.turq
		end
		if sel then
			K.rect(20, ry - 2, W - 40, rowh, COL.panel, 150)
			K.frame(20, ry - 2, W - 40, rowh, lc, 200)
		end
		K.text(30, ry + (rowh - 16) / 2, label, lc, sel and 240 or 180)
	end
	if n == 0 then
		K.textc(floor(W / 2), listY + rowh + 8, "(sample library empty - add samples in the SAMPLER app)", COL.dim, 140)
	end
	if S.msg and S.msg_t > 0 then
		K.textc(floor(W / 2), foot, S.msg, COL.yellow, 200)
	else
		K.textc(floor(W / 2), foot, n .. " sample(s)   [*] bind   [back] cancel", COL.dim, 150)
	end
end

function on_draw()
	local L = compute()
	K.clear(COL.bg)
	if S.screen == "samples" then
		draw_samples(L)
		K.overlay(S.t)
		return
	end
	if S.screen == "beats" then
		draw_beats(L)
		K.overlay(S.t)
		return
	end
	local hint
	if S.region == "grid" then
		hint = (L.bk == "compact") and "[*] toggle [X] vel [back] exit"
			or "[*] toggle  [X] vel  up/dn voice  [back] exit"
	else
		hint = "[*] " .. (BTN[S.bsel] or "") .. "   [back] exit"
	end
	-- audio mode lives in the bottom info line; the top-right carries the hint
	K.chrome("DRUM MACHINE", (S.midi_cue and S.midi_cue > 0) and "MIDI" or nil, nil)
	K.textr(L.W - 8, 5, hint, COL.dim, 150)
	draw_grid(L)
	draw_bar(L)
	K.overlay(S.t)
end

-- ── update: transport clock ──────────────────────────────────────────────────
function on_update(dt)
	S.t = S.t + dt
	if S.msg_t > 0 then
		S.msg_t = max(0, S.msg_t - dt)
	end
	if not audio then
		audio = Audio.open(K, VOICES, HERE)
	end
	-- push persisted voice→sample bindings into the bridge once it's open
	if audio and not S.smap_applied then
		S.smap_applied = true
		for v, id in pairs(S.samples) do
			audio.bind(v, id)
		end
		if S._pending_samples then
			S._pending_samples = false
			enter_samples(S.v)
		end
	end
	-- decay row-flash
	for v = 1, NV do
		if S.flash[v] and S.flash[v] > 0 then
			S.flash[v] = max(0, S.flash[v] - dt * 4)
		end
	end
	-- drive the MIDI subsystem (clock timing + hotplug reconnect)
	midi.update(dt)
	if S.midi_cue and S.midi_cue > 0 then
		S.midi_cue = max(0, S.midi_cue - dt * 2)
	end
	-- advance playback and fire steps. Under an external MIDI clock the playhead is
	-- stepped by midi.clock.on_step (see boot) instead of the dt accumulator.
	if midi.clock.source() ~= "external" then
		local fired = pat:advance(dt)
		for _, step0 in ipairs(fired) do
			for _, h in ipairs(pat:hits_at(step0)) do
				trigger(h.v, h.vel)
			end
		end
	end
	if audio then
		audio.tick(dt)
	end
	dm.redraw()
end

-- ── boot ─────────────────────────────────────────────────────────────────────
load_or_seed()
sync_grid_from_vs()
do
	local b = os.getenv("DEMOD_DM_BANK")
	if b and BANK_NAME[bank_index(b)] == b then
		pat:set_bank(bank_index(b))
	end
	local m = os.getenv("DEMOD_DM_MODE")
	if m == "LIVE" or m == "STEP" then
		S.mode = m
	end
	if os.getenv("DEMOD_DM_FOCUS") == "bar" then
		S.region = "bar"
	end
	-- import a .mid into the active bank on boot
	local imp = os.getenv("DEMOD_DM_IMPORT")
	if imp and #imp > 0 then
		local ok, res = SMF.import(imp, VOICES)
		if ok then
			apply_hits(res, true)
			set_msg("imported " .. imp)
		else
			io.stderr:write("[drum-machine] import failed: " .. tostring(res) .. "\n")
		end
	end
	-- Live MIDI via the shared subsystem: GM drum notes → voices (audition; LIVE
	-- mode records to the nearest step). The router owns the global on_midi.
	midi.on_note(function(ev)
		local v = VOICES.gm_to_voice(ev.note)
		if not v then
			return
		end
		if ev.kind == "note_on" then
			S.midi_cue = 1 -- header MIDI tag (decays in on_update)
			trigger(v, ev.vel)
			if S.mode == "LIVE" and pat.playing and S.screen == "grid" then
				pat:set(v, nearest_playstep(), true, ev.vel)
				persist()
			end
		end
		dm.redraw()
	end)
	-- External MIDI clock: follow transport + step the playhead on each 16th note.
	if (os.getenv("DEMOD_MIDI_CLOCK") or "") == "external" then
		midi.clock.set_source("external")
	end
	midi.clock.on_transport(function(kind)
		if midi.clock.source() ~= "external" then
			return
		end
		if kind == "start" then
			pat:start()
		elseif kind == "stop" then
			pat:stop()
		end
	end)
	midi.clock.on_step(function()
		if midi.clock.source() ~= "external" or not pat.playing then
			return
		end
		for _, step0 in ipairs(pat:step_once()) do
			for _, h in ipairs(pat:hits_at(step0)) do
				trigger(h.v, h.vel)
			end
		end
		dm.redraw()
	end)
	-- open an app-specific MIDI controller (framework auto-opens DEMOD_MIDI)
	local midipath = os.getenv("DEMOD_DM_MIDI")
	if midipath and #midipath > 0 then
		if midi.open(midipath) then
			io.stderr:write("[drum-machine] MIDI controller: " .. midipath .. "\n")
		end
	end
	if os.getenv("DEMOD_DM_SCREEN") == "beats" then
		enter_beats()
	elseif os.getenv("DEMOD_DM_SCREEN") == "samples" then
		S._pending_samples = true -- deferred: needs audio open for the library list
	end
	if os.getenv("DEMOD_DM_PLAY") then
		pat:start()
	end
end
io.stderr:write("[patch] DRUM MACHINE up\n")
