-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/scripts.lua — parameter automation scripts (motion record/playback).

  Record a take by arming RECORD here, switching to PARAMS, and moving knobs — every
  set_param is captured (ctx.automation, wired in dsp_studio). SELECT plays/stops the
  selected script; an inline action menu covers RECORD / LOOP / ASSIGN trigger / DELETE.
  Triggers (MIDI note/CC, footswitch, gamepad "Script N", or on-screen) all fire the
  same script. Scripts persist to DEMOD_SCRIPT_DIR and are hand-editable.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "SCRIPTS", short = "SCR" }

local function st(ctx)
	ctx.S.scripts = ctx.S.scripts or { sel = 1, menu = nil }
	return ctx.S.scripts
end

local function trig_label(s)
	if not s.trigger then
		return "no trigger"
	end
	return s.trigger.kind .. " " .. tostring(s.trigger.code)
end

local MENU = { "PLAY", "RECORD", "LOOP", "ASSIGN", "DELETE" }

local function auto(ctx)
	return ctx.automation
end

-- ── nav ──────────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local A = auto(ctx)
	if not A then
		return false
	end
	local s = st(ctx)
	local list = A.list()
	local nitems = #list + 1 -- +1 = the "NEW SCRIPT" row

	if s.menu then -- inline per-script action menu
		local sc = list[s.sel]
		if action == "next" then
			s.menu.sel = (s.menu.sel % #MENU) + 1
			return true
		elseif action == "prev" then
			s.menu.sel = ((s.menu.sel - 2) % #MENU) + 1
			return true
		elseif action == "back" then
			s.menu = nil
			return true
		elseif action == "activate" and sc then
			local item = MENU[s.menu.sel]
			if item == "PLAY" then
				A.fire(sc, ctx.S.t or 0)
			elseif item == "RECORD" then
				if A.recording then
					A.rec_stop()
					if ctx.toast then
						ctx.toast("Recorded " .. sc.name, "ok")
					end
				else
					A.rec_start(sc.name, ctx.S.t or 0)
					if ctx.toast then
						ctx.toast("Recording " .. sc.name .. " - move params on PARAMS", "info")
					end
				end
			elseif item == "LOOP" then
				sc.loop = not sc.loop
				A.save(sc)
			elseif item == "ASSIGN" then
				A.begin_assign(sc)
				if ctx.toast then
					ctx.toast("Assign: press a pad / CC / footswitch", "info")
				end
			elseif item == "DELETE" then
				A.delete(sc.name)
				s.menu = nil
				s.sel = math.max(1, math.min(s.sel, #A.list() + 1))
			end
			return true
		end
		return false
	end

	-- list mode
	if action == "next" then
		s.sel = math.min((s.sel or 1) + 1, nitems)
		return true
	elseif action == "prev" then
		s.sel = math.max((s.sel or 1) - 1, 1)
		return true
	elseif action == "activate" then
		if s.sel > #list then -- NEW SCRIPT → create + arm recording
			local name = "SCRIPT " .. (#list + 1)
			A.new(name)
			A.rec_start(name, ctx.S.t or 0)
			s.sel = #A.list()
			if ctx.toast then
				ctx.toast("Recording " .. name .. " - move params on PARAMS", "info")
			end
		else
			s.menu = { sel = 1 } -- open the action menu for this script
		end
		return true
	elseif action == "wet" then -- secondary: quick play/stop the selected script
		local sc = list[s.sel]
		if sc then
			A.fire(sc, ctx.S.t or 0)
		end
		return true
	end
	return false
end

-- ── draw ─────────────────────────────────────────────────────────────────────
function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local A = auto(ctx)
	local s = st(ctx)

	U.text(20, U.HEADER_Y, "SCRIPTS", C.turq, 220)
	U.text_r(
		W - 20,
		U.HEADER_Y,
		A and A.recording and "REC ARMED" or "param automation",
		A and A.recording and C.red or C.dim,
		A and A.recording and 240 or 150
	)
	U.line(20, 74, W - 20, 74, C.border, 140)

	if not A then
		U.text_c(W / 2, H / 2, "automation unavailable", C.dim, 170)
		U.footer(W, H, "unavailable")
		return
	end

	local list = A.list()
	local y0 = U.CONTENT_TOP + 6
	local rowH = 24
	for i, sc in ipairs(list) do
		local y = y0 + (i - 1) * rowH
		if y > H - 60 then
			break
		end
		local sel = (i == s.sel) and not s.menu
		local selrow = (i == s.sel)
		if selrow then
			U.rect(20, y, W - 40, rowH - 4, C.turq, s.menu and 18 or 32)
			U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
		end
		local playing = A.is_playing(sc)
		if playing then
			local pulse = 0.5 + 0.5 * math.sin((ctx.S.t or 0) * 5)
			U.circle(32, y + (rowH - 4) / 2, 4, C.green, math.floor(120 + 135 * pulse))
		end
		U.text(44, y + (rowH - 4) / 2 - 8, sc.name, sel and C.white or C.dim, selrow and 240 or 170)
		local meta =
			string.format("%db  %.1fs  %s%s", #sc.events, sc.length or 0, sc.loop and "loop  " or "", trig_label(sc))
		U.text_r(W - 28, y + (rowH - 4) / 2 - 8, meta, C.dim, 150)
	end

	-- the "+ NEW SCRIPT" row
	local ny = y0 + #list * rowH
	if ny <= H - 60 then
		local sel = (s.sel == #list + 1) and not s.menu
		if sel then
			U.rect(20, ny, W - 40, rowH - 4, C.violet, 32)
			U.tline(20, ny, 20, ny + rowH - 4, 3, C.violet, 255)
		end
		U.text(44, ny + (rowH - 4) / 2 - 8, "+ NEW SCRIPT (record)", sel and C.white or C.dim, sel and 230 or 150)
	end

	if #list == 0 then
		U.text_c(W / 2, H / 2 + 10, "no scripts yet - select NEW to record one", C.dim, 140)
	end

	-- inline action menu for the selected script
	if s.menu and list[s.sel] then
		local sc = list[s.sel]
		local mx, my = W - 200, U.CONTENT_TOP + 6
		local mh = #MENU * 22 + 16
		U.rect(mx, my, 180, mh, C.panel, 235)
		U.tline(mx, my, mx + 180, my, 2, C.turq, 255)
		U.text(mx + 10, my + 6, sc.name, C.turq, 220)
		for i, item in ipairs(MENU) do
			local ry = my + 22 + (i - 1) * 22
			local sel = (i == s.menu.sel)
			if sel then
				U.rect(mx + 4, ry - 2, 172, 18, C.turq, 36)
			end
			local label = item
			if item == "PLAY" then
				label = A.is_playing(sc) and "STOP" or "PLAY"
			elseif item == "RECORD" then
				label = A.recording and "STOP REC" or "RECORD"
			elseif item == "LOOP" then
				label = "LOOP: " .. (sc.loop and "ON" or "OFF")
			elseif item == "ASSIGN" then
				label = "ASSIGN (" .. trig_label(sc) .. ")"
			end
			U.text(mx + 12, ry, label, sel and C.white or C.dim, sel and 235 or 160)
		end
	end

	local hint
	if s.menu then
		hint = "turn: action   sel: do   back: close"
	elseif A.is_assigning() then
		hint = "press a pad / CC / footswitch to assign..."
	else
		hint = "turn: select   sel: menu/new   wet/X: play   ([tab] PARAMS to record knobs)"
	end
	U.footer(W, H, hint)
end

return M
