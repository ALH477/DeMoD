-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/arrange.lua — the song / arrangement editor (DAW phase 4).

  Track lanes (rows) of clips on a bar grid (columns). Edits the model in
  ctx.arrangement (dsp/arrangement.lua), which is the MASTER TRANSPORT — the song
  keeps playing when you leave this screen. Clip kinds: pattern (.mid → a synth slot),
  automation (a script → fires on entry), take (audio → best-effort out-of-engine).

  Controls (drill-in focus, same grammar as SEQUENCER / MIXER — arrows / Enter / Esc / Tab):
    turn      move the cursor: TRACK level = pick a lane; BAR level = pick a bar
    activate  TRACK level: drill into the lane's bars;  BAR level: clip menu / source picker
    back      BAR level: back to lanes;  TRACK level: open the command menu
              (add track / length / bpm / loop / save / load / clear / stop+rewind)
    play_stop play / stop (Start button / footswitch / menu — never tab)
    tab       switch screens (always — never trapped);  wet  optional level-flip accelerator

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local SEQDIR = os.getenv("DEMOD_SEQ_DIR") or ((os.getenv("HOME") or ".") .. "/.local/share/demod/patterns")
local LENGTHS = { 8, 16, 32, 64 }
local KIND_GLYPH = { pattern = "P", automation = "A", take = "T" }

local M = { name = "ARRANGE", short = "ARR" }

local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function st(ctx)
	ctx.S.arr = ctx.S.arr
		or { mode = "grid", axis = "tracks", cur_track = 1, cur_bar = 1, bar_scroll = 0, trk_scroll = 0, msel = 1 }
	return ctx.S.arr
end

local function first_synth(ctx)
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and sl.kind == "synth" then
			return i
		end
	end
	return nil
end

