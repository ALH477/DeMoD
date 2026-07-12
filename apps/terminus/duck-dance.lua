-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- duck-dance.lua — LoFi Keys MkII duck dance, audio + audio-reactive video.
--
-- A complete demod-ad project: dm.track{} synthesises the LoFi Keys MkII Faust
-- audio, dm.config{}+dm.scene{} render an audio-reactive 1080x1080 video on the
-- DeMoD "oscilloscope phosphor on CRT glass" palette.
--
-- Render both audio + video in one shot (run from the repo root so the relative
-- asset paths resolve):
--
--   python3 scripts/extract-duck-frames.py   # once: GIF  -> assets/duck-frames/*.png
--   python3 scripts/render-lofi-audio.py \
--       --out assets/audio/duck-dance-lofi.wav   # MIDI -> polyphonic Faust WAV
--   demod-ad render duck-dance.lua            # WAV + scene -> duck-dance.mp4
--
-- The LoFi Keys MkII audio is rendered through the demod-fx `faust_render`
-- PolyEngine (true 8-voice polyphony). demod-ad's own dm.track{} path is not
-- used here: the bundled demod-ad 0.4.0 cannot reach faust_render in this
-- environment and falls back to a monophonic compile, which would collapse the
-- piano chords. See scripts/render-lofi-audio.py.

-- ===========================================================================
-- Video — 1080x1080 audio-reactive scene
-- ===========================================================================
dm.config({
	audio = "assets/audio/duck-dance-loop.wav", -- 9s seamless MIDI loop (no tail silence)
	duration = "auto",
	resolution = "square", -- 1080 x 1080
	fps = 30,
	output = "duck-dance.mp4",
	background = dm.color.black,
	audio_bands = 8,
})

-- -- palette (phosphor-on-CRT) ------------------------------------------------
local rgb, rgba = dm.rgb, dm.rgba
local C = {
	bg = rgb(0x0A, 0x0A, 0x0F),
	turq = rgb(0x00, 0xF5, 0xD4),
	violet = rgb(0x8B, 0x5C, 0xF6),
	white = rgb(0xE8, 0xE8, 0xF0),
	dim = rgb(0x6A, 0x6A, 0x86),
	green = rgb(0x4C, 0xFF, 0x82),
	yellow = rgb(0xFF, 0xD9, 0x4C),
	panel = rgb(0x12, 0x12, 0x1E),
	border = rgb(0x2A, 0x2A, 0x3E),
}

-- 8-band spectrum ramp: turquoise -> violet -> magenta
local BAND_COLORS = {
	{ 0x00, 0xF5, 0xD4 },
	{ 0x00, 0xDD, 0xFF },
	{ 0x44, 0xBB, 0xFF },
	{ 0x77, 0x88, 0xFF },
	{ 0x8B, 0x5C, 0xF6 },
	{ 0xAA, 0x44, 0xF0 },
	{ 0xCC, 0x33, 0xCC },
	{ 0xFF, 0x44, 0xAA },
}

-- default duck: the 8-bit shuba dance (frames via scripts/build-duck-videos.py)
local DUCK_DIR = "assets/frames/8bit-shuba"
local DUCK_FRAMES = 122
local DUCK_FPS = 14.9877
local DUCK_AW, DUCK_AH = 516, 500

-- audio snapshot with safe fallbacks when rendered without analysis
local function sig(audio, t)
	if not audio then
		return { rms = 0, bass = 0, onset = 0, beat = false, pop = 0, bright = 0, dur = 9.0 }
	end
	local phase = audio:beat_phase(t)
	return {
		rms = audio:rms(t),
		bass = audio:band(t, 0),
		onset = audio:onset(t),
		beat = audio:beat(t),
		pop = 1.0 - math.min(1.0, phase * 1.6), -- 1 just after a beat, decays out
		bright = audio:brightness(t),
		dur = audio.duration or 9.0,
	}
end

-- L-shaped trace-corner accents (the home.lua card motif)
local function trace_corners(ctx, x, y, w, h, len, col, th)
	local function L(cx, cy, dx, dy)
		ctx:line(cx, cy, cx + dx * len, cy, col, { thickness = th })
		ctx:line(cx, cy, cx, cy + dy * len, col, { thickness = th })
	end
	L(x, y, 1, 1)
	L(x + w, y, -1, 1)
	L(x, y + h, 1, -1)
	L(x + w, y + h, -1, -1)
end

