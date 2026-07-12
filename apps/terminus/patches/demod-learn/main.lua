-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-learn/main.lua — LEARN: music from zero.

  A free, self-contained TERMINUS app-patch that teaches the fundamentals to
  someone who has never played: NOTES (pitch + tuner), RHYTHM (metronome + tap),
  SCALES/INTERVALS, and EAR (call-and-response play-along).

  Same focus-field model as the shell: one index, every input funnels through
  nav(). `back` returns to the previous screen, or to TERMINUS from the menu.

  Sound is BEST-EFFORT: if the dsp/midi_input bridge + a synth voice are present
  the lessons play notes; otherwise every lesson degrades to a fully usable
  visual-only mode (works headless and on any host). All theory lives in the
  pure, testable theory.lua — this file is UI only.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local T = dofile(HERE .. "theory.lua")

local floor, min, max, sin, abs = math.floor, math.min, math.max, math.sin, math.abs

-- ── phosphor palette (kept in sync with the ecosystem COL table) ─────────────
local COL = {
	bg = { 10, 10, 15 },
	panel = { 26, 30, 46 },
	black = { 12, 12, 18 },
	turq = { 0, 245, 212 },
	violet = { 139, 92, 246 },
	white = { 232, 232, 240 },
	dim = { 106, 106, 134 },
	green = { 76, 255, 130 },
	yellow = { 255, 217, 76 },
	red = { 255, 76, 106 },
}

-- ── thin draw wrappers (self-contained; no dependency on dsp/util.lua) ───────
local function rect(x, y, w, h, c, a)
	dm.draw.rect(floor(x), floor(y), floor(w), floor(h), c[1], c[2], c[3], a or 255)
end
local function line(x0, y0, x1, y1, c, a)
	dm.draw.line(floor(x0), floor(y0), floor(x1), floor(y1), c[1], c[2], c[3], a or 255)
end
local function frame(x, y, w, h, c, a) -- 1px border
	x, y, w, h = floor(x), floor(y), floor(w), floor(h)
	line(x, y, x + w, y, c, a)
	line(x, y + h, x + w, y + h, c, a)
	line(x, y, x, y + h, c, a)
	line(x + w, y, x + w, y + h, c, a)
end
local function text(x, y, s, c, a)
	dm.draw.text(floor(x), floor(y), s, c[1], c[2], c[3], a or 255)
