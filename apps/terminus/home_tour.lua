-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  home_tour.lua — Cinematic TERMINUS Home interface ad (demod-ad render)

  Renders the DeMoD unified home screen as a 30-second cinematic teaser
  with Faust-synthesized audio score.

  Render:  demod-ad render home_tour.lua
  ============================================================================ ]]

dm.config({
	duration = 30.0,
	resolution = "1280x720",
	fps = 15,
	output = "output/home_tour.mp4",
	audio = "assets/audio/score.wav",
})

-- ── Audio: Faust synth score ──────────────────────────────────────────────
dm.track({
	duration = 30.0,
	sample_rate = 44100,
	output = "assets/audio/score.wav",
	voices = {
		{ id = "pad", dsp = "builtin:pad", drone = "C2", gain = 0.25 },
		{ id = "bass", dsp = "builtin:sierpinski_bass", drone = "C2", gain = 0.35 },
		{ id = "kick", dsp = "builtin:kick", pattern = "x...x...x...x...", step = 0.25, pitch = "C2", gain = 0.6 },
		{ id = "hat", dsp = "builtin:hat", pattern = "..x...x...x.x...", step = 0.125, gain = 0.12 },
		{
			id = "lead",
			dsp = "builtin:lead",
			sequence = {
				{ 4.0, "C4", 0.6, 0.3 }, -- card reveal
				{ 10.5, "E4", 0.6, 0.3 }, -- card 3 focus
				{ 16.0, "G4", 0.6, 0.3 }, -- card 5 focus
				{ 22.2, "C5", 0.7, 0.4 }, -- blade opens
				{ 27.0, "A4", 0.5, 0.25 }, -- outro
			},
			gain = 0.45,
		},
	},
	master_chain = { "fx:soft_clip", "fx:dc_block" },
})

-- ── Palette (identical to home.lua COL) ───────────────────────────────────
local COL = {
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
}

-- ── Channels (same as home.lua) ───────────────────────────────────────────
local CHANNELS = {
	{ id = "dsp", name = "DSP STUDIO", tag = "Effects . Synth", accent = COL.turq, preview = "dsp" },
	{ id = "lyrics", name = "LYRICS", tag = "Worship . Karaoke", accent = COL.violet, preview = "lyrics" },
	{ id = "ferro", name = "FERROFLUID", tag = "Faraday Visualizer", accent = COL.green, preview = "ferro" },
	{ id = "market", name = "MARKETPLACE", tag = "Patches . Culture", accent = COL.yellow, preview = "market" },
	{ id = "systems", name = "SYSTEMS", tag = "Ecosystem Map", accent = COL.turq, preview = "systems" },
	{ id = "settings", name = "SYSTEM", tag = "Settings . Status", accent = COL.red, preview = "settings" },
}
local N = #CHANNELS

-- ── Math helpers ──────────────────────────────────────────────────────────
local floor, abs, sin, max, min = math.floor, math.abs, math.sin, math.max, math.min
local function lerp(a, b, k)
	return a + (b - a) * k
