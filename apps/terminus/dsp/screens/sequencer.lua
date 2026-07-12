-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/sequencer.lua — a piano-roll / step sequencer for synth slots.

  A pitch × step grid that drives a loaded synth slot via the already-shipped
  dsp.note_on/note_off, tempo-synced to the shared MIDI clock (midi/clock.lua):
  internal accumulator at the current BPM, or follows an external clock's steps.
  Patterns save/load as Standard MIDI Files via midi/smf.lua (write_notes/read_notes).

  One-step-cell model: a lit cell is a 1-step note; a held note loaded from a .mid
  lights the cells it spans. Chords = multiple lit rows in a column.

  Controls (drill-in focus, keyboard-complete — arrows / Enter / Esc / Tab):
    turn      move the cursor: STEP level = along time; PITCH level = the note row
    activate  STEP level: drill into the note row;  PITCH level: toggle the cell (+ audition)
    back      PITCH level: back to steps;  STEP level: open the command menu
              (length / target / octave / clear / save / load / stop+rewind)
    play_stop play / stop (Start button / footswitch / menu — never tab)
    tab       switch screens (always — never trapped);  wet  optional level-flip accelerator
  Note: playback runs while this screen is focused (transport is screen-local in v1);
  global-transport-synced playback pairs with the engine player node (a later phase).

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local LENGTHS = { 8, 16, 24, 32 }
local SEQDIR = os.getenv("DEMOD_SEQ_DIR") or ((os.getenv("HOME") or ".") .. "/.local/share/demod/patterns")

local HERE = (debug.getinfo(1, "S").source:gsub("^@", ""):match("(.*/)")) or "./"
local PP = dofile(HERE .. "../pattern_player.lua") -- shared note firing (also used by arrangement)

local M = { name = "SEQUENCER", short = "SEQ" }