dm.scene({
	id = "duck",
	duration = "auto",
	draw = function(ctx, t, audio)
		local W, H = ctx.width, ctx.height
		local s = sig(audio, t)
		local cx = W / 2

		-- ---- backdrop ----------------------------------------------------
		ctx:bg(C.bg)
		ctx:plasma(t * 0.35, 0, 0, W, H, { scale = 1.4, speed = 0.8, alpha = 0.07 + s.bass * 0.10, palette = "cyber" })
		ctx:stroke_rect(14, 14, W - 28, H - 28, rgba(0x2A, 0x2A, 0x3E, 180), { thickness = 2 })

		-- ---- header ------------------------------------------------------
		ctx:text("DeMoD's LoFi Keys MkII", {
			font = "Orbitron",
			size = 62,
			color = C.turq,
			x = cx,
			y = 40,
			align = "center",
			glow = 0.30 + s.rms * 0.55,
		})
		ctx:text("CH.01  //  DUCK DANCE      BPM 160", {
			font = "JetBrainsMono",
			size = 20,
			color = C.dim,
			x = cx,
			y = 118,
			align = "center",
		})

		-- ---- framed "scope screen" with the duck -------------------------
		local SCR = 500
		local sx, sy = cx - SCR / 2, 168
		-- panel + beat-reactive glowing border
		ctx:rect(sx, sy, SCR, SCR, C.panel)
		local bcol = rgba(0x00, 0xF5, 0xD4, math.floor(150 + 105 * s.pop))
		ctx:stroke_rect(sx, sy, SCR, SCR, bcol, { thickness = 2 + math.floor(s.pop * 2) })
		ctx:stroke_rect(sx + 6, sy + 6, SCR - 12, SCR - 12, rgba(0x2A, 0x2A, 0x3E, 200), { thickness = 1 })
		trace_corners(ctx, sx, sy, SCR, SCR, 26 + math.floor(s.pop * 10), C.turq, 3)
		-- channel tab label
		ctx:rect(sx + 14, sy - 2, 96, 24, C.bg)
		ctx:text("CH.01", { font = "JetBrainsMono", size = 16, color = C.turq, x = sx + 22, y = sy - 1 })

		-- duck sprite, aspect-fit into the screen; bob in Y. Lock sprite + bob to
		-- whole cycles within the audio loop so the video wraps perfectly when
		-- looped (audio is the 9s MIDI loop).
		local LOOP = (audio and audio.duration) or 9.0
		local cycles = math.max(1, math.floor(LOOP * DUCK_FPS / DUCK_FRAMES + 0.5))
		local eff = DUCK_FRAMES * cycles / LOOP
		local idx = (math.floor(t * eff) % DUCK_FRAMES) + 1
		local bobc = math.max(1, math.floor(LOOP * 6.2 / (2 * math.pi) + 0.5))
		local bob = math.sin(t * 2 * math.pi * bobc / LOOP) * 9
		local pad = 30
		local inner = SCR - pad * 2
		local fit = math.min(inner / DUCK_AW, inner / DUCK_AH)
		local dw, dh = DUCK_AW * fit, DUCK_AH * fit
		ctx:image(string.format("%s/f_%04d.png", DUCK_DIR, idx), sx + (SCR - dw) / 2, sy + (SCR - dh) / 2 + bob, dw, dh)

		-- ---- oscilloscope (real PCM trace) -------------------------------
		local ox, oy, ow, oh = 110, sy + SCR + 26, W - 220, 168
		ctx:text("WAVEFORM", { font = "JetBrainsMono", size = 15, color = C.dim, x = ox, y = oy - 22 })
		ctx:rect(ox, oy, ow, oh, rgba(0x0E, 0x0E, 0x16, 200))
		ctx:stroke_rect(ox, oy, ow, oh, rgba(0x2A, 0x2A, 0x3E, 160), { thickness = 1 })
		ctx:line(ox + 6, oy + oh / 2, ox + ow - 6, oy + oh / 2, rgba(0x2A, 0x2A, 0x3E, 150))
		if audio then
			ctx:waveform(
				audio:waveform_data(t, 256),
				ox + 6,
				oy + 6,
				ow - 12,
				oh - 12,
				C.turq,
				{ glow = 0.4 + s.rms * 0.9, mirror = true, thickness = 3 }
			)
		end

		-- ---- spectrum bars (turq->magenta ramp, manual for per-band colour)
		local bx, by, bw, bh = 110, oy + oh + 24, W - 220, 102
		local n = 8
		local gap = 10
		local barw = (bw - gap * (n - 1)) / n
		for i = 1, n do
			local v = audio and audio:band(t, i - 1) or 0
			v = math.min(1.0, v * 1.25)
			local hh = math.max(2, v * bh)
			local col = BAND_COLORS[i]
			local a = math.floor(150 + 105 * v)
			local px = bx + (i - 1) * (barw + gap)
			ctx:rect(px, by + bh - hh, barw, hh, rgba(col[1], col[2], col[3], a))
			-- bright cap
			ctx:rect(px, by + bh - hh, barw, 3, rgba(col[1], col[2], col[3], 255))
		end

		-- ---- footer: progress + readout ----------------------------------
		local prog = math.min(1.0, t / math.max(0.001, s.dur))
		local px, py, pw = 110, H - 46, W - 220
		ctx:rect(px, py, pw, 6, C.border)
		ctx:rect(px, py, pw * prog, 6, C.turq)
		ctx:text(
			string.format("t %05.2fs / %05.2fs", t, s.dur),
			{ font = "JetBrainsMono", size = 16, color = C.dim, x = px, y = py - 26 }
		)
		ctx:text(
			"LoFi Keys MkII  -  tape sat + sierpinski bloom",
			{ font = "JetBrainsMono", size = 16, color = C.dim, x = px + pw, y = py - 26, align = "right" }
		)

		-- ---- post ---------------------------------------------------------
		ctx:scanlines(0.14, 3)
		ctx:crt_glow(0.22)
		ctx:vignette(0.38)
	end,
})