end
local function clamp(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end

-- ── Draw helpers (wrappers around dm.draw.*) ─────────────────────────────
local function rect(x, y, w, h, c, a)
	dm.draw.rect(floor(x), floor(y), floor(w), floor(h), c[1], c[2], c[3], a or 255)
end
local function line(x0, y0, x1, y1, c, a)
	dm.draw.line(floor(x0), floor(y0), floor(x1), floor(y1), c[1], c[2], c[3], a or 255)
end
local function tline(x0, y0, x1, y1, th, c, a)
	dm.draw.thick_line(floor(x0), floor(y0), floor(x1), floor(y1), th, c[1], c[2], c[3], a or 255)
end
local function text(x, y, s, c, a)
	dm.draw.text(floor(x), floor(y), s, c[1], c[2], c[3], a or 255)
end
local function circle(cx, cy, r, c, a)
	if r < 1 then
		return
	end
	dm.draw.circle(floor(cx), floor(cy), floor(r), c[1], c[2], c[3], a or 255)
end
local function gradient_v(x, y, w, h, top, bot)
	dm.draw.gradient_v(floor(x), floor(y), floor(w), floor(h), top[1], top[2], top[3], bot[1], bot[2], bot[3])
end

-- ── Easing utilities ──────────────────────────────────────────────────────
local ease = dm.ease

-- ── Card layout ───────────────────────────────────────────────────────────
local COLS = 3
local function card_positions(W, H)
	local pos = {}
	local rows = math.ceil(N / COLS)
	local gap = 20
	local mx = max(36, W * 0.06)
	local cw = (W - mx * 2 - gap * (COLS - 1)) / COLS
	local ch = min((H - 120 - gap * (rows - 1)) / rows, cw * 0.74)
	local totalH = rows * ch + (rows - 1) * gap
	local startY = 92 + (H - 92 - 56 - totalH) / 2
	for i = 1, N do
		local col = (i - 1) % COLS
		local row = floor((i - 1) / COLS)
		pos[i] = {
			x = floor(mx + col * (cw + gap) + cw / 2),
			y = floor(startY + row * (ch + gap) + ch / 2),
			w = floor(cw),
			h = floor(ch),
		}
	end
	return pos
end

-- ── Mini preview icons (per channel) ──────────────────────────────────────
local function draw_preview(ch, sx, sy, a, t)
	if ch.preview == "dsp" then
		for k = 0, 3 do
			local hh = 4 + abs(sin(t * 3 + k)) * 8
			rect(sx + k * 5, sy - hh, 3, hh, ch.accent, a)
		end
	elseif ch.preview == "lyrics" then
		for j = 0, 2 do
			local yy = sy - 4 + j * 6
			line(sx, yy, sx + 18, yy, ch.accent, floor(a * (0.6 + j * 0.15)))
		end
	elseif ch.preview == "ferro" then
		circle(sx + 9, sy, 8, ch.accent, floor(a * 0.25))
		circle(sx + 9, sy, 5, ch.accent, floor(a * 0.5))
		circle(sx + 9, sy, 2, ch.accent, a)
	elseif ch.preview == "market" then
		for k = 0, 2 do
			rect(sx + k * 7, sy - 6 + sin(t * 2 + k) * 2, 4, 12, ch.accent, a)
		end
	elseif ch.preview == "systems" then
		dm.draw.sierpinski(
			floor(sx + 9),
			floor(sy - 8),
			floor(sx + 2),
			floor(sy + 6),
			floor(sx + 16),
			floor(sy + 6),
			2,
			{ 0, 0, 0, 0 },
			{ ch.accent[1], ch.accent[2], ch.accent[3], a }
		)
	elseif ch.preview == "settings" then
		local rr = 8
		for j = 0, 5 do
			local angle = t * 1.5 + j * math.pi / 3
			local dx = floor(math.cos(angle) * rr)
			local dy = floor(math.sin(angle) * rr)
			circle(sx + 9 + dx, sy + dy, 2, ch.accent, a)
		end
		circle(sx + 9, sy, 3, ch.accent, a)
	end
end

-- ── Draw a channel card ───────────────────────────────────────────────────
local function draw_card(ch, pos, focused, alpha, t)
	if alpha <= 0.02 then
		return
	end
	local x, y, w, h = pos.x, pos.y, pos.w, pos.h
	local a = floor(alpha * 255)
	gradient_v(x - w / 2, y - h / 2, w, h, COL.panel_hi, COL.panel)
	rect(x - w / 2, y - h / 2, w, h, COL.panel, floor(a * 0.15))
	tline(x - w / 2 + 2, y - h / 2 + 2, x + w / 2 - 2, y - h / 2 + 2, 2, ch.accent, floor(a * 0.9))
	text(x - #ch.name * 4, y - 10, ch.name, COL.white, a)
	text(x - #ch.tag * 3, y + 8, ch.tag, COL.dim, floor(a * 0.8))
	draw_preview(ch, x + w / 2 - 30, y - h / 2 + 22, a, t)
end

-- ── Focus ring ────────────────────────────────────────────────────────────
local function draw_ring(pos, t)
	local x, y, w, h = pos.x, pos.y, pos.w, pos.h
	local r = 5 + sin(t * 6) * 1.5
	local cl = 14
	tline(x - w / 2 - r, y - h / 2 - r, x - w / 2 - r + cl, y - h / 2 - r, 2, COL.turq, 200)
	tline(x - w / 2 - r, y - h / 2 - r, x - w / 2 - r, y - h / 2 - r + cl, 2, COL.turq, 200)
	tline(x + w / 2 + r, y - h / 2 - r, x + w / 2 + r - cl, y - h / 2 - r, 2, COL.turq, 200)
	tline(x + w / 2 + r, y - h / 2 - r, x + w / 2 + r, y - h / 2 - r + cl, 2, COL.turq, 200)
	tline(x - w / 2 - r, y + h / 2 + r, x - w / 2 - r + cl, y + h / 2 + r, 2, COL.turq, 200)
	tline(x - w / 2 - r, y + h / 2 + r, x - w / 2 - r, y + h / 2 + r - cl, 2, COL.turq, 200)
	tline(x + w / 2 + r, y + h / 2 + r, x + w / 2 + r - cl, y + h / 2 + r, 2, COL.turq, 200)
	tline(x + w / 2 + r, y + h / 2 + r, x + w / 2 + r, y + h / 2 + r - cl, 2, COL.turq, 200)
end

-- ── Background ────────────────────────────────────────────────────────────
local function draw_bg(W, H, t, pulse)
	rect(0, 0, W, H, COL.bg)
	local s = min(W, H) * 0.9
	dm.draw.sierpinski(
		floor(W / 2),
		floor(H * 0.08),
		floor(W / 2 - s / 2),
		floor(H * 0.88),
		floor(W / 2 + s / 2),
		floor(H * 0.88),
		3,
		{ 0, 0, 0, 0 },
		{ COL.turq[1], COL.turq[2], COL.turq[3], 8 }
	)
	local cx, cy = W / 2, H / 2 + H * 0.02
	local base = min(W, H) * (0.30 + 0.05 * sin(t * 1.3)) * (0.85 + pulse * 0.5)
	for j = 1, 4 do
		local f = j / 4
		local a = floor(12 * (1 - f))
		if a > 0 then
			circle(cx, cy, base * f, (j <= 2) and COL.turq or COL.violet, a)
		end
	end
	local band = (t * 60) % (H + 80) - 40
	for j = 0, 6 do
		line(0, band + j, W, band + j, COL.turq, floor(8 * (1 - j / 6)))
	end
end

-- ── Blade (right-side detail panel) ───────────────────────────────────────
local function draw_blade(W, H, ch, progress, t)
	if progress <= 0.01 then
		return
	end
	local pw = min(W * 0.46, 460)
	local px = W - floor(pw * progress)
	gradient_v(px, 0, pw, H, COL.panel_hi, COL.panel)
	rect(px, 0, pw, H, COL.panel, floor(progress * 40))
	tline(px + 1, 0, px + 1, H, 2, ch.accent, floor(progress * 200))
	text(px + 20, 18, ch.name, COL.white, floor(progress * 220))
	text(px + 20, 40, ch.tag, COL.dim, floor(progress * 160))
	local cx = px + pw / 2
	local sz = 50
	draw_preview(ch, cx - sz / 2, 110, floor(progress * 180), t)
	-- H line, then stack of text labels, then resume marker
	line(px + 20, 130, px + pw - 20, 130, COL.border, 100)
end

-- ── Chrome (top/bottom status strips) ─────────────────────────────────────
local function draw_chrome(W, H, t)
	text(20, 22, "TERMINUS", COL.turq, 220)
	text(20 + 9 * 8 + 8, 22, "DeMoD HOME", COL.dim, 140)
	local cur = CHANNELS[1].name
	text(W - #cur * 8 - 20, 22, cur, COL.white, 160)
	local sy = H - 26
	line(0, H - 40, W, H - 40, COL.border, 120)
	text(20, sy, "RT", COL.green, 200)
	circle(20 + 22, sy + 6, 3, COL.green, 220)
	text(70, sy, "1.33ms", COL.dim, 140)
	text(150, sy, "MESH", COL.turq, 200)
	circle(150 + 34, sy + 6, 3, COL.turq, 220)
	text(200, sy, "E2 82Hz", COL.dim, 140)
	local badge = string.format("WIDE %dx%d", W, H)
	text(W - #badge * 8 - 20, sy, badge, COL.dim, 120)
end

-- ── Boot overlay ──────────────────────────────────────────────────────────
local function draw_boot(W, H, boot_progress)
	local p = boot_progress
	local a = floor((1 - p) * 255)
	if a <= 2 then
		return
	end
	rect(0, 0, W, H, COL.bg, a)
	local s = min(W, H) * 0.4 * (0.5 + p * 0.5)
	local cx, cy = W / 2, H / 2
	dm.draw.sierpinski_glow(
		floor(cx),
		floor(cy - s * 0.6),
		floor(cx - s * 0.7),
		floor(cy + s * 0.5),
		floor(cx + s * 0.7),
		floor(cy + s * 0.5),
		3,
		{ 0, 0, 0, 0 },
		{ COL.turq[1], COL.turq[2], COL.turq[3], floor(a * 0.8) },
		{ COL.turq[1], COL.turq[2], COL.turq[3], a },
		8
	)
	text(cx - 32, cy + s * 0.6 + 10, "TERMINUS", COL.turq, a)
end

-- ── Main scene ─────────────────────────────────────────────────────────────
dm.scene({
	id = "tour",
	duration = 30.0,
	draw = function(ctx, t, audio)
		local W, H = dm.width(), dm.height()
		local positions = card_positions(W, H)

		-- ── Phase timing ───────────────────────────────────────────────
		local boot_ease = clamp((t - 0.5) / 2.0, 0, 1) -- 0.5..2.5s  boot → 1
		local boot_p = ease.in_out(boot_ease)
		local reveal_start = 2.5
		local walk_start = 7.0
		local blade_open_t = 22.0
		local outro_start = 27.0
		local focus_duration = 2.5

		-- Audio reactive pulse
		local pulse = audio and audio:rms(t) or 0.3
		pulse = 0.3 + pulse * 0.7

		-- ── Background ─────────────────────────────────────────────────
		draw_bg(W, H, t, pulse)

		-- ── Card reveal ─────────────────────────────────────────────────
		local focus_idx = 1
		for i = 1, N do
			local card_delay = reveal_start + (i - 1) * 0.18
			local card_t = clamp((t - card_delay) / 0.5, 0, 1)
			local card_alpha = ease.out_back(card_t)
			local offset_x = lerp(300, 0, card_alpha)
			local pos = {
				x = positions[i].x + offset_x,
				y = positions[i].y,
				w = positions[i].w,
				h = positions[i].h,
			}
			local focused = (i == focus_idx) and (t > reveal_start) and (t < walk_start)
			if card_alpha > 0.001 then
				draw_card(CHANNELS[i], pos, focused, card_alpha, t)
			end
		end

		-- ── Focus walk ──────────────────────────────────────────────────
		if t >= walk_start and t < blade_open_t then
			focus_idx = clamp(floor((t - walk_start) / focus_duration) + 1, 1, N)
			local phase_t = (t - walk_start) % focus_duration
			local next_idx = clamp(focus_idx + 1, 1, N)
			local idx_a, idx_b = focus_idx, next_idx
			local blend = clamp(phase_t / (focus_duration * 0.7), 0, 1)
			blend = ease.in_out(clamp(blend, 0, 1))
			local interp_pos = {
				x = lerp(positions[idx_a].x, positions[idx_b].x, blend),
				y = lerp(positions[idx_a].y, positions[idx_b].y, blend),
				w = lerp(positions[idx_a].w, positions[idx_b].w, blend),
				h = lerp(positions[idx_a].h, positions[idx_b].h, blend),
			}
			draw_ring(interp_pos, t)
		end

		-- ── Blade panel ─────────────────────────────────────────────────
		local blade_progress = 0
		if t >= blade_open_t then
			blade_progress = ease.out_quad(clamp((t - blade_open_t) / 0.7, 0, 1))
		end
		if t >= blade_open_t and t < outro_start then
			draw_blade(W, H, CHANNELS[focus_idx], blade_progress, t)
		elseif t >= outro_start then
			local retract = 1.0 - ease.in_quad(clamp((t - outro_start) / 1.5, 0, 1))
			draw_blade(W, H, CHANNELS[focus_idx], retract, t)
		end

		-- ── Chrome (always on top after bg) ────────────────────────────
		draw_chrome(W, H, t)

		-- ── Boot overlay ───────────────────────────────────────────────
		if boot_p < 1 then
			draw_boot(W, H, boot_p)
		end

		-- ── Outro fade ─────────────────────────────────────────────────
		if t >= outro_start then
			local fade = ease.in_quad(clamp((t - outro_start) / 3.0, 0, 1))
			rect(0, 0, W, H, COL.bg, floor(fade * 255))
			-- Final glow pulse
			if fade > 0.5 and fade < 0.95 then
				local s = min(W, H) * 0.5 * (1 - (fade - 0.5) * 2)
				local cx, cy = W / 2, H / 2
				dm.draw.sierpinski_glow(
					floor(cx),
					floor(cy - s * 0.6),
					floor(cx - s * 0.7),
					floor(cy + s * 0.5),
					floor(cx + s * 0.7),
					floor(cy + s * 0.5),
					3,
					{ 0, 0, 0, 0 },
					{ COL.turq[1], COL.turq[2], COL.turq[3], floor((1 - fade) * 120) },
					{ COL.turq[1], COL.turq[2], COL.turq[3], floor((1 - fade) * 200) },
					10
				)
			end
		end
	end,
})