local function synth_slots(ctx)
	local out = {}
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and sl.kind == "synth" then
			out[#out + 1] = i
		end
	end
	return out
end

local function ls_names(dir, pat)
	local out = {}
	local ok, p = pcall(io.popen, "ls -1t " .. shq(dir) .. "/" .. pat .. " 2>/dev/null")
	if ok and p then
		for line in p:lines() do
			local n = line:match("([^/]+)$")
			if n then
				out[#out + 1] = n
			end
		end
		p:close()
	end
	return out
end

local function clip_at(track, bar)
	for _, c in ipairs(track.clips or {}) do
		if bar >= c.start_bar and bar < c.start_bar + c.len_bars then
			return c
		end
	end
	return nil
end

-- ── source picker ─────────────────────────────────────────────────────────────
local function open_picker(ctx, kind, onpick)
	local s = st(ctx)
	local list
	if kind == "pattern" then
		list = ls_names(SEQDIR, "*.mid")
	elseif kind == "automation" then
		list = {}
		for _, sc in ipairs((ctx.automation and ctx.automation.scripts) or {}) do
			list[#list + 1] = sc.name
		end
	else -- take
		list = (ctx.record and ctx.record.recent_takes(20)) or {}
	end
	s.picker = { kind = kind, list = list, sel = 1, onpick = onpick }
	s.mode = "picker"
end

-- ── command menu (context-sensitive on cur_track) ─────────────────────────────
local function add_track(ctx, kind)
	local A = ctx.arrangement
	local target = (kind == "pattern") and first_synth(ctx) or nil
	local n = A.add_track(kind, kind:upper():sub(1, 4), target)
	st(ctx).cur_track = n
end

local function menu_items(ctx)
	local A = ctx.arrangement
	local s = st(ctx)
	local song = A.song
	local playing = A.is_playing()
	local items = {
		{
			playing and "STOP" or "PLAY",
			function()
				if playing then
					A.stop()
				else
					A.play()
				end
			end,
		},
		{
			"+ PATTERN TRK",
			function()
				add_track(ctx, "pattern")
			end,
		},
		{
			"+ AUTOMATION TRK",
			function()
				add_track(ctx, "automation")
			end,
		},
		{
			"+ TAKE TRK",
			function()
				add_track(ctx, "take")
			end,
		},
		{
			"LENGTH " .. song.len_bars,
			function()
				for i, L in ipairs(LENGTHS) do
					if L == song.len_bars then
						A.set_len(LENGTHS[(i % #LENGTHS) + 1])
						return
					end
				end
				A.set_len(16)
			end,
		},
		{
			"BPM -",
			function()
				A.set_bpm(song.bpm - 1)
			end,
		},
		{
			"BPM +",
			function()
				A.set_bpm(song.bpm + 1)
			end,
		},
		{
			song.loop.on and "LOOP ON" or "LOOP OFF",
			function()
				A.set_loop(not song.loop.on, 1, song.len_bars)
			end,
		},
		{
			"SAVE",
			function()
				local ok, name = A.save()
				if ctx.toast then
					ctx.toast(ok and ("Saved " .. name) or "Save failed", ok and "ok" or "warn")
				end
			end,
		},
		{
			"LOAD RECENT",
			function()
				if ctx.toast then
					ctx.toast(A.load_recent() and "Loaded song" or "No songs", "info")
				end
				s.cur_track, s.cur_bar = 1, 1
			end,
		},
		{
			"NEW / CLEAR",
			function()
				A.new_song()
				s.cur_track, s.cur_bar = 1, 1
			end,
		},
		{
			"RELOAD PATTERNS",
			function()
				A.reload_patterns()
				if ctx.toast then
					ctx.toast("Pattern cache cleared", "info")
				end
			end,
		},
	}
	local trk = song.tracks[s.cur_track]
	if trk then
		items[#items + 1] = {
			(trk.mute and "UNMUTE" or "MUTE") .. " TRK",
			function()
				trk.mute = not trk.mute
			end,
		}
		if trk.kind == "pattern" then
			items[#items + 1] = {
				"TRK TARGET " .. (trk.target and ("slot" .. trk.target) or "-"),
				function()
					local sy = synth_slots(ctx)
					if #sy > 0 then
						local at = 1
						for i, v in ipairs(sy) do
							if v == trk.target then
								at = i
							end
						end
						trk.target = sy[(at % #sy) + 1]
					end
				end,
			}
		end
		items[#items + 1] = {
			"DELETE TRK",
			function()
				A.remove_track(s.cur_track)
				s.cur_track = math.max(1, s.cur_track - 1)
			end,
		}
	end
	items[#items + 1] = {
		"STOP + REWIND",
		function()
			A.stop()
			A.seek(1)
			s.cur_bar = 1
		end,
	}
	return items
end

-- ── clip menu ─────────────────────────────────────────────────────────────────
local function clip_menu_items(ctx, track, clip)
	local A = ctx.arrangement
	local s = st(ctx)
	local items = {
		{
			"LEN -",
			function()
				clip.len_bars = math.max(1, clip.len_bars - 1)
			end,
		},
		{
			"LEN +",
			function()
				clip.len_bars = clip.len_bars + 1
			end,
		},
		{
			"MOVE",
			function()
				s.mode, s.clip = "move", clip
			end,
		},
		{
			"SOURCE",
			function()
				open_picker(ctx, track.kind, function(name)
					A.set_clip_source(s.cur_track, clip, name)
				end)
			end,
		},
	}
	if track.kind == "take" then
		items[#items + 1] = {
			"AUDITION",
			function()
				if ctx.record then
					ctx.record.play(clip.source, clip.which or "wet", false)
				end
			end,
		}
	end
	items[#items + 1] = {
		"DELETE",
		function()
			A.remove_clip(s.cur_track, clip)
		end,
	}
	return items
end

-- ── input ─────────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local s = st(ctx)
	local A = ctx.arrangement
	local song = A.song
	local nt = #song.tracks

	-- menus / picker first
	if s.mode == "menu" or s.mode == "clipmenu" then
		local items = (s.mode == "menu") and menu_items(ctx) or s.clipitems
		s.msel = math.max(1, math.min(#items, s.msel))
		if action == "next" then
			s.msel = (s.msel % #items) + 1
		elseif action == "prev" then
			s.msel = ((s.msel - 2) % #items) + 1
		elseif action == "activate" then
			items[s.msel][2]()
			if s.mode == "clipmenu" then
				s.mode = "grid"
			end -- one-shot clip actions return to grid
		elseif action == "back" or action == "wet" then
			s.mode = "grid"
		else
			return false
		end
		return true
	elseif s.mode == "picker" then
		local pk = s.picker
		if not pk or #pk.list == 0 then
			s.mode = "grid"
			if ctx.toast then
				ctx.toast("nothing to pick", "warn")
			end
			return true
		end
		if action == "next" then
			pk.sel = (pk.sel % #pk.list) + 1
		elseif action == "prev" then
			pk.sel = ((pk.sel - 2) % #pk.list) + 1
		elseif action == "activate" then
			pk.onpick(pk.list[pk.sel])
			s.mode = "grid"
		elseif action == "back" or action == "wet" then
			s.mode = "grid"
		else
			return false
		end
		return true
	elseif s.mode == "move" then
		local clip = s.clip
		if action == "next" then
			clip.start_bar = math.min(song.len_bars, clip.start_bar + 1)
			s.cur_bar = clip.start_bar
		elseif action == "prev" then
			clip.start_bar = math.max(1, clip.start_bar - 1)
			s.cur_bar = clip.start_bar
		elseif action == "activate" or action == "back" then
			s.mode = "grid"
		else
			return false
		end
		return true
	end

	-- transport: Start button / footswitch / menu (NOT tab, so tab always switches screens)
	if action == "play_stop" then
		if A.is_playing() then
			A.stop()
		else
			A.play()
		end
		return true
	end

	-- grid mode — drill-in focus (s.axis is the level): "tracks" = pick a lane; "bars" =
	-- drilled into that lane to pick a bar + place/edit a clip. Enter descends, back ascends
	-- — keyboard-complete. wet is an optional level-flip accelerator.
	if s.axis == "bars" then
		if action == "next" or action == "prev" then
			local d = (action == "next") and 1 or -1
			s.cur_bar = math.max(1, math.min(song.len_bars, s.cur_bar + d))
			return true
		elseif action == "activate" then
			local track = song.tracks[s.cur_track]
			if not track then
				s.mode, s.msel = "menu", 1 -- no tracks yet → command menu (add one)
				return true
			end
			local clip = clip_at(track, s.cur_bar)
			if clip then
				s.mode, s.msel, s.clip = "clipmenu", 1, clip
				s.clipitems = clip_menu_items(ctx, track, clip)
			else
				open_picker(ctx, track.kind, function(name)
					local remaining = song.len_bars - s.cur_bar + 1
					A.place_clip(s.cur_track, name, s.cur_bar, math.min(4, math.max(1, remaining)))
				end)
			end
			return true
		elseif action == "back" or action == "wet" then
			s.axis = "tracks" -- ascend back to lane select
			return true
		end
		return false -- tab/tab_prev/play_stop fall through to the global handler
	end

	-- track level (default): pick a lane; Enter (or wet) drills into its bars
	if action == "next" or action == "prev" then
		local d = (action == "next") and 1 or -1
		s.cur_track = math.max(1, math.min(math.max(1, nt), s.cur_track + d))
		return true
	elseif action == "activate" or action == "wet" then
		if nt == 0 then
			s.mode, s.msel = "menu", 1 -- no tracks yet → command menu (add one)
		else
			s.axis = "bars" -- descend into the lane's bars
		end
		return true
	elseif action == "back" then
		s.mode, s.msel = "menu", 1
		return true
	end
	return false
end

-- ── draw helpers ──────────────────────────────────────────────────────────────
local function draw_overlay(ctx, W, H, title, items, sel)
	local U, C = ctx.U, ctx.C
	local rh = 18
	local maxrows = math.min(#items, math.floor((H - 120) / rh))
	maxrows = math.max(4, maxrows)
	local first = math.max(1, math.min(sel - math.floor(maxrows / 2), math.max(1, #items - maxrows + 1)))
	local mw = 196
	local mh = math.min(#items, maxrows) * rh + 26
	local mx, my = W - mw - 18, 90
	U.gradient_v(mx, my, mw, mh, C.panel_hi, C.panel)
	U.rect(mx, my, mw, mh, C.panel)
	U.tline(mx, my, mx + mw, my, 2, C.turq, 255)
	U.tline(mx, my + mh, mx + mw, my + mh, 2, C.turq, 255)
	U.text(mx + 10, my + 6, title, C.turq, 230)
	for row = 0, math.min(#items, maxrows) - 1 do
		local i = first + row
		local it = items[i]
		if it then
			local iy = my + 24 + row * rh
			local issel = (i == sel)
			if issel then
				U.rect(mx + 4, iy - 2, mw - 8, rh - 2, C.turq, 40)
				U.tline(mx + 4, iy - 2, mx + 4, iy + rh - 4, 3, C.turq, 255)
			end
			U.text(mx + 14, iy + 2, U.ellipsize(it[1] or it, mw - 26), issel and C.white or C.dim, issel and 255 or 180)
		end
	end
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local A = ctx.arrangement
	local song = A.song
	local narrow = W < 380

	-- header
	U.text(20, U.HEADER_Y, "ARRANGE", C.turq, 220)
	U.text_r(
		W - 20,
		U.HEADER_Y,
		string.format(
			"%d BPM  %d bars  bar %d%s",
			math.floor(song.bpm),
			song.len_bars,
			A.song_bar(),
			A.is_playing() and "  >PLAY" or ""
		),
		A.is_playing() and C.green or C.dim,
		A.is_playing() and 220 or 160
	)
	U.line(20, 74, W - 20, 74, C.border, 140)

	local nt = #song.tracks
	if nt == 0 then
		U.text_c(W / 2, H / 2 - 8, "no tracks yet", C.dim, 180)
		U.text_c(W / 2, H / 2 + 10, "back: menu  ->  + PATTERN / AUTOMATION / TAKE TRK", C.dim, 150)
	end

	-- geometry
	local gutter = narrow and 64 or 116
	local gx0 = 20 + gutter
	local top = U.CONTENT_TOP
	local bot = H - 50
	local gridW = (W - 20) - gx0
	local rowH = math.max(18, math.min(34, nt > 0 and (bot - top) / math.max(nt, 1) or 28))
	local vis_tracks = math.max(1, math.floor((bot - top) / rowH))

	-- bar window (scroll)
	local colW = math.max(narrow and 14 or 22, math.floor(gridW / song.len_bars))
	local vbars = math.max(1, math.min(song.len_bars, math.floor(gridW / colW)))
	if s.cur_bar - 1 < s.bar_scroll then
		s.bar_scroll = s.cur_bar - 1
	elseif s.cur_bar - 1 > s.bar_scroll + vbars - 1 then
		s.bar_scroll = s.cur_bar - vbars
	end
	s.bar_scroll = math.max(0, math.min(s.bar_scroll, math.max(0, song.len_bars - vbars)))
	-- track window (scroll)
	if s.cur_track - 1 < s.trk_scroll then
		s.trk_scroll = s.cur_track - 1
	elseif s.cur_track - 1 > s.trk_scroll + vis_tracks - 1 then
		s.trk_scroll = s.cur_track - vis_tracks
	end
	s.trk_scroll = math.max(0, math.min(s.trk_scroll, math.max(0, nt - vis_tracks)))

	-- loop region shading (under everything)
	if song.loop.on then
		local a = math.max(0, song.loop.start_bar - 1 - s.bar_scroll)
		local b = math.min(vbars, song.loop.end_bar - s.bar_scroll)
		if b > a then
			U.rect(gx0 + a * colW, top, (b - a) * colW, (math.min(nt, vis_tracks)) * rowH, C.yellow, 14)
		end
	end

	-- lanes
	for r = 0, math.min(nt, vis_tracks) - 1 do
		local ti = s.trk_scroll + r + 1
		local track = song.tracks[ti]
		if track then
			local y = top + r * rowH
			local tsel = (ti == s.cur_track)
			local accent = (track.kind == "pattern") and C.violet or (track.kind == "automation") and C.turq or C.orange
			-- gutter label
			U.gradient_v(20, y, gutter - 2, rowH - 2, C.panel_hi, C.panel)
			if tsel then
				U.tline(20, y, 20, y + rowH - 2, 3, accent, 230)
			end
			local lbl = U.ellipsize(track.name or track.kind, gutter - 30)
			U.text(24, y + 3, lbl, track.mute and C.dim or (tsel and C.white or C.dim), tsel and 255 or 170)
			local meta = KIND_GLYPH[track.kind]
				.. (track.target and (">" .. track.target) or "")
				.. (track.mute and " M" or "")
			U.text(24, y + rowH - 13, meta, track.mute and C.red or accent, 180)
			-- lane background + bar grid
			U.rect(gx0, y, gridW, rowH - 2, C.panel, 60)
			for c = 0, vbars - 1 do
				local bar = s.bar_scroll + c + 1
				if (bar - 1) % 4 == 0 then
					U.line(gx0 + c * colW, y, gx0 + c * colW, y + rowH - 2, C.border, 90)
				end
			end
			-- clips
			for _, clip in ipairs(track.clips or {}) do
				local cs = clip.start_bar - 1 - s.bar_scroll
				local ce = cs + clip.len_bars
				local x0 = gx0 + math.max(0, cs) * colW
				local x1 = gx0 + math.min(vbars, ce) * colW
				if x1 > gx0 and x0 < gx0 + gridW and ce > 0 and cs < vbars then
					local hot = tsel and (s.cur_bar >= clip.start_bar and s.cur_bar < clip.start_bar + clip.len_bars)
					U.rect(x0 + 1, y + 2, math.max(2, x1 - x0 - 2), rowH - 6, accent, hot and 220 or 150)
					U.text(x0 + 4, y + 3, U.ellipsize((clip.source or ""):gsub("%.mid$", ""), x1 - x0 - 6), C.bg, 220)
				end
			end
			-- cursor cell (only when drilled into the lane's bars; at track level the lane
			-- rail alone shows focus, so the level is visually obvious)
			if tsel and s.axis == "bars" then
				local cc = s.cur_bar - 1 - s.bar_scroll
				if cc >= 0 and cc < vbars then
					local cx = gx0 + cc * colW
					U.tline(cx + 1, y, cx + colW - 1, y, 1, C.turq, 230)
					U.tline(cx + 1, y + rowH - 3, cx + colW - 1, y + rowH - 3, 1, C.turq, 230)
					U.tline(cx + 1, y, cx + 1, y + rowH - 3, 2, C.turq, 230)
				end
			end
		end
	end

	-- playhead (across all lanes)
	if A.is_playing() then
		local phb = A.song_bar() - 1 - s.bar_scroll
		if phb >= 0 and phb < vbars then
			local px = gx0 + phb * colW
			U.tline(px, top - 2, px, top + math.min(nt, vis_tracks) * rowH, 2, C.green, 220)
		end
	end

	-- bar ruler
	local ry = top + math.min(nt, vis_tracks) * rowH + 2
	if ry < bot then
		for c = 0, vbars - 1 do
			local bar = s.bar_scroll + c + 1
			if (bar - 1) % 4 == 0 then
				U.text(gx0 + c * colW + 2, ry, tostring(bar), C.dim, 130)
			end
		end
	end

	-- overlays
	if s.mode == "menu" then
		draw_overlay(ctx, W, H, "SONG MENU", menu_items(ctx), s.msel)
	elseif s.mode == "clipmenu" then
		draw_overlay(ctx, W, H, "CLIP", s.clipitems or {}, s.msel)
	elseif s.mode == "picker" and s.picker then
		local rows = {}
		for _, n in ipairs(s.picker.list) do
			rows[#rows + 1] = { n }
		end
		draw_overlay(ctx, W, H, (s.picker.kind or "?"):upper() .. " ?", rows, s.picker.sel)
	end

	-- footer
	local hint
	if s.mode == "menu" or s.mode == "clipmenu" then
		hint = "turn: choose   sel: do   back: close"
	elseif s.mode == "picker" then
		hint = "turn: pick   sel: choose   back: cancel"
	elseif s.mode == "move" then
		hint = "turn: move clip   sel/back: drop"
	elseif s.axis == "bars" then
		hint = "turn: BAR   sel: clip   back: tracks   start: play   tab: screen"
	else
		hint = "turn: TRACK   sel: open lane   back: menu   start: play   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