end
local function textc(cx, y, s, c, a) -- centred (8px glyphs)
	text(cx - #s * 4, y, s, c, a)
end
local function textr(xr, y, s, c, a) -- right-aligned
	text(xr - #s * 8, y, s, c, a)
end

-- ── best-effort synth bridge (precedent: demod-duck-dance) ───────────────────
local MI = nil
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
		pcall(MI.open_jack_client, "demod-learn")
	end
end
local function note_on(n)
	if MI then
		pcall(MI.push_event, "secondary", { type = "note_on", note = floor(n + 0.5), vel = 0.8 })
	end
end
local function note_off(n)
	if MI then
		pcall(MI.push_event, "secondary", { type = "note_off", note = floor(n + 0.5) })
	end
end
local HAS_SOUND = MI ~= nil

-- ── shared state ─────────────────────────────────────────────────────────────
local ROOT = 60 -- C4: the keyboard's leftmost key
local KEYS = 13 -- one octave + top C (chromatic pc 0..12)
local SCREENS -- forward decl
local ORDER = { "pitch", "rhythm", "intervals", "ear" }

local S = {
	screen = "menu",
	t = 0,
	menu_focus = 1,
	sched = {}, -- { {t=abstime, fn=...}, ... } note scheduler
	lastlit = { n = -1, t = -9 }, -- most-recent sounding note (for key highlight)
	-- pitch
	kbfocus = 0,
	-- rhythm
	bpm = 90,
	beat_t = 0,
	beat_count = 0,
	beat_phase = 0,
	last_phase = 0,
	flash = 0,
	tap_msg = "",
	tap_col = COL.dim,
	-- intervals
	iv = 1,
	-- ear
	ear = nil,
}

-- ── note scheduler (drives scales / phrases / metronome clicks) ──────────────
local function sched_at(tt, fn)
	S.sched[#S.sched + 1] = { t = tt, fn = fn }
end
local function play_note(n, dur)
	note_on(n)
	S.lastlit = { n = n, t = S.t }
	sched_at(S.t + (dur or 0.45), function()
		note_off(n)
	end)
end
local function play_seq(notes, step, dur)
	local tt = S.t
	for _, n in ipairs(notes) do
		local nn = n
		sched_at(tt, function()
			note_on(nn)
			S.lastlit = { n = nn, t = S.t }
		end)
		sched_at(tt + (dur or step * 0.9), function()
			note_off(nn)
		end)
		tt = tt + step
	end
end
local function run_sched()
	if #S.sched == 0 then
		return
	end
	local keep = {}
	for _, e in ipairs(S.sched) do
		if e.t <= S.t then
			e.fn()
		else
			keep[#keep + 1] = e
		end
	end
	S.sched = keep
end

-- ── keyboard widget ──────────────────────────────────────────────────────────
-- chromatic pc 0..12 laid out as piano keys. opts: focus=pc, lit={[pc]=true}, label=bool
local WHITES = { 0, 2, 4, 5, 7, 9, 11, 12 }
local function key_layout(kx, ky, kw, kh)
	local lay = {}
	local nw = #WHITES
	local wkw = kw / nw
	for i, pc in ipairs(WHITES) do
		lay[pc] = { x = kx + (i - 1) * wkw, y = ky, w = wkw - 2, h = kh, black = false }
	end
	local bkw = wkw * 0.6
	for _, pc in ipairs({ 1, 3, 6, 8, 10 }) do
		local wi -- index of the white key just left of this black
		for i, p in ipairs(WHITES) do
			if p == pc - 1 then
				wi = i
			end
		end
		lay[pc] = { x = kx + wi * wkw - bkw / 2, y = ky, w = bkw, h = kh * 0.6, black = true }
	end
	return lay
end
local function playing_pc()
	if S.t - S.lastlit.t < 0.28 and S.lastlit.n >= 0 then
		return (floor(S.lastlit.n + 0.5) - ROOT) % 12
	end
	return nil
end
local function draw_keyboard(kx, ky, kw, kh, opts)
	opts = opts or {}
	local lay = key_layout(kx, ky, kw, kh)
	local pp = playing_pc()
	-- whites first
	for _, pc in ipairs(WHITES) do
		local k = lay[pc]
		local c = COL.panel
		if opts.lit and opts.lit[pc] then
			c = COL.violet
		end
		if pp == pc then
			c = COL.green
		end
		rect(k.x, k.y, k.w, k.h, c, pp == pc and 220 or 150)
		frame(k.x, k.y, k.w, k.h, COL.dim, 120)
	end
	-- blacks on top
	for _, pc in ipairs({ 1, 3, 6, 8, 10 }) do
		local k = lay[pc]
		local c = COL.black
		if opts.lit and opts.lit[pc] then
			c = COL.violet
		end
		if pp == pc then
			c = COL.green
		end
		rect(k.x, k.y, k.w, k.h, c, 255)
		frame(k.x, k.y, k.w, k.h, COL.dim, 140)
	end
	-- focus ring (drawn last so it's always visible)
	if opts.focus then
		local k = lay[opts.focus]
		if k then
			frame(k.x - 1, k.y - 1, k.w + 2, k.h + 2, COL.turq, 255)
			frame(k.x - 2, k.y - 2, k.w + 4, k.h + 4, COL.turq, 120)
			if opts.label then
				textc(k.x + k.w / 2, k.y + kh + 6, T.midi_to_name(ROOT + opts.focus), COL.turq, 255)
			end
		end
	end
	return lay
end

-- ── chrome ───────────────────────────────────────────────────────────────────
local function header(W, title)
	rect(0, 0, W, 30, COL.panel, 90)
	text(14, 8, "LEARN", COL.turq, 255)
	text(14 + 6 * 8, 8, "/ " .. title, COL.white, 220)
	textr(W - 14, 8, HAS_SOUND and "SOUND" or "VISUAL", HAS_SOUND and COL.green or COL.dim, 160)
end
local function footer(W, H, hint)
	rect(0, H - 26, W, 26, COL.panel, 70)
	text(14, H - 18, hint, COL.dim, 180)
	textr(W - 14, H - 18, "[< >] switch lesson", COL.dim, 140)
end

-- ════════════════════════════════════════════════════════════════════════════
-- SCREENS
-- ════════════════════════════════════════════════════════════════════════════
SCREENS = {}

-- ── MENU ─────────────────────────────────────────────────────────────────────
local MENU = {
	{ id = "pitch", name = "NOTES & TUNER", desc = "Hear notes, learn their names, match a pitch." },
	{ id = "rhythm", name = "RHYTHM & TIMING", desc = "Feel the beat. Tap in time with the metronome." },
	{ id = "intervals", name = "SCALES & INTERVALS", desc = "Which notes sound good together, and why." },
	{ id = "ear", name = "EAR / PLAY-ALONG", desc = "Listen to a phrase, then play it back." },
}
SCREENS.menu = {
	nav = function(a)
		if a == "next" then
			S.menu_focus = S.menu_focus % #MENU + 1
		elseif a == "prev" then
			S.menu_focus = (S.menu_focus - 2) % #MENU + 1
		elseif a == "activate" then
			SCREENS.go(MENU[S.menu_focus].id)
		end
	end,
	draw = function(W, H)
		header(W, "HOME")
		textc(W / 2, 44, "WELCOME -- pick where to start. No experience needed.", COL.dim, 180)
		local n = #MENU
		local ch = 52
		local gap = 12
		local total = n * ch + (n - 1) * gap
		local y0 = max(78, (H - total) / 2)
		for i, m in ipairs(MENU) do
			local y = y0 + (i - 1) * (ch + gap)
			local foc = i == S.menu_focus
			rect(40, y, W - 80, ch, foc and COL.panel or COL.bg, foc and 200 or 0)
			frame(40, y, W - 80, ch, foc and COL.turq or COL.dim, foc and 255 or 110)
			text(56, y + 8, tostring(i) .. ".", foc and COL.turq or COL.dim, 255)
			text(84, y + 8, m.name, foc and COL.white or COL.dim, 255)
			text(84, y + 28, m.desc, COL.dim, foc and 200 or 120)
		end
		footer(W, H, "[ up/down pick . activate open . back exit ]")
	end,
}

-- ── lesson: NOTES & TUNER ────────────────────────────────────────────────────
SCREENS.pitch = {
	enter = function()
		S.kbfocus = 0
	end,
	nav = function(a)
		if a == "next" then
			S.kbfocus = min(KEYS - 1, S.kbfocus + 1)
		elseif a == "prev" then
			S.kbfocus = max(0, S.kbfocus - 1)
		elseif a == "activate" then
			play_note(ROOT + S.kbfocus)
		end
	end,
	draw = function(W, H)
		header(W, "NOTES & TUNER")
		local note = ROOT + S.kbfocus
		textc(W / 2, 40, "This is " .. T.midi_to_name(note) .. " -- press activate to hear it.", COL.white, 220)
		-- live tuner panel (only meaningful when the engine feeds pitch back)
		local pr = (dm.params_read and dm.params_read()) or {}
		local ty = 64
		rect(40, ty, W - 80, 40, COL.panel, 70)
		frame(40, ty, W - 80, 40, COL.dim, 120)
		if pr.midi_note and pr.midi_note >= 0 and (pr.pitch_conf or 0) > 0.4 then
			local nearest, cents = T.cents_off(pr.pitch_hz)
			local cx = W / 2
			line(cx, ty + 6, cx, ty + 34, COL.dim, 120)
			local nx = cx + max(-1, min(1, (cents or 0) / 50)) * (W / 2 - 60)
			local ok = abs(cents or 0) < 8
			line(nx, ty + 6, nx, ty + 34, ok and COL.green or COL.yellow, 255)
			text(52, ty + 14, "HEARD " .. (nearest and T.midi_to_name(nearest) or "--"), COL.white, 220)
			textr(W - 52, ty + 14, string.format("%+d cents", floor((cents or 0) + 0.5)), ok and COL.green or COL.yellow, 220)
		else
			textc(W / 2, ty + 14, "TUNER: play/sing into the input to see if you are sharp or flat", COL.dim, 150)
		end
		local kh = min(150, H - 200)
		draw_keyboard(40, H - 60 - kh, W - 80, kh, { focus = S.kbfocus, label = true })
		footer(W, H, "[ left/right move . activate play note ]")
	end,
}

-- ── lesson: RHYTHM & TIMING ──────────────────────────────────────────────────
SCREENS.rhythm = {
	enter = function()
		S.beat_t, S.beat_count, S.last_phase, S.tap_msg = 0, 0, 0, ""
	end,
	update = function(dt)
		S.beat_t = S.beat_t + dt
		local ph = (S.beat_t * S.bpm / 60) % 1
		if ph < S.last_phase then -- crossed a beat
			S.beat_count = S.beat_count + 1
			S.flash = 1
			if HAS_SOUND then
				play_note(84 + ((S.beat_count % 4 == 1) and 4 or 0), 0.05) -- high click, accent the 1
			end
		end
		S.last_phase = ph
		S.beat_phase = ph
		S.flash = max(0, S.flash - dt * 4)
	end,
	nav = function(a)
		if a == "next" then
			S.bpm = min(240, S.bpm + 2)
		elseif a == "prev" then
			S.bpm = max(40, S.bpm - 2)
		elseif a == "activate" then
			local off = min(S.beat_phase, 1 - S.beat_phase) -- 0 = dead on
			if off < 0.08 then
				S.tap_msg, S.tap_col = "ON THE BEAT!", COL.green
			elseif S.beat_phase < 0.5 then
				S.tap_msg, S.tap_col = "a little LATE", COL.yellow
			else
				S.tap_msg, S.tap_col = "a little EARLY", COL.yellow
			end
		end
	end,
	draw = function(W, H)
		header(W, "RHYTHM & TIMING")
		textc(W / 2, 40, "Tap activate in time with the pulse. " .. S.bpm .. " BPM.", COL.white, 220)
		local cx, cy = W / 2, H / 2 - 6
		local base = min(W, H) * 0.18
		-- pulse ring: big on the beat, shrinking between
		local r = base * (1 + 0.5 * S.flash)
		for i = 0, 5 do
			dm.draw.circle(floor(cx), floor(cy), floor(r - i), COL.turq[1], COL.turq[2], COL.turq[3], floor(40 + 30 * S.flash))
		end
		dm.draw.circle(floor(cx), floor(cy), floor(base * 0.5), COL.violet[1], COL.violet[2], COL.violet[3], 200)
		-- 4 beat dots
		for b = 0, 3 do
			local on = (S.beat_count % 4) == b and S.flash > 0.3
			local bx = cx - 60 + b * 40
			dm.draw.circle(floor(bx), floor(cy + base + 28), 7, on and COL.green[1] or COL.dim[1], on and COL.green[2] or COL.dim[2], on and COL.green[3] or COL.dim[3], on and 255 or 140)
		end
		if S.tap_msg ~= "" then
			textc(cx, cy - base - 28, S.tap_msg, S.tap_col, 255)
		end
		footer(W, H, "[ left/right tempo . activate tap ]")
	end,
}

-- ── lesson: SCALES & INTERVALS ───────────────────────────────────────────────
SCREENS.intervals = {
	enter = function()
		S.iv = 1
	end,
	nav = function(a)
		if a == "next" then
			S.iv = S.iv % #T.INTERVALS + 1
		elseif a == "prev" then
			S.iv = (S.iv - 2) % #T.INTERVALS + 1
		elseif a == "activate" then
			local semi = T.INTERVALS[S.iv].semi
			play_seq({ ROOT, ROOT + semi }, 0.5, 0.45) -- root, then the interval
		end
	end,
	draw = function(W, H)
		header(W, "SCALES & INTERVALS")
		-- reference: a C major scale lit on the keyboard
		local lit = {}
		for _, s in ipairs(T.SCALES[1].steps) do
			lit[s] = true
		end
		lit[12] = true
		local iv = T.INTERVALS[S.iv]
		lit[0] = true
		lit[iv.semi % 12] = (iv.semi == 12) and lit[iv.semi % 12] or true
		textc(W / 2, 40, "Lit keys = C MAJOR scale. Pick an interval from the root C.", COL.dim, 180)
		-- interval picker
		textc(W / 2, 62, iv.name .. "  (" .. iv.semi .. " semitones)", COL.white, 255)
		textc(W / 2, 82, "[<]  " .. T.midi_to_name(ROOT) .. " + " .. T.midi_to_name(ROOT + iv.semi) .. "  [>]", COL.turq, 220)
		local kh = min(150, H - 210)
		draw_keyboard(40, H - 60 - kh, W - 80, kh, { lit = lit })
		footer(W, H, "[ left/right pick interval . activate play it ]")
	end,
}

-- ── lesson: EAR / PLAY-ALONG ─────────────────────────────────────────────────
local function ear_new(seed)
	local ph = T.phrase(seed, 4, T.SCALES[3], ROOT) -- pentatonic = friendly for beginners
	return { seed = seed, phrase = ph, answer = {}, result = "", focus = -1 } -- focus -1 = LISTEN button
end
SCREENS.ear = {
	enter = function()
		S.ear = ear_new(floor(S.t * 1000) % 100000 + 7)
		play_seq(S.ear.phrase, 0.5, 0.4) -- auto-play once on entry
	end,
	nav = function(a)
		local e = S.ear
		if a == "next" then
			e.focus = min(KEYS - 1, e.focus + 1)
		elseif a == "prev" then
			e.focus = max(-1, e.focus - 1)
		elseif a == "activate" then
			if e.focus == -1 then -- LISTEN: replay
				play_seq(e.phrase, 0.5, 0.4)
				return
			end
			local n = ROOT + e.focus
			play_note(n)
			e.answer[#e.answer + 1] = n
			if #e.answer >= #e.phrase then
				local hits = 0
				for i = 1, #e.phrase do
					if e.answer[i] == e.phrase[i] then
						hits = hits + 1
					end
				end
				if hits == #e.phrase then
					e.result = "PERFECT! New phrase..."
					S.ear = ear_new(e.seed + 1)
					sched_at(S.t + 0.7, function()
						play_seq(S.ear.phrase, 0.5, 0.4)
					end)
				else
					e.result = hits .. "/" .. #e.phrase .. " right -- try again"
					e.answer = {}
				end
			end
		end
	end,
	draw = function(W, H)
		header(W, "EAR / PLAY-ALONG")
		local e = S.ear
		textc(W / 2, 40, "LISTEN to the phrase, then play it back on the keys.", COL.white, 220)
		-- progress dots: one per phrase note
		local px = W / 2 - (#e.phrase - 1) * 12
		for i = 1, #e.phrase do
			local got = e.answer[i]
			local c = COL.dim
			if got then
				c = (got == e.phrase[i]) and COL.green or COL.red
			end
			dm.draw.circle(floor(px + (i - 1) * 24), 64, 6, c[1], c[2], c[3], 220)
		end
		if e.result ~= "" then
			textc(W / 2, 80, e.result, e.result:find("PERFECT") and COL.green or COL.yellow, 255)
		end
		-- LISTEN button (focus -1)
		local lb = e.focus == -1
		rect(W / 2 - 70, 96, 140, 22, lb and COL.panel or COL.bg, lb and 220 or 0)
		frame(W / 2 - 70, 96, 140, 22, lb and COL.turq or COL.dim, lb and 255 or 120)
		textc(W / 2, 102, "[ LISTEN AGAIN ]", lb and COL.turq or COL.dim, 255)
		local kh = min(140, H - 230)
		draw_keyboard(40, H - 60 - kh, W - 80, kh, { focus = e.focus >= 0 and e.focus or nil, label = e.focus >= 0 })
		footer(W, H, "[ left/right move . activate listen/play ]")
	end,
}

-- ── screen switch ────────────────────────────────────────────────────────────
function SCREENS.go(id)
	S.screen = id
	local sc = SCREENS[id]
	if sc and sc.enter then
		sc.enter()
	end
end

-- ════════════════════════════════════════════════════════════════════════════
-- INPUT FUNNEL
-- ════════════════════════════════════════════════════════════════════════════
local function switch_lesson(dir)
	-- cycle among the four lessons (used by tab / LB-RB)
	local cur = 1
	for i, id in ipairs(ORDER) do
		if id == S.screen then
			cur = i
		end
	end
	local nxt = ((cur - 1 + dir) % #ORDER) + 1
	SCREENS.go(ORDER[nxt])
end

local function nav(action)
	if action == "back" then
		if S.screen == "menu" then
			if dm.quit then
				dm.quit()
			end
		else
			S.menu_focus = 1
			S.screen = "menu"
		end
		return
	end
	if action == "tab" or action == "tab_prev" then
		if S.screen ~= "menu" then
			switch_lesson(action == "tab" and 1 or -1)
		end
		return
	end
	local sc = SCREENS[S.screen]
	if sc and sc.nav then
		sc.nav(action)
	end
end

-- desktop / serial encoder / gamepad
function on_nav(action)
	nav(action)
	dm.redraw()
end

-- demod5 i2c buttons + AS5600 encoder
function on_input(evt, btn, val)
	if evt == "DOWN" then
		if btn == "NAV_BACK" then
			nav("back")
		elseif btn == "NAV_UP" or btn == "NAV_PREV" then
			nav("prev")
		elseif btn == "NAV_DOWN" or btn == "NAV_NEXT" then
			nav("next")
		elseif btn == "ENC_PUSH" or btn == "NAV_OK" then
			nav("activate")
		end
	elseif evt == "ENC_CW" then
		nav("next")
	elseif evt == "ENC_CCW" then
		nav("prev")
	end
	dm.redraw()
end

function on_update(dt)
	S.t = S.t + dt
	run_sched()
	local sc = SCREENS[S.screen]
	if sc and sc.update then
		sc.update(dt)
	end
	dm.redraw()
end

function on_draw()
	local W, H = dm.width(), dm.height()
	rect(0, 0, W, H, COL.bg, 255)
	-- scanlines
	local off = (S.t * 14) % 4
	for y = 0, H, 4 do
		line(0, floor(y + off), W, floor(y + off), { 18, 18, 30 }, 26)
	end
	local sc = SCREENS[S.screen]
	if sc and sc.draw then
		sc.draw(W, H)
	end
end

-- deep-link: the home shell sets DEMOD_LEARN_LESSON to open a lesson directly
do
	local L = os.getenv("DEMOD_LEARN_LESSON")
	if L and L ~= "" and SCREENS[L] and L ~= "menu" then
		SCREENS.go(L)
	end
end

io.stderr:write("[patch] LEARN up (sound=" .. tostring(HAS_SOUND) .. ")\n")
