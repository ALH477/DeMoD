-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/viz.lua — visualizer.

  Uses dsp.scope() when the backend provides waveform data (stub/local). When it
  doesn't (orchestrator → demod-rt has no scope ring yet), the scope/spectrum/
  lissajous modes synthesize a waveform from the *detected pitch* so they stay
  alive and reactive — clearly marked "PITCH" so it isn't mistaken for the real
  signal. SPECTRUM is a real radix-2 FFT (was a fake |sample| bar chart). METERS
  is a proper tuner (note + cents) plus transport / CPU / active-FX.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local floor = math.floor
local M = { name = "VISUALIZER", short = "VIZ" }
local MODES = { "SCOPE", "SPECTRUM", "LISSAJOUS", "METERS" }
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

local function st(ctx)
	local s = ctx.S.viz or { mode = 1 }
	s.peaks = s.peaks or {} -- spectrum peak-hold
	s.bars = s.bars or {} -- spectrum temporal smoothing
	s.cents = s.cents or 0 -- smoothed tuner needle
	s.level = s.level or 0 -- smoothed display level (auto-gain)
	ctx.S.viz = s
	return s
end

function M.nav(ctx, action)
	local s = st(ctx)
	if action == "next" then
		s.mode = (s.mode % #MODES) + 1
		return true
	elseif action == "prev" then
		s.mode = ((s.mode - 2) % #MODES) + 1
		return true
	end
	return false
end

-- ── DSP helpers ─────────────────────────────────────────────────────────────

-- in-place iterative radix-2 FFT on 1-based arrays (n must be a power of two)
local function fft(re, im)
	local n = #re
	local j = 1
	for i = 1, n - 1 do
		if i < j then
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		end
		local mh = n // 2
		while mh >= 1 and j > mh do
			j = j - mh
			mh = mh // 2
		end
		j = j + mh
	end
	local len = 2
	while len <= n do
		local ang = -2 * math.pi / len
		local wlr, wli = math.cos(ang), math.sin(ang)
		local half = len // 2
		for i = 1, n, len do
			local wr, wi = 1.0, 0.0
			for k = 0, half - 1 do
				local a = i + k
				local b = a + half
				local tr = wr * re[b] - wi * im[b]
				local ti = wr * im[b] + wi * re[b]
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] = re[a] + tr
				im[a] = im[a] + ti
				local nwr = wr * wlr - wi * wli
				wi = wr * wli + wi * wlr
				wr = nwr
			end
		end
		len = len * 2
	end
end

-- synthesize a representative L/R waveform from the detected pitch (fallback)
local function synth_scope(pitch, level, t, n)
	local L, R = {}, {}
	local f = math.max(20, pitch or 110)
	local cyc = math.max(1, math.min(8, f / 55)) -- show 1..8 periods across the window
	for i = 1, n do
		local x = (i / n) * 2 * math.pi * cyc + t * 4
		local s = math.sin(x) + 0.3 * math.sin(2 * x) + 0.15 * math.sin(3 * x)
		L[i] = s * level
		R[i] = (math.sin(x + 0.5) + 0.3 * math.sin(2 * x + 0.2)) * level
	end
	return { L = L, R = R, n = n, synth = true }
end

-- nearest note + cents-off for the tuner; returns name, octave, cents or nil
local function note_of(hz)
	if not hz or hz <= 0 then
		return nil
	end
	local midi = 69 + 12 * (math.log(hz / 440.0) / math.log(2))
	local nearest = floor(midi + 0.5)
	local cents = (midi - nearest) * 100
	local name = NOTE_NAMES[(nearest % 12) + 1]
	local octave = floor(nearest / 12) - 1
	return name, octave, cents
end

local function grid(U, C, x, y, w, h)
	U.rect(x, y, w, h, C.bg, 200)
	for gx = 0, 8 do
		U.line(x + gx * w / 8, y, x + gx * w / 8, y + h, C.border, 60)
	end
	for gy = 0, 4 do
		U.line(x, y + gy * h / 4, x + w, y + gy * h / 4, C.border, 60)
	end
	U.line(x, y + h / 2, x + w, y + h / 2, C.border, 110)
end

-- ── draw ────────────────────────────────────────────────────────────────────

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local CFG = ctx.CFG or {}
	local s = st(ctx)
	local mode = MODES[s.mode]
	local compact = W < 380
	local narrow = W < 560
	local x, y, w, h = 20, 72, W - 40, H - 72 - 50 -- leave room for the footer+status

	local m = ctx.dsp.meters() or {}
	local m_hz = m.pitch_hz or 0
	local m_bpm = m.bpm or 0
	local m_beat = m.beat or 0
	local m_cpu = m.cpu or 0
	local m_xr = m.xruns or 0
	local t = ctx.S.t or 0

	-- waveform source: real scope if the backend has one, else pitch-synthesized
	local sc = ctx.dsp.scope()
	local synth = false
	if (not sc or not sc.L or (sc.n or 0) < 2) and mode ~= "METERS" then
		-- a gentle level proxy from active FX / beat so the synth trace breathes
		local lvl = 0.5 + 0.15 * math.sin(t * 2.0)
		sc = synth_scope(m_hz > 0 and m_hz or 110, lvl, t, 256)
		synth = true
	end

	if mode == "METERS" then
		grid(U, C, x, y, w, h)
		-- ── tuner: nearest note + cents needle ──
		local name, octv, cents = note_of(m_hz)
		s.cents = U.lerp(s.cents, cents or 0, CFG.reduce_motion and 1 or 0.25)
		local cy = y + h * 0.30
		if name then
			local inTune = math.abs(s.cents) < 5
			U.text_c(x + w / 2, cy - 30, name .. tostring(octv), inTune and C.green or C.turq, 255)
			U.text_c(
				x + w / 2,
				cy - 8,
				string.format("%.1f Hz   %+0.0f cents", m_hz, s.cents),
				inTune and C.green or C.dim,
				200
			)
			-- needle track with a faint in-tune window (+/-5 cents) at the centre
			local tx, tw = x + w * 0.15, w * 0.7
			U.rect(tx + tw / 2 - tw * 0.05, cy + 15, tw * 0.10, 7, C.green, 40)
			U.line(tx, cy + 18, tx + tw, cy + 18, C.border, 140)
			for gx = 0, 10 do
				local gxp = tx + gx * tw / 10
				U.line(gxp, cy + 14, gxp, cy + 22, C.border, gx == 5 and 200 or 90)
			end
			U.text_r(tx + tw, cy + 26, "+/-5c = in tune", C.dim, 110)
			local nx = tx + tw / 2 + (math.max(-50, math.min(50, s.cents)) / 50) * (tw / 2)
			U.tline(nx, cy + 10, nx, cy + 26, 2, inTune and C.green or C.yellow, 255)
		else
			U.text_c(x + w / 2, cy - 8, "-- no pitch --", C.dim, 160)
		end

		-- ── transport / CPU ──
		local by = y + h * 0.60
		U.text(x + 16, by, string.format("BPM %.0f", m_bpm), C.violet, 220)
		-- beat dots
		for b = 0, 3 do
			local on = (b == (m_beat % 4))
			U.circle(x + 110 + b * 16, by + 6, on and 5 or 3, on and C.violet or C.border, on and 255 or 120)
		end
		-- CPU bar (color by load)
		local cbw = math.min(w - 32, 220)
		local cbx = x + 16
		local cby = by + 26
		U.text(cbx, cby - 2, "CPU", C.dim, 180)
		local barx = cbx + 44
		local barw = cbw - 44
		U.rect(barx, cby, barw, 10, C.border, 140)
		local frac = math.max(0, math.min(1, m_cpu / 100))
		local ccol = (m_cpu > 80 and C.red) or (m_cpu > 55 and C.yellow) or C.green
		U.rect(barx, cby, barw * frac, 10, ccol, 220)
		U.text_r(barx + barw, cby - 2, string.format("%.0f%%  xr %d", m_cpu, m_xr), m_xr > 0 and C.red or C.dim, 200)

		-- ── active FX strip ──
		local n = ctx.dsp.slot_count()
		local fy = by + 50
		U.text(x + 16, fy, "FX", C.dim, 150)
		for i = 1, math.min(n, compact and 8 or (narrow and 10 or 16)) do
			local sl = ctx.dsp.slot(i)
			local on = (m.bypass_mask or 0) & (1 << (i - 1)) ~= 0
			local accent = U.SLOT_COLORS[((i - 1) % #U.SLOT_COLORS) + 1]
			local bx = x + 44 + (i - 1) * 20
			U.rect(bx, fy - 2, 16, 16, on and accent or C.border, on and 210 or 90)
			if sl and sl.kind == "synth" then
				U.text(bx + 1, fy - 1, "S", on and C.bg or C.dim, 220)
			end
		end
	elseif mode == "SCOPE" then
		grid(U, C, x, y, w, h)
		local n = sc.n
		-- auto-gain so quiet signals are visible (peak → ~0.9). Peak across BOTH
		-- channels so L and R share one scale — a loud R no longer clips while L sets
		-- the gain.
		local peak = 1e-4
		for i = 1, n do
			local a = math.abs(sc.L[i] or 0)
			if a > peak then
				peak = a
			end
			if sc.R then
				local b = math.abs(sc.R[i] or 0)
				if b > peak then
					peak = b
				end
			end
		end
		local gain = math.max(1, math.min(8, 0.9 / peak))
		local px, py
		for i = 1, n do
			local cx = x + (i - 1) / (n - 1) * w
			local cyy = y + h / 2 - (sc.L[i] or 0) * gain * (h / 2 - 4)
			cyy = math.max(y + 2, math.min(y + h - 2, cyy))
			if px then
				U.glowline(px, py, cx, cyy, synth and C.violet or C.turq, 220, 2)
			end
			px, py = cx, cyy
		end
		if sc.R then
			px, py = nil, nil
			for i = 1, n do
				local cx = x + (i - 1) / (n - 1) * w
				local cyy = y + h / 2 - (sc.R[i] or 0) * gain * (h / 2 - 4)
				cyy = math.max(y + 2, math.min(y + h - 2, cyy))
				if px then
					U.line(px, py, cx, cyy, C.violet, 110)
				end
				px, py = cx, cyy
			end
		end
	elseif mode == "SPECTRUM" then
		grid(U, C, x, y, w, h)
		-- real FFT magnitude spectrum (Hann window), log-frequency bins, dB scale
		local N = 256
		local re, im = {}, {}
		for i = 1, N do
			local sv = sc.L[((i - 1) % sc.n) + 1] or 0
			local win = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (N - 1))
			re[i] = sv * win
			im[i] = 0
		end
		fft(re, im)
		local half = N // 2
		local mags = {}
		for k = 1, half do
			mags[k] = 2 * math.sqrt(re[k] * re[k] + im[k] * im[k]) / N
		end
		local bars = compact and 24 or (narrow and 36 or 56)
		local bw = w / bars
		local minBin, maxBin = 2, half
		local pk, sm = s.peaks, s.bars
		local sk = CFG.reduce_motion and 1 or 0.4
		for b = 0, bars - 1 do
			local lo = floor(minBin * (maxBin / minBin) ^ (b / bars))
			local hi = math.max(lo + 1, floor(minBin * (maxBin / minBin) ^ ((b + 1) / bars)))
			local mag = 0
			for k = lo, math.min(hi, half) do
				if mags[k] > mag then
					mag = mags[k]
				end
			end
			-- dB → 0..1 (-66 dB floor)
			local db = 20 * (math.log(mag + 1e-6) / math.log(10))
			local v = math.max(0, math.min(1, (db + 66) / 66))
			sm[b] = U.lerp(sm[b] or 0, v, sk) -- temporal smoothing
			local bh = sm[b] * h
			if bh > 1 then
				U.gradient_v(x + b * bw + 1, y + h - bh, bw - 2, bh, C.turq, C.violet)
			end
			pk[b] = math.max((pk[b] or 0) - (CFG.reduce_motion and 1 or 0.012), sm[b])
			U.rect(x + b * bw + 1, y + h - pk[b] * h - 2, bw - 2, 2, C.yellow, 220)
		end
	elseif mode == "LISSAJOUS" then
		grid(U, C, x, y, w, h)
		local Lc = sc.L
		local Rc = sc.R or sc.L
		local px, py
		for i = 1, sc.n do
			local cx = x + w / 2 + (Lc[i] or 0) * (w / 2 - 6)
			local cyy = y + h / 2 - (Rc[i] or 0) * (h / 2 - 6)
			if px then
				U.line(px, py, cx, cyy, C.turq, 120)
			end
			U.circle(cx, cyy, 1, C.turq, 180)
			px, py = cx, cyy
		end
	end

	-- source badge: PITCH = pitch-synthesized fallback, SIM = stub's synthetic scope,
	-- LIVE = real post-chain waveform from the engine. (The stub returns a non-nil
	-- synthetic scope, so "not synth" alone would mislabel it LIVE.)
	if mode ~= "METERS" then
		local bk = ctx.dsp.backend_name and ctx.dsp.backend_name() or ""
		local label, col
		if synth then
			label, col = "PITCH", C.yellow
		elseif bk == "stub" then
			label, col = "SIM", C.violet
		else
			label, col = "LIVE", C.green
		end
		U.text_r(x + w - 6, y + 6, label, col, 170)
	end

	-- mode selector doubles as the footer hint (one line; mode + how to change it)
	U.footer(W, H, "[ < " .. mode .. " > ]   turn: change mode")
end

return M
