-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-rhythm/main.lua — RHYTHM RUNNER: a beat game for TERMINUS.

  Notes scroll down 3 lanes toward a hit-line. Move the lane cursor with
  prev/next and STRIKE with activate ON the beat. Clean hits play the lane's
  note through the synth bridge, so the game is audible music when a voice is
  loaded (and fully playable / silent otherwise — it runs headless).

  Same focus-field model as the shell: one cursor, every input funnels through
  nav(). `back` aborts to the title, or exits to TERMINUS from the title.

  All beat-map generation + hit judging lives in the pure, testable chart.lua;
  this file is UI + game state only. Shared draw/sound/save helpers come from
  ../games/gamekit.lua.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local C = dofile(HERE .. "chart.lua")
local K = dofile(HERE .. "../games/gamekit.lua")

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local COL = K.COL
local snd = K.sound("demod-rhythm")

-- per-lane accent colours (low -> high)
local LANE_COL = { COL.turq, COL.violet, COL.yellow }
local LEAD = 4 -- beats of runway visible above the hit-line

local DIFF = {
	{ name = "EASY", bpm = 90, density = 0.40, bars = 16 },
	{ name = "NORMAL", bpm = 120, density = 0.55, bars = 20 },
	{ name = "HARD", bpm = 150, density = 0.72, bars = 24 },
}

local SAVE = K.load("demod-rhythm")
local best = tonumber(SAVE.best) or 0

-- attract/self-play: when set, the title screen auto-plays a song hands-free.
-- Also used by the headless smoke test to exercise the play/over draw paths.
local SELFPLAY = os.getenv("DEMOD_RHYTHM_SELFPLAY") ~= nil

local S = {
	state = "title", -- title | play | over
	diff = 2,
	t = 0, -- wall clock since boot (for flashes/animation)
	-- per-song:
	notes = {},
	bpm = 120,
	beat = 0,
	songbeats = 0,
	cursor = 1, -- lane 0..2
	score = 0,
	combo = 0,
	maxcombo = 0,
	hits = 0,
	perfects = 0,
	misses = 0,
	offs = {}, -- scheduled note-offs: { {t=, note=}, ... }
	flash = nil, -- { text=, t=, c= }
	newbest = false,
}

-- ── song lifecycle ───────────────────────────────────────────────────────────
local function start_song()
	local d = DIFF[S.diff]
	local seed = (os.time() % 100000) + S.score + math.random(1, 9999)
	S.notes = C.generate(seed, d.bars, { density = d.density })
	S.bpm = d.bpm
	S.songbeats = C.length(S.notes)
	S.beat = -LEAD -- a count-in: first note starts at the top
	S.score, S.combo, S.maxcombo = 0, 0, 0
	S.hits, S.perfects, S.misses = 0, 0, 0
	S.offs = {}
	S.flash = nil
	S.newbest = false
	S.cursor = 1
	S.state = "play"
end

local function finish_song()
	S.state = "over"
	for _, o in ipairs(S.offs) do
		snd.off(o.note)
	end
	S.offs = {}
	if S.score > best then
		best = S.score
		S.newbest = true
		K.save("demod-rhythm", { best = best })
	end
end

