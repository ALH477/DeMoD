-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/util.lua — shared draw helpers + palette for DSP Studio
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local floor = math.floor

local U = {}

-- DeMoD oscilloscope-phosphor palette (matches home.lua / demod_main.lua)
U.C = {
	bg = { 10, 10, 15 },
	panel = { 18, 18, 30 },
	panel_hi = { 26, 26, 46 },
	border = { 42, 42, 62 },
	turq = { 0, 245, 212 },
	violet = { 139, 92, 246 },
	white = { 232, 232, 240 },
	dim = { 106, 106, 134 },
	red = { 255, 76, 106 },
	green = { 76, 255, 130 },
	yellow = { 255, 217, 76 },
	orange = { 255, 140, 66 },
	blue = { 0, 170, 255 },
}

-- slot accent ring used by the FX chain (cycled per slot)
U.SLOT_COLORS = {
	U.C.orange,
	U.C.turq,
	U.C.violet,
	U.C.blue,
	U.C.yellow,
	U.C.green,
	U.C.red,
	{ 0xFF, 0x6A, 0xD4 },
	{ 0x6A, 0xD4, 0xFF },
	{ 0xD4, 0xFF, 0x6A },
	{ 0xB0, 0x8A, 0xFF },
	{ 0xFF, 0xB0, 0x8A },
}

function U.rect(x, y, w, h, c, a)
	dm.draw.rect(floor(x), floor(y), floor(w), floor(h), c[1], c[2], c[3], a or 255)
end
function U.line(x0, y0, x1, y1, c, a)
	dm.draw.line(floor(x0), floor(y0), floor(x1), floor(y1), c[1], c[2], c[3], a or 255)
end
function U.tline(x0, y0, x1, y1, th, c, a)
	dm.draw.thick_line(floor(x0), floor(y0), floor(x1), floor(y1), th, c[1], c[2], c[3], a or 255)
end
function U.text(x, y, s, c, a)
	dm.draw.text(floor(x), floor(y), s, c[1], c[2], c[3], a or 255)
end
function U.circle(cx, cy, r, c, a)
	if r < 1 then
		return
	end
	dm.draw.circle(floor(cx), floor(cy), floor(r), c[1], c[2], c[3], a or 255)
end
function U.gradient_v(x, y, w, h, top, bot)
	dm.draw.gradient_v(floor(x), floor(y), floor(w), floor(h), top[1], top[2], top[3], bot[1], bot[2], bot[3])
end

function U.lerp(a, b, k)
	return a + (b - a) * k
