-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-duck-dance/main.lua — Duck Dance, BPM-correct looping app patch.

  A self-contained demod-ui "app" patch the home shell launches via the terminus
  supervisor (`back` = dm.quit, hands the framebuffer back to TERMINUS).

  The loop clock is locked to the music: 24 beats / 6 bars at 160 BPM = exactly
  9.000 s, so the sprite, the oscilloscope, and the note scheduling all wrap on a
  clean bar boundary — no drift. When the on-device DSP runtime is present the
  notes are routed to the LoFi Keys MkII synth over the dsp/midi_input JACK
  bridge; with no synth running it is a graceful visual-only loop.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local floor, sin, min, max = math.floor, math.sin, math.min, math.max
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"

-- ── assets ──────────────────────────────────────────────────────────────────
local FD = dofile(HERE .. "duck-anim-frames.lua")
local BIN
do
	local f = io.open(HERE .. "duck-anim-frames.bin", "rb")
	if f then
		BIN = f:read("*all")
		f:close()
	end
end

local SW, SH = FD.w or 96, FD.h or 96 -- source sprite size
local FPS = FD.fps or 10
local BPM = FD.bpm or 160
local LOOP_BEATS = 24 -- 6 bars (4/4)
local LOOP_LEN = LOOP_BEATS * 60.0 / BPM -- seconds (== 9.0 at 160)
local SECS_BEAT = 60.0 / BPM
local NOTES = FD.midi_notes or {}

local COL = {
	bg = { 10, 10, 15 },
	panel = { 18, 18, 30 },
	border = { 42, 42, 62 },
	turq = { 0, 245, 212 },
	violet = { 139, 92, 246 },
	white = { 232, 232, 240 },
	dim = { 106, 106, 134 },
	yellow = { 255, 217, 76 },
}
-- 8-band spectrum ramp turquoise -> violet -> magenta
local RAMP = {
	{ 0, 245, 212 },
	{ 0, 221, 255 },
	{ 68, 187, 255 },
	{ 119, 136, 255 },
	{ 139, 92, 246 },
	{ 170, 68, 240 },
	{ 204, 51, 204 },
	{ 255, 68, 170 },
}

-- ── optional synth bridge (dsp/midi_input JACK) ─────────────────────────────
local MI, SYNTH = nil, false
do
	for _, p in ipairs({
		HERE .. "../../dsp/midi_input.lua",
		(os.getenv("DEMOD_UI_ROOT") or "") .. "/dsp/midi_input.lua",
	}) do
		local ok, mod = pcall(dofile, p)
		if ok and type(mod) == "table" and mod.push_event then
			MI = mod
			break
		end
	end
	if MI and MI.open_jack_client then
		SYNTH = select(1, pcall(MI.open_jack_client, "duck-dance")) and true or false
	end
end
local function send(ev)
	if MI then
		pcall(MI.push_event, "secondary", ev)
	end
end

-- ── sprite frames ───────────────────────────────────────────────────────────
-- dm.draw.blit is 1:1 (no scaling): the data must be exactly dest_w*dest_h*4.
-- We blit at native size, with a one-time nearest 2x cache for larger screens.
local function frame_native(fi)
	if not (BIN and FD.frame_offsets) then
		return nil
	end
	local off = FD.frame_offsets[fi]
	if not off then
		return nil
	end
	local sz = SW * SH * 4
	if off + sz > #BIN then
		return nil
	end
	return BIN:sub(off + 1, off + sz)
end

