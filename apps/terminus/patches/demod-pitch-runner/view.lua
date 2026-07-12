-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/view.lua — instrument target view + notation.

  Renders WHERE to play the incoming note (a labelled fretboard for string
  instruments, a labelled piano for melodic ones), plus the note-notation
  helpers used across the GUI:

    V.label(prof, midi, mode)  -> "E:3" (tab) | "C4" (note)   short text label
    V.staff(x,y,w,h, midi, c)  -> a mini treble staff with the note drawn on it
    V.lane_label(prof, lane)   -> the string letter / register tag for a lane

  Drawing only (call inside on_draw). gamekit (K), theory (T) and instruments
  (INST) are injected by main via V.init.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor = math.floor

local V = {}
local K, T, INST -- injected

function V.init(k, t, inst)
	K, T, INST = k, t, inst
end

-- ── shared polish helpers (mirror dsp/util.lua, kept in-patch) ───────────────
-- soft glowing line: bright core + low-alpha halo
function V.glowline(x0, y0, x1, y1, c, a, spread)
	spread = spread or 2
	for s = spread, 1, -1 do
		local fa = floor((a or 200) * 0.18 * (1 - (s - 1) / (spread + 1)))
		K.line(x0, y0 - s, x1, y1 - s, c, fa)
		K.line(x0, y0 + s, x1, y1 + s, c, fa)
	end
	K.line(x0, y0, x1, y1, c, a or 200)
end

-- oscilloscope corner brackets around a rect
function V.brackets(x, y, w, h, c, a, len)
	len = len or 12
	x, y, w, h = floor(x), floor(y), floor(w), floor(h)
	local function L(x0, y0, x1, y1)
		K.line(x0, y0, x1, y1, c, a)
	end
	L(x, y, x + len, y)
	L(x, y, x, y + len)
	L(x + w, y, x + w - len, y)
	L(x + w, y, x + w, y + len)
	L(x, y + h, x + len, y + h)
	L(x, y + h, x, y + h - len)
	L(x + w, y + h, x + w - len, y + h)
	L(x + w, y + h, x + w, y + h - len)
end

-- truncate text to a pixel width (8px glyphs), append '~' if cut
function V.ellipsize(s, px)
	local n = floor(px / 8)
	if #s <= n then
		return s
	end
	if n <= 1 then
		return "~"
	end
	return s:sub(1, n - 1) .. "~"
end

-- a framed panel: faint fill + border + corner accents
function V.panel(x, y, w, h, accent, fill_a)
	local COL = K.COL
	K.rect(x, y, w, h, COL.panel, fill_a or 40)
	K.frame(x, y, w, h, COL.panel, 200)
	V.brackets(x, y, w, h, accent or COL.turq, 150, (w < 200) and 8 or 14)
end

-- emphasised centred text. scale>1 uses real crisp integer-scaled glyphs;
-- scale 1 (default) falls back to a faux-bold double-draw.
function V.bigc(cx, y, s, c, a, scale)
	scale = scale or 1
	if scale > 1 then
		K.textc(cx, y, s, c, a or 240, scale)
	else
		K.textc(cx + 1, y, s, c, floor((a or 240) * 0.45))
		K.textc(cx - 1, y, s, c, floor((a or 240) * 0.45))
		K.textc(cx, y, s, c, a or 240)
	end
end

local MARKERS = { [3] = true, [5] = true, [7] = true, [9] = true, [12] = true, [15] = true }
local LETTER_STEP = { 0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6 } -- pc -> diatonic letter index (C..B)
local IS_SHARP = { false, true, false, true, false, false, true, false, true, false, true, false }

-- ── notation labels ──────────────────────────────────────────────────────────
local function letter(midi)
	return T.NOTE_NAMES[(midi % 12) + 1]
end

-- short text label for a note in the given mode ("tab" | "note"; staff -> note name)
function V.label(prof, midi, mode)
	if mode == "tab" and prof.kind == "fret" then
		local fp = INST.note_to_fret(prof, midi)
		if fp then
			return letter(prof.tuning[fp.string]) .. ":" .. fp.fret
		end
	end
	return T.midi_to_name(midi)
end

-- the lane's identity tag: open-string letter (fret) or low note of the register (keys)
function V.lane_label(prof, lane)
	if prof.kind == "fret" then
		return letter(prof.tuning[lane + 1] or prof.tuning[1])
	end
	local lo, hi = INST.range(prof)
	local n = INST.lanes(prof)
	return letter(floor(lo + (hi - lo) * (lane + 0.5) / n))
end

-- ── mini treble staff ────────────────────────────────────────────────────────
local function dia_of(midi)
	local pc = midi % 12
	return (floor(midi / 12) - 1) * 7 + LETTER_STEP[pc + 1]
end

-- draw a small 5-line treble staff in the box with `midi` placed on it
function V.staff(x, y, w, h, midi, accent)
	local COL = K.COL
	accent = accent or COL.turq
	local gap = floor((h - 6) / 4)
	if gap < 4 then
		gap = 4
	end
	local cy = floor(y + h / 2)
	for k = -2, 2 do -- E4 G4 B4 D5 F5, middle line (k=0) = B4 (dia 34)
		K.line(x + 16, cy + k * gap, x + w - 6, cy + k * gap, COL.dim, 130)
	end
	-- stylised treble (G) clef cue
	K.line(x + 19, cy - 2 * gap, x + 19, cy + 2 * gap, accent, 200)
	K.circle(x + 19, cy + gap, 2, accent, 220)
	if not midi then
		return
	end
	local steps = 34 - dia_of(midi) -- + = below middle line
	local ny = cy + floor(steps * (gap / 2))
	local nx = x + floor(w * 0.62)
	local lp = steps / 2 -- position in line-units (+ down)
	if lp >= 3 then
		for u = 3, floor(lp) do
			K.line(nx - 8, cy + u * gap, nx + 8, cy + u * gap, COL.dim, 150)
		end
	elseif lp <= -3 then
		for u = -3, math.ceil(lp), -1 do
			K.line(nx - 8, cy + u * gap, nx + 8, cy + u * gap, COL.dim, 150)
		end
	end
	if IS_SHARP[(midi % 12) + 1] then
		K.text(nx - 16, ny - 7, "#", accent, 230)
	end
	K.circle(nx, ny, 3, accent, 245)