-- ── striking ─────────────────────────────────────────────────────────────────
local function register(res, n)
	local base = (res == "perfect") and 100 or 50
	local mult = 1 + floor(S.combo / 8)
	S.score = S.score + base * mult
	S.combo = S.combo + 1
	S.maxcombo = max(S.maxcombo, S.combo)
	S.hits = S.hits + 1
	if res == "perfect" then
		S.perfects = S.perfects + 1
	end
	snd.on(n.note, res == "perfect" and 0.9 or 0.7)
	S.offs[#S.offs + 1] = { t = S.t + 0.22, note = n.note }
	S.flash = { text = res:upper() .. "!  x" .. mult, t = S.t, c = (res == "perfect") and COL.turq or COL.green }
end

local function strike()
	if S.state ~= "play" then
		return
	end
	local good_b = C.WINDOW.good * S.bpm / 60 -- good window in beats
	local hit, hd = nil, 1e9
	for _, n in ipairs(S.notes) do
		if not n.judged and n.lane == S.cursor then
			local d = abs(n.beat - S.beat)
			if d < hd then
				hd, hit = d, n
			end
		end
	end
	if hit and hd <= good_b then
		local res = C.judge(hit.beat - S.beat, S.bpm)
		hit.judged, hit.result = true, res
		register(res, hit)
	else
		S.flash = { text = "--", t = S.t, c = COL.dim } -- empty strike: no penalty
	end
end

-- ── input funnel (one dispatcher; every source calls it) ─────────────────────
local function move(d)
	S.cursor = (S.cursor + d) % C.LANES
	if S.cursor < 0 then
		S.cursor = S.cursor + C.LANES
	end
end

local function nav(action)
	if S.state == "title" then
		if action == "activate" then
			start_song()
		elseif action == "back" then
			if dm.quit then
				dm.quit()
			end
		elseif action == "next" or action == "tab" then
			S.diff = (S.diff % #DIFF) + 1
		elseif action == "prev" or action == "tab_prev" then
			S.diff = ((S.diff - 2) % #DIFF) + 1
		end
	elseif S.state == "play" then
		if action == "prev" then
			move(-1)
		elseif action == "next" then
			move(1)
		elseif action == "activate" or action == "wet" then
			strike()
		elseif action == "back" then
			S.state = "title"
		end
	elseif S.state == "over" then
		if action == "activate" then
			start_song()
		elseif action == "back" then
			S.state = "title"
		end
	end
	dm.redraw()
end

function on_nav(action)
	nav(action)
end

-- demod5 i2c buttons + AS5600 encoder -> same actions
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
		elseif btn == "NAV_PREV" or btn == "NAV_UP" then
			nav("prev")
		elseif btn == "NAV_NEXT" or btn == "NAV_DOWN" then
			nav("next")
		end
	end
	dm.redraw()
end

-- ── per-frame update ─────────────────────────────────────────────────────────
function on_update(dt)
	S.t = S.t + dt
	if S.state == "play" then
		S.beat = S.beat + dt * S.bpm / 60
		-- self-play: aim the cursor at the soonest note and strike on the line
		if SELFPLAY then
			local soon, sd = nil, 1e9
			for _, n in ipairs(S.notes) do
				if not n.judged then
					local d = n.beat - S.beat
					if d >= -0.05 and d < sd then
						sd, soon = d, n
					end
				end
			end
			if soon then
				S.cursor = soon.lane
				if abs(soon.beat - S.beat) <= 0.03 then
					strike()
				end
			end
		end
		local good_b = C.WINDOW.good * S.bpm / 60
		-- auto-miss notes that slipped past the hit-line
		for _, n in ipairs(S.notes) do
			if not n.judged and (S.beat - n.beat) > good_b + 0.06 then
				n.judged, n.result = true, "miss"
				S.combo = 0
				S.misses = S.misses + 1
				S.flash = { text = "MISS", t = S.t, c = COL.red }
			end
		end
		-- scheduled note-offs
		if #S.offs > 0 then
			local keep = {}
			for _, o in ipairs(S.offs) do
				if o.t <= S.t then
					snd.off(o.note)
				else
					keep[#keep + 1] = o
				end
			end
			S.offs = keep
		end
		-- end of song (all notes have scrolled past)
		if S.beat > S.songbeats + 1.5 then
			finish_song()
		end
	end
	dm.redraw()
end

-- ── drawing ──────────────────────────────────────────────────────────────────
local function field_geom()
	local W, H = dm.width(), dm.height()
	local topY = 30
	local hitY = H - 46
	local pfW = min(W - 40, 360)
	local x0 = floor((W - pfW) / 2)
	local laneW = pfW / C.LANES
	return W, H, topY, hitY, pfW, x0, laneW
end

local function draw_play()
	local W, H, topY, hitY, pfW, x0, laneW = field_geom()
	local fieldH = hitY - topY

	-- lane columns + cursor highlight
	for i = 0, C.LANES - 1 do
		local lx = x0 + i * laneW
		K.frame(lx, topY, laneW, fieldH, COL.panel, 120)
		if i == S.cursor then
			K.rect(lx + 1, topY + 1, laneW - 2, fieldH - 2, LANE_COL[i + 1], 18)
		end
	end

	-- the hit-line (glow = a few stacked low-alpha lines)
	for g = -2, 2 do
		K.line(x0, hitY + g, x0 + pfW, hitY + g, COL.white, 40 - abs(g) * 14)
	end
	K.line(x0, hitY, x0 + pfW, hitY, COL.white, 200)

	-- falling notes
	for _, n in ipairs(S.notes) do
		if not n.judged then
			local frac = (S.beat - n.beat + LEAD) / LEAD
			if frac > -0.1 and frac < 1.25 then
				local cy = topY + frac * fieldH
				local cx = x0 + (n.lane + 0.5) * laneW
				local c = LANE_COL[n.lane + 1]
				local r = max(6, laneW * 0.26)
				K.circle(cx, cy, r, c, 70)
				K.circle(cx, cy, r * 0.62, c, 230)
			end
		end
	end

	-- lane cursor paddle on the hit-line
	local cxp = x0 + S.cursor * laneW
	local cc = LANE_COL[S.cursor + 1]
	K.rect(cxp + 2, hitY - 4, laneW - 4, 8, cc, 230)
	K.rect(cxp + 2, hitY - 4, laneW - 4, 8, COL.white, 40)

	-- judgement flash above the hit-line
	if S.flash then
		local age = S.t - S.flash.t
		if age < 0.5 then
			local a = floor(255 * (1 - age / 0.5))
			K.textc(floor(W / 2), hitY - 26, S.flash.text, S.flash.c, a)
		end
	end

	-- HUD
	K.chrome("RHYTHM RUNNER", DIFF[S.diff].name, nil)
	K.textr(W - 10, 28, "BEST " .. best, COL.dim, 150)
	K.text(10, 28, "SCORE " .. S.score, COL.white, 230)
	if S.combo >= 2 then
		K.textc(floor(W / 2), 28, "COMBO " .. S.combo, COL.green, 220)
	end
	K.text(10, H - 12, snd.has and "SOUND" or "VISUAL", snd.has and COL.green or COL.dim, 150)
	K.textr(W - 10, H - 12, "[<>] lane  [*] hit  [back] quit", COL.dim, 150)

	-- progress bar
	local prog = K.clamp((S.beat + LEAD) / (S.songbeats + LEAD + 1.5), 0, 1)
	K.rect(0, H - 2, floor(W * prog), 2, COL.turq, 200)
end

local function draw_title()
	local W, H = dm.width(), dm.height()
	K.textc(floor(W / 2), floor(H * 0.22), "RHYTHM RUNNER", COL.turq, 240)
	K.textc(floor(W / 2), floor(H * 0.22) + 18, "hit the beat - notes play through the synth", COL.dim, 160)

	-- difficulty selector
	local d = DIFF[S.diff]
	K.textc(floor(W / 2), floor(H * 0.46), "[ " .. d.name .. " ]", COL.white, 230)
	K.textc(floor(W / 2), floor(H * 0.46) + 16, d.bpm .. " BPM", COL.dim, 170)

	-- a little 3-lane motif
	local cx, cy = floor(W / 2), floor(H * 0.60)
	for i = 0, 2 do
		K.circle(cx - 28 + i * 28, cy, 7, LANE_COL[i + 1], 220)
	end

	K.textc(floor(W / 2), floor(H * 0.74), "BEST  " .. best, COL.yellow, 200)
	K.textc(floor(W / 2), floor(H * 0.86), "[*] start    [<>] difficulty    [back] exit", COL.dim, 170)
	K.text(10, H - 12, snd.has and "SOUND" or "VISUAL (no synth voice)", snd.has and COL.green or COL.dim, 150)
end

local function draw_over()
	local W, H = dm.width(), dm.height()
	local total = #S.notes
	local acc = total > 0 and floor(100 * S.hits / total) or 0
	K.textc(floor(W / 2), floor(H * 0.20), "SONG COMPLETE", COL.turq, 240)
	if S.newbest then
		K.textc(floor(W / 2), floor(H * 0.20) + 18, "* NEW BEST *", COL.yellow, 230)
	end
	local rows = {
		{ "SCORE", tostring(S.score) },
		{ "MAX COMBO", tostring(S.maxcombo) },
		{ "ACCURACY", acc .. "%" },
		{ "PERFECT", tostring(S.perfects) },
		{ "MISS", tostring(S.misses) },
	}
	local y = floor(H * 0.36)
	for _, r in ipairs(rows) do
		K.text(floor(W / 2) - 80, y, r[1], COL.dim, 180)
		K.textr(floor(W / 2) + 80, y, r[2], COL.white, 230)
		y = y + 18
	end
	K.textc(floor(W / 2), floor(H * 0.88), "[*] play again    [back] menu", COL.dim, 180)
end

function on_draw()
	K.clear(COL.bg)
	if S.state == "play" then
		draw_play()
	elseif S.state == "over" then
		draw_over()
	else
		draw_title()
	end
	K.overlay(S.t)
end

math.randomseed(os.time())

-- test/attract boot: DEMOD_RHYTHM_STATE = play|over forces a starting screen so
-- the headless smoke test can render every state; SELFPLAY also auto-starts.
do
	local st = os.getenv("DEMOD_RHYTHM_STATE")
	if st == "play" or SELFPLAY then
		start_song()
	elseif st == "over" then
		start_song()
		S.score, S.maxcombo, S.hits, S.perfects, S.misses = 1234, 20, 18, 12, 2
		S.state = "over"
	end
end

io.stderr:write("[patch] RHYTHM up (sound=" .. tostring(snd.has) .. ")\n")