local CACHE2X -- [fi] = 2x-upscaled RGBA string (built lazily)
local function frame_2x(fi)
	if not CACHE2X then
		CACHE2X = {}
		for f = 1, (FD.total or 51) do
			local src = frame_native(f)
			if not src then
				break
			end
			local rows = {}
			for y = 0, SH - 1 do
				local cols = {}
				local base = y * SW * 4
				for x = 0, SW - 1 do
					local p = src:sub(base + x * 4 + 1, base + x * 4 + 4)
					cols[#cols + 1] = p
					cols[#cols + 1] = p -- double horizontally
				end
				local row = table.concat(cols)
				rows[#rows + 1] = row
				rows[#rows + 1] = row -- double vertically
			end
			CACHE2X[f] = table.concat(rows)
		end
	end
	return CACHE2X[fi]
end

-- ── state / clock ───────────────────────────────────────────────────────────
-- T      : music clock, wraps on the 6-bar boundary (drives notes + beat)
-- anim_t : free-running sprite clock (never resets) so the duck cycles seamlessly
local T, anim_t, idx, active, beat_t = 0, 0, 1, {}, 0

local function all_off()
	for n in pairs(active) do
		send({ type = "note_off", note = n, vel = 0 })
	end
	active = {}
end

local function apply_until(time)
	while idx <= #NOTES and time >= NOTES[idx].t do
		local e = NOTES[idx]
		if e.k == 1 then
			active[e.n] = { vel = e.v or 0.63, age = 0 }
			send({ type = "note_on", note = e.n, vel = e.v or 0.63 })
		else
			active[e.n] = nil
			send({ type = "note_off", note = e.n, vel = 0 })
		end
		idx = idx + 1
	end
end

-- ── input: every source funnels here; back returns to TERMINUS ──────────────
local function quit()
	all_off()
	if dm.quit then
		dm.quit()
	end
end
function on_nav(action)
	if action == "back" then
		quit()
	end
	dm.redraw()
end
function on_input(evt, btn, val)
	if evt == "DOWN" and btn == "NAV_BACK" then
		quit()
	end
	dm.redraw()
end

-- ── update ──────────────────────────────────────────────────────────────────
function on_update(dt)
	T = T + dt
	beat_t = beat_t + dt
	anim_t = anim_t + dt
	apply_until(T)
	if T >= LOOP_LEN then -- wrap exactly on the 6-bar boundary
		T = T - LOOP_LEN
		idx = 1
		beat_t = beat_t % SECS_BEAT
		all_off() -- release anything still held, restart clean
	end
	for _, info in pairs(active) do
		info.age = (info.age or 0) + dt
	end
	dm.redraw()
end

-- ── draw ────────────────────────────────────────────────────────────────────
local function ctext(x, y, s, c, a)
	dm.draw.text(floor(x - #s * 4), floor(y), s, c[1], c[2], c[3], a or 230)
end

function on_draw()
	local W, H = dm.width(), dm.height()
	dm.draw.rect(0, 0, W, H, COL.bg[1], COL.bg[2], COL.bg[3], 255)

	-- geometry: the scope screen wraps the duck at its native/2x pixel size
	local span = min(W, H)
	local scale2x = span >= 260 -- 2x sprite on roomy screens
	local DPX = scale2x and (SW * 2) or SW
	local pad = max(6, floor(DPX * 0.10))
	local SCR = DPX + pad * 2
	local sx, sy = floor(W / 2 - SCR / 2), floor(H * 0.26)
	if sy < floor(H * 0.16) then
		sy = floor(H * 0.16)
	end

	-- header
	ctext(W / 2, H * 0.085, "LoFi Keys MkII", COL.turq, 240)
	ctext(W / 2, H * 0.085 + 18, "CH.01  //  DUCK DANCE   BPM 160", COL.dim, 170)

	-- beat-reactive framed screen
	local beat = T / SECS_BEAT
	local pop = max(0, 1 - (beat % 1) * 1.6)
	dm.draw.rect(sx, sy, SCR, SCR, COL.panel[1], COL.panel[2], COL.panel[3], 255)
	local ba = floor(150 + 105 * pop)
	dm.draw.rect(sx, sy, SCR, 2, COL.turq[1], COL.turq[2], COL.turq[3], ba)
	dm.draw.rect(sx, sy + SCR - 2, SCR, 2, COL.turq[1], COL.turq[2], COL.turq[3], ba)
	dm.draw.rect(sx, sy, 2, SCR, COL.turq[1], COL.turq[2], COL.turq[3], ba)
	dm.draw.rect(sx + SCR - 2, sy, 2, SCR, COL.turq[1], COL.turq[2], COL.turq[3], ba)
	-- trace corners
	local cl = floor(SCR * 0.10) + floor(pop * 6)
	local function corner(px, py, dx, dy)
		dm.draw.line(px, py, px + dx * cl, py, COL.turq[1], COL.turq[2], COL.turq[3], 230)
		dm.draw.line(px, py, px, py + dy * cl, COL.turq[1], COL.turq[2], COL.turq[3], 230)
	end
	corner(sx, sy, 1, 1)
	corner(sx + SCR, sy, -1, 1)
	corner(sx, sy + SCR, 1, -1)
	corner(sx + SCR, sy + SCR, -1, -1)

	-- duck sprite (native or 2x, blitted 1:1, vertical bob)
	local bob = floor(sin(T * 6.2) * (DPX * 0.04))
	local fi = (floor(anim_t * FPS) % (FD.total or 51)) + 1
	local data = dm.draw.blit and (scale2x and frame_2x(fi) or frame_native(fi)) or nil
	if data then
		dm.draw.blit(sx + pad, sy + pad + bob, DPX, DPX, data, 255)
	else
		-- older demod-ui without dm.draw.blit: placeholder so the screen isn't blank
		dm.draw.rect(sx + pad, sy + pad + bob, DPX, DPX, COL.border[1], COL.border[2], COL.border[3], 80)
		ctext(sx + SCR / 2, sy + SCR / 2, "[ DUCK ]", COL.dim, 160)
	end

	-- oscilloscope beams from the live held notes
	local n_notes = 0
	for _ in pairs(active) do
		n_notes = n_notes + 1
	end
	local ox, oy = sx, sy + SCR + floor(H * 0.03)
	local ow = SCR
	local oh = floor(span * 0.13)
	dm.draw.rect(ox, oy, ow, oh, COL.panel[1], COL.panel[2], COL.panel[3], 180)
	if n_notes > 0 then
		local i = 0
		for note, info in pairs(active) do
			local freq = 440 * 2 ^ ((note - 69) / 12)
			local amp = (info.vel or 0.6) * oh * 0.42
			local color = (i % 2 == 0) and COL.turq or COL.violet
			local cy = oy + oh / 2
			local pxp, pyp
			for sxp = 0, ow, 2 do
				local vy = floor(cy + sin(T * freq * 0.12 + sxp * 0.22 + i * 1.3) * amp)
				local vx = ox + sxp
				if pxp then
					dm.draw.line(pxp, pyp, vx, vy, color[1], color[2], color[3], 200)
				end
				pxp, pyp = vx, vy
			end
			i = i + 1
		end
	end

	-- spectrum bars: active notes binned into 8 pitch columns
	local bins = { 0, 0, 0, 0, 0, 0, 0, 0 }
	for note, info in pairs(active) do
		local b = floor((note - 36) / (60 / 8))
		b = max(0, min(7, b))
		bins[b + 1] = max(bins[b + 1], info.vel or 0.6)
	end
	local bx, by = sx, oy + oh + floor(H * 0.02)
	local bw, bh = SCR, floor(span * 0.08)
	local gap = max(2, floor(bw * 0.012))
	local barw = floor((bw - gap * 7) / 8)
	for i = 1, 8 do
		local v = min(1, bins[i] * 1.1)
		local hh = max(2, floor(v * bh))
		local c = RAMP[i]
		dm.draw.rect(bx + (i - 1) * (barw + gap), by + bh - hh, barw, hh, c[1], c[2], c[3], floor(140 + 115 * v))
	end

	-- loop bar + 24 beat pips
	local lx, ly, lw = sx, floor(H * 0.95), SCR
	dm.draw.rect(lx, ly, lw, 4, COL.border[1], COL.border[2], COL.border[3], 255)
	dm.draw.rect(lx, ly, floor(lw * (T / LOOP_LEN)), 4, COL.turq[1], COL.turq[2], COL.turq[3], 255)
	for b = 0, LOOP_BEATS - 1 do
		local on = (floor(beat) % LOOP_BEATS) == b
		local c = on and COL.turq or (b % 4 == 0 and COL.dim or COL.border)
		dm.draw.rect(floor(lx + lw * (b / LOOP_BEATS)), ly - 7, (b % 4 == 0 and 2 or 1), 5, c[1], c[2], c[3], 230)
	end

	-- status / scanlines
	local sline = SYNTH and "SYNTH: LoFi Keys MkII (live)" or "SYNTH: visual-only (no DSP runtime)"
	dm.draw.text(lx, ly - 22, "160 BPM  6 bars  seamless", COL.dim[1], COL.dim[2], COL.dim[3], 150)
	dm.draw.text(floor(lx + lw - #sline * 8), ly - 22, sline, COL.dim[1], COL.dim[2], COL.dim[3], 150)
	local off = (T * 14) % 3
	for y = 0, H, 3 do
		dm.draw.line(0, floor(y + off), W, floor(y + off), 0, 0, 0, 36)
	end
end

io.stderr:write(string.format("[patch] DUCK DANCE up  loop=%.3fs  synth=%s\n", LOOP_LEN, tostring(SYNTH)))
