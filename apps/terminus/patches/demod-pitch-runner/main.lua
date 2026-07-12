-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/main.lua — PITCH RUNNER: learn any instrument.

  A Beat-Saber x Guitar-Hero note highway oriented toward learning a real
  instrument. Notes fly down lanes toward a hit-line; a bottom target view
  (keyboard or fretboard) shows exactly WHERE to play the next note. Two ways
  to hit, auto-selected:

   - PERFORM (demod5 device): play the note on ANY instrument; the pitch detector
     grades you on timing AND in-tune accuracy (cents). Monophonic.
   - PRACTICE (desktop / headless / no input): move the cursor to the lit target
     and press activate; graded on timing. Works everywhere.

  One focus field; every input funnels through nav(). `back` returns/quits. The
  pure music logic lives in instruments.lua + track.lua (+ LEARN's theory.lua);
  this file is UI + game state. Shared helpers come from ../games/gamekit.lua.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local K = dofile(HERE .. "../games/gamekit.lua")
local T = dofile(HERE .. "../demod-learn/theory.lua")
local INST = dofile(HERE .. "instruments.lua")
local TRK = dofile(HERE .. "track.lua")
local V = dofile(HERE .. "view.lua")
local SONGS = dofile(HERE .. "songs.lua")
local LAY = dofile(HERE .. "layout.lua")
V.init(K, T, INST)

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local COL = K.COL
local snd = K.sound("demod-pitch-runner")

local LEAD = 4 -- beats of runway visible above the hit-line
local LANE_COL = {
	COL.turq,
	COL.violet,
	COL.yellow,
	COL.green,
	{ 255, 150, 80 }, -- orange
	{ 90, 180, 255 }, -- blue
}

local DIFF = {
	{ name = "EASY", bpm = 70, dmul = 0.7 },
	{ name = "NORMAL", bpm = 96, dmul = 1.0 },
	{ name = "HARD", bpm = 132, dmul = 1.2 },
}

-- note-label notation; cycled in the menu and with `wet` during play, persisted
local NOTATION = {
	{ id = "tab", name = "Tab  (E:3)" },
	{ id = "note", name = "Notes  (C4)" },
	{ id = "staff", name = "Staff" },
}
local PREFS = K.load("demod-pitch-runner-prefs")

-- content = drills then riffs, flattened for the menu
local CONTENT = {}
for _, d in ipairs(SONGS.drills) do
	CONTENT[#CONTENT + 1] = { kind = "drill", ref = d, name = d.name }
end
for _, r in ipairs(SONGS.riffs) do
	CONTENT[#CONTENT + 1] = { kind = "riff", ref = r, name = r.name }
end

local SELFPLAY = os.getenv("DEMOD_PR_SELFPLAY") ~= nil
-- headless test hook: synthesize "perfect" pitch detection so the PERFORM grading
-- + tuner-draw path runs without an orchestrator (which is the only real source).
local FAKEPITCH = os.getenv("DEMOD_PR_FAKEPITCH") ~= nil

local S = {
	state = "menu", -- menu | play | over
	menurow = 1, -- 1 instrument, 2 content, 3 difficulty
	inst = 1,
	content = 1,
	diff = 2,
	notation = 1,
	t = 0,
	beat = 0,
	bpm = 96,
	bpb = 4,
	notes = {},
	songlen = 0,
	cursor = 60, -- PRACTICE target cursor (midi)
	score = 0,
	combo = 0,
	maxcombo = 0,
	hits = 0,
	perfects = 0,
	misses = 0,
	total = 0,
	offs = {},
	flash = nil,
	last_beat_floor = nil,
	-- pitch / perform
	perform_avail = false,
	force_practice = false,
	pitch_seen_t = -99,
	was_voiced = false,
	last_heard = -1,
	heard_note = nil,
	heard_cents = 0,
	best = 0,
	newbest = false,
}

for i, m in ipairs(NOTATION) do
	if m.id == PREFS.notation then
		S.notation = i
	end
end

local function mode_id()
	return NOTATION[S.notation].id
end
local function cycle_notation(d)
	S.notation = ((S.notation - 1 + d) % #NOTATION) + 1
	K.save("demod-pitch-runner-prefs", { notation = NOTATION[S.notation].id })
end

local function profile()
	return INST.PROFILES[S.inst]
end
local function content()
	return CONTENT[S.content]
end
local function eff_mode()
	return (S.perform_avail and not S.force_practice) and "perform" or "practice"
end
local function scale_by_id(id)
	for _, sc in ipairs(T.SCALES) do
		if sc.id == id then
			return sc
		end
	end
	return T.SCALES[1]
end

-- shift an authored melody by octaves so it sits inside the instrument range
local function transpose_into(notes, prof)
	local lo, hi = INST.range(prof)
	local out = {}
	for _, n in ipairs(notes) do
		local m = n.note
		while m < lo do
			m = m + 12
		end
		while m > hi do
			m = m - 12
		end
		out[#out + 1] = { beat = n.beat, note = m, dur = n.dur }
	end
	return out
end

-- ── start / finish a run ─────────────────────────────────────────────────────
local function build_notes()
	local prof = profile()
	local c = content()
	local d = DIFF[S.diff]
	if c.kind == "drill" then
		local lo = select(1, INST.range(prof))
		-- root = lowest C-relative scale root at or above the instrument's low note
		local root = lo
		local seed = (os.time() % 100000) + S.inst * 7 + S.content * 13 + math.random(1, 9999)
		return TRK.generate(seed, {
			profile = prof,
			scale = scale_by_id(c.ref.scale_id),
			root = root,
			bars = c.ref.bars,
			density = (c.ref.density or 0.8) * d.dmul,
		})
	else
		local song = { notes = transpose_into(c.ref.notes, prof) }
		return TRK.from_song(song, prof)
	end
end

local function start()
	local prof = profile()
	S.bpm = DIFF[S.diff].bpm
	S.notes = build_notes()
	S.total = #S.notes
	S.songlen = TRK.length(S.notes)
	S.beat = -S.bpb -- one bar count-in
	S.last_beat_floor = nil
	S.score, S.combo, S.maxcombo = 0, 0, 0
	S.hits, S.perfects, S.misses = 0, 0, 0
	S.offs = {}
	S.flash = nil
	S.newbest = false
	local lo, hi = INST.range(prof)
	S.cursor = S.notes[1] and S.notes[1].note or floor((lo + hi) / 2)
	S.best = tonumber(K.load("demod-pitch-runner-" .. prof.id .. "-" .. content().name).best) or 0
	S.state = "play"
end

local function finish()
	S.state = "over"
	for _, o in ipairs(S.offs) do
		snd.off(o.note)
	end
	S.offs = {}
	if S.score > S.best then
		S.best = S.score
		S.newbest = true
		K.save("demod-pitch-runner-" .. profile().id .. "-" .. content().name, { best = S.best })
	end
end

-- ── hit registration ─────────────────────────────────────────────────────────
local function play_off(note, dt)
	S.offs[#S.offs + 1] = { t = S.t + (dt or 0.22), note = note }
end

local function register(grade, note)
	note.judged, note.result = true, grade
	local base = (grade == "perfect") and 100 or 50
	local mult = 1 + floor(S.combo / 8)
	S.score = S.score + base * mult
	S.combo = S.combo + 1
	S.maxcombo = max(S.maxcombo, S.combo)
	S.hits = S.hits + 1
	if grade == "perfect" then
		S.perfects = S.perfects + 1
	end
	snd.on(note.note, grade == "perfect" and 0.9 or 0.7)
	play_off(note.note)
	S.flash = { text = grade:upper() .. "!  x" .. mult, t = S.t, c = (grade == "perfect") and COL.turq or COL.green }
end

local function find_target(pitch, octave_ok)
	local good_b = TRK.WINDOW.good * S.bpm / 60
	local hit, hd = nil, 1e9
	for _, n in ipairs(S.notes) do
		if not n.judged then
			local same = octave_ok and (n.note % 12 == pitch % 12) or (n.note == pitch)
			if same then
				local d = abs(n.beat - S.beat)
				if d < hd then
					hd, hit = d, n
				end
			end
		end
	end
	if hit and hd <= good_b then
		return hit
	end
	return nil
end

local function perform_hit(pitch, cents)
	local n = find_target(pitch, profile().octave_ok)
	if n then
		local g = TRK.judge(n.beat - S.beat, cents, S.bpm)
		if g ~= "miss" then
			register(g, n)
			return
		end
	end
end

local function practice_strike()
	-- nearest unjudged note in the timing window, any pitch
	local good_b = TRK.WINDOW.good * S.bpm / 60
	local near, nd = nil, 1e9
	for _, n in ipairs(S.notes) do
		if not n.judged then
			local d = abs(n.beat - S.beat)
			if d < nd then
				nd, near = d, n
			end
		end
	end
	if near and nd <= good_b then
		if near.note == S.cursor then
			register(TRK.judge(near.beat - S.beat, nil, S.bpm), near)
		else
			S.flash = { text = "WRONG NOTE", t = S.t, c = COL.red }
		end
	else
		S.flash = { text = "--", t = S.t, c = COL.dim }
	end
end

-- ── input funnel ─────────────────────────────────────────────────────────────
local function move_cursor(d)
	local lo, hi = INST.range(profile())
	S.cursor = max(lo, min(hi, S.cursor + d))
end

local function nav(action)
	if S.state == "menu" then
		if action == "tab" then
			S.menurow = (S.menurow % 4) + 1
		elseif action == "tab_prev" then
			S.menurow = ((S.menurow - 2) % 4) + 1
		elseif action == "next" or action == "prev" then
			local d = (action == "next") and 1 or -1
			if S.menurow == 1 then
				S.inst = ((S.inst - 1 + d) % #INST.PROFILES) + 1
			elseif S.menurow == 2 then
				S.content = ((S.content - 1 + d) % #CONTENT) + 1
			elseif S.menurow == 3 then
				S.diff = ((S.diff - 1 + d) % #DIFF) + 1
			else
				cycle_notation(d)
			end
		elseif action == "activate" then
			start()
		elseif action == "back" then
			if dm.quit then
				dm.quit()
			end
		end
	elseif S.state == "play" then
		if action == "prev" then
			move_cursor(-1)
		elseif action == "next" then
			move_cursor(1)
		elseif action == "activate" then
			practice_strike()
		elseif action == "wet" then
			cycle_notation(1)
		elseif action == "tab" then
			S.force_practice = not S.force_practice
		elseif action == "back" then
			S.state = "menu"
		end
	elseif S.state == "over" then
		if action == "activate" then
			start()
		elseif action == "back" then
			S.state = "menu"
		end
	end
	dm.redraw()
end

function on_nav(action)
	nav(action)
end
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
local function fake_params()
	if FAKEPITCH and S.state == "play" and S.beat >= 0 then
		local soon, sd = nil, 1e9
		for _, n in ipairs(S.notes) do
			if not n.judged then
				local d = n.beat - S.beat
				if d >= -0.05 and d < sd then
					sd, soon = d, n
				end
			end
		end
		if soon and abs(soon.beat - S.beat) <= 0.04 then
			return { midi_note = soon.note, pitch_conf = 0.9, pitch_hz = T.midi_to_freq(soon.note) }
		end
	end
	return { midi_note = -1, pitch_conf = 0, pitch_hz = 0 }
end

local function read_pitch()
	local pr = FAKEPITCH and fake_params() or (dm.params_read and dm.params_read() or nil)
	if pr and (pr.midi_note or -1) >= 0 and (pr.pitch_conf or 0) > 0.4 then
		local heard = pr.midi_note
		S.pitch_seen_t = S.t
		local _, cents = T.cents_off(pr.pitch_hz or 0)
		S.heard_note, S.heard_cents = heard, cents or 0
		local onset = (not S.was_voiced) or (heard ~= S.last_heard)
		if onset and eff_mode() == "perform" and S.state == "play" and S.beat >= 0 then
			perform_hit(heard, cents)
		end
		S.was_voiced, S.last_heard = true, heard
	else
		S.was_voiced, S.heard_note = false, nil
	end
	S.perform_avail = (pr ~= nil) and ((S.t - S.pitch_seen_t) < 2.0)
end

function on_update(dt)
	S.t = S.t + dt
	read_pitch()

	if S.state == "play" then
		S.beat = S.beat + dt * S.bpm / 60

		-- metronome click on each integer beat (count-in + play)
		local bf = floor(S.beat)
		if bf ~= S.last_beat_floor then
			S.last_beat_floor = bf
			if snd.has and DIFF[S.diff].name ~= "HARD" then
				snd.on(84 + ((bf % S.bpb == 0) and 4 or 0), 0.04)
				play_off(84 + ((bf % S.bpb == 0) and 4 or 0), 0.05)
			end
		end

		-- self-play (PRACTICE) for the headless smoke test: aim + strike on the line
		if SELFPLAY and S.beat >= 0 then
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
				S.cursor = soon.note
				if abs(soon.beat - S.beat) <= 0.03 then
					practice_strike()
				end
			end
		end

		-- reference preview: sound each note softly as it enters the runway (drills, not HARD)
		if snd.has and content().kind == "drill" and DIFF[S.diff].name ~= "HARD" then
			for _, n in ipairs(S.notes) do
				if not n.previewed and (S.beat - n.beat + LEAD) >= 0 then
					n.previewed = true
					if n.beat >= S.beat then
						snd.on(n.note, 0.2)
						play_off(n.note, 0.12)
					end
				end
			end
		end

		-- auto-miss notes that slipped past the line
		local good_b = TRK.WINDOW.good * S.bpm / 60
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

		if S.beat > S.songlen + 1.5 then
			finish()
		end
	end
	dm.redraw()
end

-- ── drawing ──────────────────────────────────────────────────────────────────
local function draw_play()
	local W, H = dm.width(), dm.height()
	local prof = profile()
	local mode = mode_id()
	local em = eff_mode()
	local lanes = INST.lanes(prof)
	local L = LAY.compute(W, H, lanes)
	local hw = L.hw

	-- next unjudged note (drives the NEXT chip + the target view)
	local target = nil
	for _, n in ipairs(S.notes) do
		if not n.judged then
			target = n.note
			break
		end
	end

	-- chrome + info row
	K.chrome("PITCH RUNNER", V.ellipsize(prof.name .. " - " .. (em == "perform" and "PERFORM" or "PRACTICE"), 260), nil)
	K.text(L.info.score_x, L.info.y, "SCORE " .. S.score, COL.white, 230)
	if S.combo >= 2 then
		K.textc(L.info.cx, L.info.y, "x" .. (1 + floor(S.combo / 8)) .. "  COMBO " .. S.combo, COL.green, 220)
	end
	K.textr(L.info.best_x, L.info.y, "BEST " .. S.best, COL.dim, 160)

	-- playfield panel + NEXT chip
	V.panel(L.play.x, L.play.y, L.play.w, L.play.h, COL.turq, 26)
	if target then
		if mode == "staff" then
			V.staff(L.nextchip.cx - 66, L.nextchip.y, 132, (L.bucket == "compact") and 18 or 24, target, COL.violet)
		else
			V.bigc(L.nextchip.cx, L.nextchip.y + ((L.bucket == "compact") and 1 or 3), "NEXT  " .. V.label(prof, target, mode), COL.violet, 245)
		end
	end

	-- lane separators
	for i = 0, lanes do
		local lx = hw.x + i * hw.laneW
		K.line(lx, hw.y, lx, hw.hitY + 6, COL.panel, 70)
	end
	-- hit-line glow + on-beat pulse
	local ph = S.beat - floor(S.beat)
	local pulse = floor(60 * max(0, 1 - ph * 3))
	V.glowline(hw.x, hw.hitY, hw.x + hw.w, hw.hitY, COL.white, min(255, 150 + pulse), 3)
	-- lane identity tags under the hit-line (string letters / register)
	for i = 0, lanes - 1 do
		K.textc(hw.x + (i + 0.5) * hw.laneW, L.lanetag_y, V.lane_label(prof, i), COL.dim, 150)
	end

	-- falling notes + trails + labels
	local nr = max(5, min((L.bucket == "compact") and 11 or 15, floor(hw.laneW * 0.20)))
	for _, n in ipairs(S.notes) do
		if not n.judged then
			local frac = (S.beat - n.beat + LEAD) / LEAD
			if frac > -0.1 and frac < 1.18 then
				local cy = hw.y + frac * (hw.hitY - hw.y)
				local cx = hw.x + (n.lane + 0.5) * hw.laneW
				local c = LANE_COL[(n.lane % #LANE_COL) + 1]
				for tt = 1, 3 do -- motion trail
					local ty = cy - tt * nr * 0.7
					if ty > hw.y then
						K.circle(cx, ty, max(1, floor(nr * (1 - tt * 0.24))), c, floor(38 * (1 - tt * 0.3)))
					end
				end
				K.circle(cx, cy, nr, c, 80)
				K.circle(cx, cy, floor(nr * 0.6), c, 235)
				if frac < 0.86 then -- the imminent note is already in the NEXT chip
					local a = floor(120 + 120 * min(1, frac + 0.2))
					K.textc(cx, cy - nr - 8, V.label(prof, n.note, mode == "staff" and "note" or mode), c, a)
				end
			end
		end
	end

	-- count-in (pulsing ring + count)
	if S.beat < 0 then
		local n = floor(-S.beat) + 1
		local pp = 1 - (S.beat - floor(S.beat))
		local mcy = floor(hw.y + (hw.hitY - hw.y) * 0.5)
		K.textc(floor(W / 2), mcy - 52, "GET READY", COL.dim, 200)
		K.circle(floor(W / 2), mcy, floor(12 + 22 * pp), COL.turq, floor(40 + 70 * (1 - pp)))
		V.bigc(floor(W / 2), mcy - 22, tostring(n), COL.turq, 245, 3)
	end

	-- judgement flash (rises + fades)
	if S.flash then
		local age = S.t - S.flash.t
		if age < 0.5 then
			V.bigc(floor(W / 2), hw.hitY - 44 - floor(age * 22), S.flash.text, S.flash.c, floor(255 * (1 - age / 0.5)), 2)
		end
	end

	-- target view panel (keyboard / fretboard)
	V.panel(L.tv.x, L.tv.y, L.tv.w, L.tv.h, COL.violet, 22)
	local tp = (L.bucket == "compact") and 7 or 12
	V.draw(prof, L.tv.x + tp, L.tv.y + tp, L.tv.w - 2 * tp, L.tv.h - 2 * tp, {
		target = target,
		cursor = (em == "practice") and S.cursor or nil,
		playing = S.heard_note,
		label = true,
		mode = mode,
		bucket = L.bucket,
	})

	-- footer: tuner (perform) or hints (centred, never clipped)
	if em == "perform" then
		local ty = L.foot.y + 6
		if S.heard_note then
			local cents = S.heard_cents or 0
			local half = floor(min(W * 0.4, 240))
			local nx = floor(W / 2) + max(-1, min(1, cents / 50)) * half
			K.line(floor(W / 2), ty, floor(W / 2), ty + 10, COL.dim, 120)
			for tk = -50, 50, 25 do
				local tx = floor(W / 2) + (tk / 50) * half
				K.line(tx, ty + 3, tx, ty + 7, COL.dim, 80)
			end
			K.line(nx, ty, nx, ty + 10, abs(cents) < 12 and COL.green or COL.yellow, 255)
			K.textc(floor(W / 2), ty + 12, T.midi_to_name(S.heard_note) .. string.format("  %+d c", floor(cents + 0.5)), COL.dim, 175)
		else
			K.textc(floor(W / 2), L.foot.cy - 4, "play a note on your instrument...", COL.dim, 150)
		end
	else
		local hint = (L.bucket == "compact") and "<> note   * play   wet notn"
			or "[<>] note    [*] play    [wet] notation    [tab] mode"
		K.textc(floor(W / 2), L.foot.cy - 4, hint, COL.dim, 160)
	end

	-- progress along the very bottom
	local prog = K.clamp((S.beat + LEAD) / (S.songlen + LEAD + 1.5), 0, 1)
	K.rect(0, H - 2, floor(W * prog), 2, COL.turq, 200)
end

local function draw_menu()
	local W, H = dm.width(), dm.height()
	local prof = profile()
	local L = LAY.compute(W, H, INST.lanes(prof))
	local b = L.bucket
	local mode = mode_id()

	-- title (real crisp scale-2 on standard/wide)
	local tsc = (b == "compact") and 1 or 2
	V.bigc(floor(W / 2), L.header.h + (b == "compact" and 6 or 12), "PITCH RUNNER", COL.violet, 245, tsc)
	K.textc(floor(W / 2), L.header.h + (b == "compact" and 22 or 52), "learn any instrument - play in time and in tune", COL.dim, 160)

	-- menu card
	local card = { x = floor(W * (b == "compact" and 0.04 or 0.17)), y = floor(H * 0.22) }
	card.w = W - 2 * card.x
	card.h = floor(H * (b == "compact" and 0.46 or 0.40))
	V.panel(card.x, card.y, card.w, card.h, COL.turq, 30)

	local rows = {
		{ "INSTRUMENT", prof.name },
		{ "PRACTICE", V.ellipsize(content().name, card.w * 0.45) .. "  (" .. content().kind .. ")" },
		{ "DIFFICULTY", DIFF[S.diff].name .. "  " .. DIFF[S.diff].bpm .. " BPM" },
		{ "NOTATION", NOTATION[S.notation].name },
	}
	local rh = floor(card.h / (#rows + 0.5))
	local y = card.y + floor(rh * 0.5)
	for i, r in ipairs(rows) do
		local sel = (i == S.menurow)
		if sel then
			K.rect(card.x + 6, y - 2, card.w - 12, rh - 4, COL.turq, 22)
		end
		K.text(card.x + 26, y, r[1], sel and COL.turq or COL.dim, sel and 235 or 160)
		K.textr(card.x + card.w - 20, y, r[2], COL.white, sel and 245 or 185)
		if sel then
			K.text(card.x + 12, y, ">", COL.turq, 240)
		end
		y = y + rh
	end

	-- live preview: instrument view + a sample note in the chosen notation
	local lo, hi = INST.range(prof)
	local sample = floor((lo + hi) / 2)
	local pv = { x = floor(W * 0.12), y = card.y + card.h + (b == "compact" and 6 or 16), w = floor(W * 0.76) }
	pv.h = floor(H * (b == "compact" and 0.16 or 0.15))
	if pv.y + pv.h + 14 < L.foot.y then
		V.draw(prof, pv.x, pv.y, pv.w, pv.h, { target = sample, mode = mode, bucket = b })
		if mode == "staff" then
			V.staff(floor(W / 2 - 60), pv.y + pv.h + 1, 120, 20, sample, COL.violet)
		else
			K.textc(floor(W / 2), pv.y + pv.h + 4, "shows as:  " .. V.label(prof, sample, mode), COL.violet, 220)
		end
	end

	K.textc(floor(W / 2), L.foot.y + 2, "[tab] row    [<>] change    [*] start    [back] exit", COL.dim, 170)
	local m = S.perform_avail and "PERFORM ready - instrument detected" or "PRACTICE - on-screen (no pitch input)"
	K.textc(floor(W / 2), L.foot.y + 18, m, S.perform_avail and COL.green or COL.dim, 150)
end

local function draw_over()
	local W, H = dm.width(), dm.height()
	local L = LAY.compute(W, H, 6)
	local b = L.bucket
	local total = S.total
	local acc = total > 0 and floor(100 * S.hits / total) or 0
	local intune = S.hits > 0 and floor(100 * S.perfects / S.hits) or 0
	local grade = acc >= 95 and "S" or acc >= 85 and "A" or acc >= 70 and "B" or acc >= 50 and "C" or "D"
	local gc = (grade == "S" or grade == "A") and COL.green
		or (grade == "B" and COL.turq or (grade == "C" and COL.yellow or COL.red))

	local card = { x = floor(W * (b == "compact" and 0.06 or 0.30)) }
	card.w = W - 2 * card.x
	card.h = floor(H * (b == "compact" and 0.82 or 0.46))
	card.y = floor((H - card.h) / 2)
	V.panel(card.x, card.y, card.w, card.h, COL.turq, 34)

	V.bigc(floor(W / 2), card.y + (b == "compact" and 8 or 16), "RUN COMPLETE", COL.turq, 245)
	if S.newbest then
		K.textc(floor(W / 2), card.y + (b == "compact" and 24 or 36), "* NEW BEST *", COL.yellow, 230)
	end

	-- grade badge
	local gy = card.y + (b == "compact" and 38 or 58)
	K.frame(floor(W / 2 - 20), gy, 40, 32, gc, 210)
	V.bigc(floor(W / 2), gy, grade, gc, 245, 2)

	-- numeric stats
	local y = gy + (b == "compact" and 42 or 48)
	for _, r in ipairs({ { "SCORE", S.score }, { "MAX COMBO", S.maxcombo }, { "MISS", S.misses } }) do
		K.text(card.x + 30, y, r[1], COL.dim, 180)
		K.textr(card.x + card.w - 30, y, tostring(r[2]), COL.white, 235)
		y = y + 18
	end

	-- accuracy bars
	y = y + 6
	local function bar(label, val, c)
		K.text(card.x + 30, y, label, COL.dim, 180)
		K.textr(card.x + card.w - 30, y, val .. "%", c, 230)
		local bx, bw, by = card.x + 30, card.w - 60, y + 12
		K.frame(bx, by, bw, 8, COL.panel, 200)
		K.rect(bx, by, floor(bw * val / 100), 8, c, 225)
		y = y + 28
	end
	bar("ACCURACY", acc, COL.turq)
	bar("CLEAN HITS", intune, COL.green)

	K.textc(floor(W / 2), L.foot.cy - 4, "[*] again      [back] menu", COL.dim, 180)
end

function on_draw()
	K.clear(COL.bg)
	if S.state == "play" then
		draw_play()
	elseif S.state == "over" then
		draw_over()
	else
		draw_menu()
	end
	K.overlay(S.t)
end

math.randomseed(os.time())

-- test/attract boot hooks (headless smoke): force a state + optional instrument
do
	local inst = os.getenv("DEMOD_PR_INST")
	if inst then
		for i, p in ipairs(INST.PROFILES) do
			if p.id == inst then
				S.inst = i
			end
		end
	end
	local cid = os.getenv("DEMOD_PR_CONTENT")
	if cid then
		for i, c in ipairs(CONTENT) do
			if c.ref.id == cid then
				S.content = i
			end
		end
	end
	local nid = os.getenv("DEMOD_PR_NOTATION")
	if nid then
		for i, m in ipairs(NOTATION) do
			if m.id == nid then
				S.notation = i
			end
		end
	end
	local st = os.getenv("DEMOD_PR_STATE")
	if st == "play" or SELFPLAY then
		start()
	elseif st == "over" then
		start()
		S.score, S.maxcombo, S.hits, S.perfects, S.misses, S.total = 940, 18, 22, 14, 3, 25
		S.state = "over"
	end
end

io.stderr:write("[patch] PITCH RUNNER up (sound=" .. tostring(snd.has) .. ")\n")