local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function note_name(n)
	return NAMES[n % 12 + 1] .. tostring(n // 12 - 1)
end

local function st(ctx)
	if not ctx.S.seq then
		ctx.S.seq = {
			target = nil, -- synth slot index (resolved each frame)
			lo = 48, -- bottom MIDI note of the visible window (C3)
			len = 16,
			cur_step = 1,
			cur_note = 60, -- absolute MIDI note under the cursor
			axis = "time", -- "time" | "pitch"
			playing = false,
			head = 0, -- current playhead step (0 = none)
			acc = 0, -- internal step accumulator (s)
			last_ext = 0, -- last external-clock step index consumed
			cells = {}, -- cells[step] = { [note] = vel }
			pp = PP.new(), -- shared note-firing engine (tracks sounding notes)
			audition = nil, -- { note, off } a previewed note to release
			menu = false,
			msel = 1,
			step_scroll = 0,
		}
	end
	return ctx.S.seq
end

-- the first loaded synth slot (the thing we play); nil if none loaded
local function find_synth(ctx)
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and sl.kind == "synth" then
			return i
		end
	end
	return nil
end

local function cell_get(s, step, note)
	return s.cells[step] and s.cells[step][note]
end
local function cell_toggle(s, step, note)
	s.cells[step] = s.cells[step] or {}
	if s.cells[step][note] then
		s.cells[step][note] = nil
	else
		s.cells[step][note] = 0.8
	end
end

-- ── transport (note firing via the shared pattern_player) ────────────────────
local function advance(ctx, s)
	s.head = (s.head % s.len) + 1
	s.pp:step(ctx.dsp, s.target, s.cells, s.head)
end

local function transport_stop(ctx, s)
	s.playing = false
	s.pp:panic(ctx.dsp, s.target)
end

local function audition(ctx, s, note)
	if s.target and ctx.dsp.note_on then
		ctx.dsp.note_on(s.target, note, 100)
		s.audition = { note = note, off = (ctx.S.t or 0) + 0.18 }
	end
end

-- ── save / load (.mid) ────────────────────────────────────────────────────────
local function pattern_notes(s)
	local notes = {}
	for step, col in pairs(s.cells) do
		for note, vel in pairs(col) do
			notes[#notes + 1] = { note = note, step = step, len = 1, vel = vel }
		end
	end
	return notes
end

local function do_save(ctx, s)
	os.execute("mkdir -p " .. shq(SEQDIR) .. " 2>/dev/null")
	local bpm = (ctx.midi and ctx.midi.clock and ctx.midi.clock.bpm()) or ctx.S._bpm or 120
	local name = "pattern_" .. os.date("%Y%m%d_%H%M%S") .. ".mid"
	local ok = ctx.midi
		and ctx.midi.smf
		and ctx.midi.smf.write_notes(SEQDIR .. "/" .. name, { bpm = bpm, steps = s.len, notes = pattern_notes(s) })
	if ctx.toast then
		ctx.toast(ok and ("Saved " .. name) or "Save failed", ok and "ok" or "warn")
	end
end

local function do_load(ctx, s)
	local path
	local ok, p = pcall(function()
		local pipe = io.popen("ls -1t " .. shq(SEQDIR) .. "/*.mid 2>/dev/null")
		if pipe then
			local line = pipe:read("*l")
			pipe:close()
			return line
		end
	end)
	path = ok and p or nil
	if not path or not (ctx.midi and ctx.midi.smf) then
		if ctx.toast then
			ctx.toast("No patterns to load", "warn")
		end
		return
	end
	local ok2, res = ctx.midi.smf.read_notes(path)
	if not ok2 then
		if ctx.toast then
			ctx.toast("Load failed", "warn")
		end
		return
	end
	s.cells = {}
	s.len = math.max(8, math.min(32, res.steps or 16))
	for _, nt in ipairs(res.notes or {}) do
		for k = 0, math.max(0, (nt.len or 1) - 1) do
			local step = nt.step + k
			if step >= 1 and step <= s.len then
				s.cells[step] = s.cells[step] or {}
				s.cells[step][nt.note] = nt.vel or 0.8
			end
		end
	end
	if ctx.toast then
		ctx.toast("Loaded " .. (path:gsub(".*/", "")), "ok")
	end
end

-- ── per-frame transport ───────────────────────────────────────────────────────
function M.update(ctx, dt)
	local s = st(ctx)
	-- release a finished audition note
	if s.audition and (ctx.S.t or 0) >= s.audition.off then
		if ctx.dsp.note_off and s.target then
			ctx.dsp.note_off(s.target, s.audition.note)
		end
		s.audition = nil
	end
	if not s.playing then
		return
	end
	local clk = ctx.midi and ctx.midi.clock
	if clk and clk.source and clk.source() == "external" and clk.is_running() then
		-- follow the external clock's 16th-note steps (no own accumulator)
		local idx = clk.step_index()
		while s.last_ext < idx do
			s.last_ext = s.last_ext + 1
			advance(ctx, s)
		end
	else
		local bpm = (clk and clk.bpm()) or ctx.S._bpm or 120
		local step_dur = 60.0 / bpm / 4
		s.acc = s.acc + (dt or 0)
		while s.acc >= step_dur do
			s.acc = s.acc - step_dur
			advance(ctx, s)
		end
	end
	dm.redraw()
end

-- ── input ─────────────────────────────────────────────────────────────────────
local function menu_items(ctx, s)
	return {
		{
			s.playing and "STOP" or "PLAY",
			function()
				if s.playing then
					transport_stop(ctx, s)
				else
					s.playing, s.head, s.acc = true, 0, 0
					s.last_ext = (ctx.midi and ctx.midi.clock and ctx.midi.clock.step_index()) or 0
				end
			end,
		},
		{
			"LENGTH " .. s.len,
			function()
				for i, L in ipairs(LENGTHS) do
					if L == s.len then
						s.len = LENGTHS[(i % #LENGTHS) + 1]
						break
					end
				end
				s.head = math.min(s.head, s.len)
			end,
		},
		{
			"TARGET " .. (s.target and (ctx.dsp.slot(s.target).name or "?") or "none"),
			function()
				-- cycle through loaded synth slots
				local synths = {}
				for i = 1, ctx.dsp.slot_count() do
					local sl = ctx.dsp.slot(i)
					if sl and sl.loaded and sl.kind == "synth" then
						synths[#synths + 1] = i
					end
				end
				if #synths > 0 then
					local at = 1
					for i, v in ipairs(synths) do
						if v == s.target then
							at = i
						end
					end
					s.target = synths[(at % #synths) + 1]
				end
			end,
		},
		{
			"OCTAVE -",
			function()
				s.lo = math.max(0, s.lo - 12)
			end,
		},
		{
			"OCTAVE +",
			function()
				s.lo = math.min(108, s.lo + 12)
			end,
		},
		{
			"CLEAR",
			function()
				s.cells = {}
			end,
		},
		{
			"SAVE .mid",
			function()
				do_save(ctx, s)
			end,
		},
		{
			"LOAD .mid",
			function()
				do_load(ctx, s)
			end,
		},
		{
			"STOP + REWIND",
			function()
				transport_stop(ctx, s)
				s.head = 0
			end,
		},
	}
end

function M.nav(ctx, action)
	local s = st(ctx)

	if s.menu then -- command menu
		local items = menu_items(ctx, s)
		s.msel = math.max(1, math.min(#items, s.msel))
		if action == "next" then
			s.msel = (s.msel % #items) + 1
		elseif action == "prev" then
			s.msel = ((s.msel - 2) % #items) + 1
		elseif action == "activate" then
			items[s.msel][2]()
		elseif action == "back" or action == "wet" then
			s.menu = false
		else
			return false
		end
		return true
	end

	-- transport: Start button / footswitch / menu (NOT tab, so tab always switches screens)
	if action == "play_stop" then
		if s.playing then
			transport_stop(ctx, s)
		else
			s.playing, s.head, s.acc = true, 0, 0
			s.last_ext = (ctx.midi and ctx.midi.clock and ctx.midi.clock.step_index()) or 0
		end
		return true
	end

	-- drill-in focus (s.axis is the level): "time" = pick a step (column); "pitch" = drilled
	-- into that step to pick the note row + toggle. Enter descends, back ascends — fully
	-- keyboard-reachable (no "wet" needed). wet is an optional accelerator for the same flip.
	if s.axis == "pitch" then
		if action == "next" or action == "prev" then
			local d = (action == "next") and 1 or -1
			s.cur_note = math.max(0, math.min(127, s.cur_note + d))
			return true
		elseif action == "activate" then
			cell_toggle(s, s.cur_step, s.cur_note)
			if cell_get(s, s.cur_step, s.cur_note) then
				audition(ctx, s, s.cur_note)
			end
			return true
		elseif action == "back" or action == "wet" then
			s.axis = "time" -- ascend back to the step row
			return true
		end
		return false -- tab/tab_prev/play_stop fall through to the global handler
	end

	-- step level (default): move along time; Enter (or wet) drills into the note row
	if action == "next" or action == "prev" then
		local d = (action == "next") and 1 or -1
		s.cur_step = ((s.cur_step - 1 + d) % s.len) + 1
		return true
	elseif action == "activate" or action == "wet" then
		s.axis = "pitch" -- descend into the note row
		return true
	elseif action == "back" then
		s.menu, s.msel = true, 1
		return true
	end
	return false
end

-- ── drawing ────────────────────────────────────────────────────────────────────
function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	s.target = find_synth(ctx) and (s.target or find_synth(ctx)) or nil
	-- keep a stale target valid
	if s.target then
		local sl = ctx.dsp.slot(s.target)
		if not (sl and sl.loaded and sl.kind == "synth") then
			s.target = find_synth(ctx)
		end
	else
		s.target = find_synth(ctx)
	end

	-- header
	U.text(20, U.HEADER_Y, "SEQUENCER", C.turq, 220)
	local bpm = (ctx.midi and ctx.midi.clock and ctx.midi.clock.bpm()) or ctx.S._bpm or 120
	local tgt = s.target and (ctx.dsp.slot(s.target).name or "synth") or "no synth"
	U.text_r(
		W - 20,
		U.HEADER_Y,
		string.format("%s  %d BPM  %d steps%s", tgt, math.floor(bpm), s.len, s.playing and "  >PLAY" or ""),
		s.playing and C.green or C.dim,
		s.playing and 220 or 160
	)
	U.line(20, 74, W - 20, 74, C.border, 140)

	-- geometry
	local gutter = 38
	local gx0 = 20 + gutter
	local top = U.CONTENT_TOP
	local bot = H - 50
	local gridW = (W - 20) - gx0
	local rowH = 14
	local nrows = math.max(4, math.floor((bot - top) / rowH))
	-- auto-scroll the pitch window so the cursor stays visible
	if s.cur_note < s.lo then
		s.lo = s.cur_note
	elseif s.cur_note > s.lo + nrows - 1 then
		s.lo = s.cur_note - nrows + 1
	end
	s.lo = math.max(0, math.min(127 - nrows + 1, s.lo))

	-- horizontal step window (scroll for long patterns)
	local colW = math.max(12, math.floor(gridW / s.len))
	local vcols = math.min(s.len, math.floor(gridW / colW))
	if s.cur_step - 1 < s.step_scroll then
		s.step_scroll = s.cur_step - 1
	elseif s.cur_step - 1 > s.step_scroll + vcols - 1 then
		s.step_scroll = s.cur_step - vcols
	end
	s.step_scroll = math.max(0, math.min(s.step_scroll, math.max(0, s.len - vcols)))

	-- rows: high pitch at the top
	-- the cursor column (STEP level) faint band — shows you're selecting a step, not a note
	if s.axis == "time" then
		local cc = s.cur_step - 1 - s.step_scroll
		if cc >= 0 and cc < vcols then
			U.rect(gx0 + cc * colW, top, colW, nrows * rowH, C.turq, 22)
		end
	end
	for r = 0, nrows - 1 do
		local note = s.lo + (nrows - 1 - r)
		local y = top + r * rowH
		local black = (NAMES[note % 12 + 1]:find("#") ~= nil)
		-- piano-key shading + faint row line; C rows get a brighter gutter label
		U.rect(20, y, gutter - 2, rowH - 1, black and C.bg or C.panel, black and 200 or 120)
		U.rect(gx0, y, gridW, rowH - 1, black and C.panel or C.panel_hi, black and 60 or 30)
		if note % 12 == 0 or rowH >= 14 then
			U.text(22, y + 1, note_name(note), (note % 12 == 0) and C.dim or C.border, (note % 12 == 0) and 170 or 120)
		end
		-- the cursor row (pitch axis) faint band
		if note == s.cur_note then
			U.rect(gx0, y, gridW, rowH - 1, C.turq, 18)
		end
		-- cells
		for c = 0, vcols - 1 do
			local step = s.step_scroll + c + 1
			local x = gx0 + c * colW
			local lit = cell_get(s, step, note)
			local is_cur = (step == s.cur_step and note == s.cur_note)
			local is_head = (s.playing and step == s.head)
			if lit then
				local col = (note == s.cur_note) and C.turq or C.violet
				U.rect(x + 1, y + 1, colW - 2, rowH - 3, col, is_head and 255 or 210)
			end
			if is_head and not lit then
				U.rect(x + 1, y, colW - 2, rowH - 1, C.green, 26)
			end
			if is_cur then
				U.tline(x + 1, y, x + colW - 1, y, 1, C.turq, 230)
				U.tline(x + 1, y + rowH - 2, x + colW - 1, y + rowH - 2, 1, C.turq, 230)
				U.tline(x + 1, y, x + 1, y + rowH - 2, 2, C.turq, 230)
			end
		end
	end

	-- beat markers along the bottom (every 4 steps) + playhead tick
	local by = bot + 2
	for c = 0, vcols - 1 do
		local step = s.step_scroll + c + 1
		local x = gx0 + c * colW
		if (step - 1) % 4 == 0 then
			U.text(x + 2, by, tostring(step), C.dim, 130)
		end
		if s.playing and step == s.head then
			U.tline(x + 1, top - 2, x + colW - 1, top - 2, 2, C.green, 220)
		end
	end

	-- command menu overlay
	if s.menu then
		local items = menu_items(ctx, s)
		local mw, rh = 160, 20
		local mh = #items * rh + 24
		local mx, my = W - mw - 24, top + 6
		U.gradient_v(mx, my, mw, mh, C.panel_hi, C.panel)
		U.rect(mx, my, mw, mh, C.panel)
		U.tline(mx, my, mx + mw, my, 2, C.turq, 255)
		U.tline(mx, my + mh, mx + mw, my + mh, 2, C.turq, 255)
		U.text(mx + 10, my + 6, "SEQ MENU", C.turq, 230)
		for i, it in ipairs(items) do
			local iy = my + 22 + (i - 1) * rh
			local sel = (i == s.msel)
			if sel then
				U.rect(mx + 4, iy - 2, mw - 8, rh - 2, C.turq, 40)
				U.tline(mx + 4, iy - 2, mx + 4, iy + rh - 4, 3, C.turq, 255)
			end
			U.text(mx + 14, iy + 2, it[1], sel and C.white or C.dim, sel and 255 or 180)
		end
	end

	-- footer
	local hint
	if s.menu then
		hint = "turn: choose   sel: do   back: close menu"
	elseif not s.target then
		hint = "load a SYNTH (FX CHAIN) to hear it   |   turn: STEP   sel: pick note   back: menu"
	elseif s.axis == "pitch" then
		hint = "turn: NOTE   sel: place   back: steps   start: play   tab: screen"
	else
		hint = "turn: STEP   sel: pick note   back: menu   start: play   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