end

-- ── keyboard (melodic instruments) ───────────────────────────────────────────
local function draw_keys(prof, x, y, w, h, opts)
	local COL = K.COL
	local lo, hi = INST.range(prof)
	local whites = {}
	for m = lo, hi do
		if not T.is_black(m % 12) then
			whites[#whites + 1] = m
		end
	end
	local nw = #whites
	if nw == 0 then
		return
	end
	local wkw = w / nw
	local xof = {}
	for i, m in ipairs(whites) do
		local kx = x + (i - 1) * wkw
		xof[m] = { x = kx, w = wkw - 2 }
		local c = COL.panel
		if opts.target == m then
			c = COL.violet
		end
		if opts.playing == m then
			c = COL.green
		end
		K.rect(kx, y, wkw - 2, h, c, opts.playing == m and 235 or 150)
		K.frame(kx, y, wkw - 2, h, COL.dim, 110)
		if m % 12 == 0 then -- label each C with its octave
			K.textc(kx + (wkw - 2) / 2, y + h - 12, "C" .. (floor(m / 12) - 1), COL.dim, 150)
		end
	end
	local bkw = wkw * 0.6
	for m = lo, hi do
		if T.is_black(m % 12) and xof[m - 1] then
			local bx = xof[m - 1].x + xof[m - 1].w - bkw / 2
			local c = COL.black
			if opts.target == m then
				c = COL.violet
			end
			if opts.playing == m then
				c = COL.green
			end
			K.rect(bx, y, bkw, h * 0.6, c, 255)
			K.frame(bx, y, bkw, h * 0.6, COL.dim, 140)
			xof[m] = { x = bx, w = bkw, black = true }
		end
	end
	if opts.cursor and xof[opts.cursor] then
		local k = xof[opts.cursor]
		local kh = k.black and h * 0.6 or h
		K.frame(k.x - 1, y - 1, k.w + 2, kh + 2, COL.turq, 255)
		K.frame(k.x - 2, y - 2, k.w + 4, kh + 4, COL.turq, 110)
	end
end

-- ── fretboard (string instruments) ───────────────────────────────────────────
local function draw_fret(prof, x, y, w, h, opts)
	local COL = K.COL
	local ns = #prof.tuning
	local nf = prof.frets
	local lx = x + 16 -- room for string letters
	local by = y + h - 10 -- room for fret numbers
	local bw = (x + w) - lx
	local bh = by - y
	local rowh = bh / ns
	local colw = bw / (nf + 1)

	for f = 1, nf do
		if MARKERS[f] then
			K.circle(lx + (f + 0.5) * colw, y + bh * 0.5, 2, COL.dim, 110)
		end
	end
	-- strings (string 1 / lowest at the bottom) + open-note letter
	for i = 1, ns do
		local ry = y + (ns - i) * rowh + rowh * 0.5
		K.line(lx, ry, lx + bw, ry, COL.dim, 110)
		K.textr(lx - 2, ry - 7, letter(prof.tuning[i]), COL.dim, 170)
	end
	-- fret wires + numbers
	for f = 0, nf do
		local fx = lx + (f + 1) * colw
		K.line(fx, y, fx, by, COL.panel, f == 0 and 210 or 80)
	end
	for _, f in ipairs({ 0, 3, 5, 7, 9, 12, 15 }) do
		if f <= nf then
			K.textc(lx + (f + 0.5) * colw, by + 1, tostring(f), COL.dim, 150)
		end
	end

	local function dot(midi, c, a, ring)
		local fp = INST.note_to_fret(prof, midi)
		if not fp then
			return
		end
		local ry = y + (ns - fp.string) * rowh + rowh * 0.5
		local cx = lx + (fp.fret + 0.5) * colw
		if ring then
			K.frame(cx - rowh * 0.42, ry - rowh * 0.42, rowh * 0.84, rowh * 0.84, c, 255)
		else
			K.circle(cx, ry, floor(rowh * 0.34), c, a)
		end
	end
	if opts.target then
		dot(opts.target, COL.violet, 235, false)
	end
	if opts.playing then
		dot(opts.playing, COL.green, 245, false)
	end
	if opts.cursor then
		dot(opts.cursor, COL.turq, 255, true)
	end
end

-- draw the target view in (x,y,w,h). opts = { target, cursor, playing, label, mode }
function V.draw(prof, x, y, w, h, opts)
	opts = opts or {}
	if prof.kind == "fret" then
		draw_fret(prof, x, y, w, h, opts)
	else
		draw_keys(prof, x, y, w, h, opts)
	end
	if opts.label and opts.cursor then
		K.textc(floor(x + w / 2), floor(y + h + 4), "YOU: " .. V.label(prof, opts.cursor, opts.mode), K.COL.turq, 230)
	end
end

return V