end
function U.clamp(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end

-- Hold-to-accelerate for held inc/dec (encoder / keyboard auto-repeat / i2c).
-- Consecutive same-direction ticks arriving faster than ACCEL_GAP ramp the step up
-- exponentially with how long the button's been held; a pause or a reversal resets
-- to 1x so a deliberate tap stays precise. ACCEL_GAP (0.20s) sits between the keyboard
-- auto-repeat interval (~0.03s, no mid-burst reset) and its initial delay (~0.4s, so a
-- fresh hold starts slow). `state` is a caller-persisted table; `now` is ctx.S.t.
U.ACCEL_GAP = 0.20 -- s: longer pause (or reversal) resets the burst
U.ACCEL_RATE = 3.5 -- exponential rate in held-seconds
U.ACCEL_MAX = 40 -- cap so a long hold can't run away
function U.accel(state, dir, now)
	local gap = now - (state.last or -1e9)
	if dir ~= state.dir or gap > U.ACCEL_GAP then
		state.dir, state.start = dir, now
	end
	state.last = now
	local held = now - (state.start or now)
	return math.min(U.ACCEL_MAX, math.exp(U.ACCEL_RATE * held))
end

-- right-aligned text helper (fixed 8px font)
function U.text_r(xr, y, s, c, a)
	U.text(xr - #s * 8, y, s, c, a)
end
-- centred text helper
function U.text_c(xc, y, s, c, a)
	U.text(xc - #s * 4, y, s, c, a)
end
-- pixel width of a string in the fixed 8px font
function U.text_w(s)
	return #s * 8
end

-- ── shared phosphor polish (mirrors home.lua) ────────────────────────────
-- subtle CRT vignette — darken top/bottom edges for depth
function U.vignette(W, H)
	local vh = floor(H * 0.16)
	if vh < 1 then
		return
	end
	for j = 0, vh do
		local a = floor(55 * (1 - j / vh))
		U.line(0, j, W, j, U.C.bg, a)
		U.line(0, H - j, W, H - j, U.C.bg, a)
	end
end

-- console corner brackets — an oscilloscope frame around the screen
function U.brackets(W, H, col, m, cl)
	col = col or U.C.turq
	m = m or 12
	cl = cl or 18
	local a = 45
	U.tline(m, m, m + cl, m, 2, col, a)
	U.tline(m, m, m, m + cl, 2, col, a)
	U.tline(W - m, m, W - m - cl, m, 2, col, a)
	U.tline(W - m, m, W - m, m + cl, 2, col, a)
	U.tline(m, H - m, m + cl, H - m, 2, col, a)
	U.tline(m, H - m, m, H - m - cl, 2, col, a)
	U.tline(W - m, H - m, W - m - cl, H - m, 2, col, a)
	U.tline(W - m, H - m, W - m, H - m - cl, 2, col, a)
end

-- a glowing line: bright 2px core + a soft vertical halo (stacked low-alpha)
function U.glowline(x0, y0, x1, y1, col, a, spread)
	a = a or 230
	spread = spread or 2
	for j = -spread, spread do
		if j ~= 0 then
			local f = 1 - math.abs(j) / (spread + 1)
			U.line(x0, y0 + j, x1, y1 + j, col, floor(a * 0.16 * f))
		end
	end
	U.tline(x0, y0, x1, y1, 2, col, a)
end

-- format a 0..1 (or ranged) parameter value for display
function U.fmt(v, unit)
	unit = unit or ""
	if unit == "Hz" then
		return string.format("%.0f Hz", v)
	end
	if unit == "dB" then
		return string.format("%+.1f dB", v)
	end
	if unit == "ms" then
		return string.format("%.0f ms", v)
	end
	if unit == "%" then
		return string.format("%.0f %%", v * 100)
	end
	if unit == "x" then
		return string.format("%.2fx", v)
	end
	return string.format("%.2f", v)
end

-- ── shared screen chrome (consistent header/footer across all screens) ─────
-- Layout rhythm: tab bar 0..48 · header title at 54, separator at 74 · content
-- 82..H-50 · screen hint at H-42 · global status band at H-22 (drawn by chrome).
U.HEADER_Y = 54
U.CONTENT_TOP = 82
U.FOOTER_Y = -42 -- offset from H (so footer sits just above the status band)
U.CONTENT_BOTTOM = -50 -- offset from H

-- screen title (left) + optional right-aligned context + separator. Returns the
-- y where content may begin (U.CONTENT_TOP).
function U.header(W, title, right, accent)
	accent = accent or U.C.turq
	U.text(20, U.HEADER_Y, title, accent, 230)
	if right and right ~= "" then
		U.text_r(W - 20, U.HEADER_Y, right, U.C.dim, 160)
	end
	U.line(20, 74, W - 20, 74, U.C.border, 140)
	return U.CONTENT_TOP
end

-- one consistent place + style for the per-screen hint line (above the status band)
function U.footer(W, H, hint)
	U.text(20, H + U.FOOTER_Y, hint, U.C.dim, 160)
end

-- truncate to a pixel width at the fixed 8px font, adding a trailing marker
function U.ellipsize(s, px)
	local maxc = math.max(1, math.floor(px / 8))
	if #s <= maxc then
		return s
	end
	if maxc <= 1 then
		return s:sub(1, 1)
	end
	return s:sub(1, maxc - 1) .. "~" -- "~" reads as "truncated" in ASCII-only font
end

return U
