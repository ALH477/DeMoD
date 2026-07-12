-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/bindings.lua — the param <-> interface-control binding manager.

  Lists every parameter across the loaded slots (effects AND synths share one param
  model) with its assigned control, and an inline menu to ASSIGN a control, set the
  PERF (performance) param, cycle its MODE, CLEAR it, or GRAB the encoder. The quick
  "assign" also lives on the PARAMS screen (wet/X); this is the review/edit/clear view.
  All state lives in ctx.bindings (dsp/bindings.lua), persisted via ctx.save_bindings.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "BINDINGS", short = "BND" }

local MENU = { "ASSIGN", "PERF", "MODE", "SHAPE", "OUT", "OUT MODE", "CLEAR", "GRAB ENC" }

-- SHAPE sub-panel: the per-binding value-shaping editor (curve/invert/pickup/deadzone/
-- quantize/range/encoder). Works on a copy in ctx.S.bind.shape; committed on back.
local CURVE_OPTS = { "lin", "exp", "log", "s" }
local QSTEPS = { 0, 2, 3, 4, 5, 6, 8, 12, 16 }
local ENC_OPTS = { false, "rel_signed", "rel_twos" }
local SHAPE_ROWS = { "Curve", "Invert", "Pickup", "Deadzone", "Quantize", "Range Lo", "Range Hi", "Encoder" }

local function cycle(list, cur, dir)
	local idx = 1
	for i, v in ipairs(list) do
		if v == cur then
			idx = i
			break
		end
	end
	return list[((idx - 1 + dir) % #list) + 1]
end

local function shape_adjust(sp, dir)
	local sh = sp.sh
	local r = SHAPE_ROWS[sp.sel]
	if r == "Curve" then
		sh.curve = cycle(CURVE_OPTS, sh.curve or "lin", dir)
	elseif r == "Invert" then
		sh.invert = not sh.invert
	elseif r == "Pickup" then
		sh.pickup = not sh.pickup
	elseif r == "Deadzone" then
		sh.deadzone = math.max(0, math.min(0.9, (sh.deadzone or 0) + dir * 0.05))
	elseif r == "Quantize" then
		sh.quantize = cycle(QSTEPS, sh.quantize or 0, dir)
	elseif r == "Range Lo" then
		sh.lo = math.max(0, math.min(1, (sh.lo or 0) + dir * 0.05))
	elseif r == "Range Hi" then
		sh.hi = math.max(0, math.min(1, (sh.hi or 1) + dir * 0.05))
	elseif r == "Encoder" then
		sp.enc = cycle(ENC_OPTS, sp.enc, dir)
	end
end

local function shape_display(sp, i)
	local sh = sp.sh
	local r = SHAPE_ROWS[i or sp.sel]
	if r == "Curve" then
		return sh.curve or "lin"
	elseif r == "Invert" then
		return sh.invert and "ON" or "OFF"
	elseif r == "Pickup" then
		return sh.pickup and "ON" or "OFF"
	elseif r == "Deadzone" then
		return string.format("%d%%", math.floor((sh.deadzone or 0) * 100 + 0.5))
	elseif r == "Quantize" then
		return (sh.quantize or 0) > 1 and tostring(sh.quantize) or "Off"
	elseif r == "Range Lo" then
		return string.format("%d%%", math.floor((sh.lo or 0) * 100 + 0.5))
	elseif r == "Range Hi" then
		return string.format("%d%%", math.floor((sh.hi or 1) * 100 + 0.5))
	elseif r == "Encoder" then
		return sp.enc == "rel_signed" and "Rel Signed" or (sp.enc == "rel_twos" and "Rel Two's" or "None")
	end
	return ""
end

-- collapse an all-default shape to nil so it isn't persisted
local function shape_or_nil(sh)
	if
		(sh.curve == nil or sh.curve == "lin")
		and not sh.invert
		and not sh.pickup
		and (sh.deadzone or 0) == 0
		and (sh.quantize or 0) <= 1
		and (sh.lo or 0) == 0
		and (sh.hi or 1) == 1
	then
		return nil
	end
	return sh
end

local function st(ctx)
	ctx.S.bind = ctx.S.bind or { sel = 1, menu = nil }
	return ctx.S.bind
end

-- flat list of every param across loaded slots, in chain order
local function build(ctx)
	local list = {}
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded then
			for _, p in ipairs(ctx.dsp.params(i) or {}) do
				list[#list + 1] = {
					slot = i,
					sname = sl.name or ("SLOT " .. i),
					p = p,
					id = "slot" .. i .. ".p" .. p.index,
				}
			end
		end
	end
	return list
end

local function ensure_target(ctx, it)
	ctx.bindings.register_target(
		it.id,
		it.sname .. " " .. (it.p.label or "?"),
		it.slot,
		it.p.index,
		it.p.min or 0,
		it.p.max or 1,
		it.p.step or 0.01
	)
end

-- ── nav ──────────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local B = ctx.bindings
	if not B then
		return false
	end
	local s = st(ctx)

	-- shaping editor sub-panel (takes priority over the list/menu). Mirrors the settings
	-- overlay: turn to move rows; activate toggles adjust; in adjust, turn changes the value.
	if s.shape then
		local sp = s.shape
		if action == "next" then
			if sp.adjust then
				shape_adjust(sp, 1)
			else
				sp.sel = (sp.sel % #SHAPE_ROWS) + 1
			end
		elseif action == "prev" then
			if sp.adjust then
				shape_adjust(sp, -1)
			else
				sp.sel = ((sp.sel - 2) % #SHAPE_ROWS) + 1
			end
		elseif action == "activate" then
			sp.adjust = not sp.adjust
		elseif action == "back" then
			if sp.adjust then
				sp.adjust = false
			else
				B.set_shape(sp.id, shape_or_nil(sp.sh))
				B.set_enc(sp.id, sp.enc)
				if ctx.save_bindings then
					ctx.save_bindings()
				end
				s.shape = nil
				if ctx.toast then
					ctx.toast("Shape saved", "ok")
				end
			end
		end
		return true
	end

	local list = build(ctx)
	local n = #list + 1 -- +1 = the "clear all" action row
	s.sel = math.max(1, math.min(s.sel or 1, n))
	local it = list[s.sel]

	if s.menu and it then -- inline per-param action menu
		if action == "next" then
			s.menu.sel = (s.menu.sel % #MENU) + 1
			return true
		elseif action == "prev" then
			s.menu.sel = ((s.menu.sel - 2) % #MENU) + 1
			return true
		elseif action == "back" then
			s.menu = nil
			return true
		elseif action == "activate" then
			local item = MENU[s.menu.sel]
			ensure_target(ctx, it)
			if item == "ASSIGN" then
				B.begin_assign(it.id)
				s.learning = it.id
				s.menu = nil
				if ctx.toast then
					ctx.toast("Assign: twist a CC or tap a footswitch", "info")
				end
			elseif item == "PERF" then
				B.set_perf(B.perf() == it.id and nil or it.id)
				if ctx.save_bindings then
					ctx.save_bindings()
				end
				if ctx.toast then
					ctx.toast(
						B.perf() == it.id and ("Performance param: " .. (it.p.label or "?"))
							or "Performance param cleared",
						"ok"
					)
				end
			elseif item == "MODE" then
				B.cycle_mode(it.id)
				if ctx.save_bindings then
					ctx.save_bindings()
				end
			elseif item == "SHAPE" then
				-- open the shaping editor on a working copy of this binding's shape
				local cur = B.shape_of(it.id) or {}
				s.shape = {
					id = it.id,
					sel = 1,
					enc = B.enc_of(it.id),
					sh = {
						curve = cur.curve,
						invert = cur.invert,
						pickup = cur.pickup,
						deadzone = cur.deadzone,
						quantize = cur.quantize,
						lo = cur.lo,
						hi = cur.hi,
					},
				}
				s.menu = nil
			elseif item == "OUT" then
				-- learn the MIDI-out destination from the next inbound CC, or clear if set
				if B.out(it.id) then
					B.clear_out(it.id)
					if ctx.save_bindings then
						ctx.save_bindings()
					end
					if ctx.toast then
						ctx.toast("MIDI-out cleared", "ok")
					end
				else
					B.begin_assign_out(it.id)
					s.learning_out = it.id
					s.menu = nil
					if ctx.toast then
						ctx.toast("MIDI-out: twist the CC to mirror", "info")
					end
				end
			elseif item == "OUT MODE" then
				B.cycle_override(it.id)
				if ctx.save_bindings then
					ctx.save_bindings()
				end
			elseif item == "CLEAR" then
				B.clear(it.id)
				if B.perf() == it.id then
					B.set_perf(nil)
				end
				if ctx.save_bindings then
					ctx.save_bindings()
				end
				s.menu = nil
				if ctx.toast then
					ctx.toast("Binding cleared", "ok")
				end
			elseif item == "GRAB ENC" then
				if B.perf() ~= it.id then
					B.set_perf(it.id)
				end
				ctx.S._perf_edit = not ctx.S._perf_edit
				s.menu = nil
				if ctx.save_bindings then
					ctx.save_bindings()
				end
				if ctx.toast then
					ctx.toast(
						ctx.S._perf_edit and "Encoder grab ON - turn to adjust, back to release" or "Encoder grab OFF",
						"info"
					)
				end
			end
			return true
		end
		return false
	end

	-- list mode
	if action == "next" then
		s.sel = math.min(s.sel + 1, n)
		return true
	elseif action == "prev" then
		s.sel = math.max(s.sel - 1, 1)
		return true
	elseif action == "activate" then
		if not it then -- the "clear all" row
			B.clear_all()
			B.set_perf(nil)
			ctx.S._perf_edit = false
			if ctx.save_bindings then
				ctx.save_bindings()
			end
			if ctx.toast then
				ctx.toast("All bindings cleared", "ok")
			end
		else
			s.menu = { sel = 1 }
		end
		return true
	elseif action == "wet" and it then -- secondary: quick toggle PERF on the selected param
		ensure_target(ctx, it)
		B.set_perf(B.perf() == it.id and nil or it.id)
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		return true
	elseif action == "back" then
		if B.is_assigning() then
			B.cancel_assign()
			s.learning = nil
			return true
		end
		return false
	end
	return false
end

-- ── draw ─────────────────────────────────────────────────────────────────────
function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local B = ctx.bindings
	local s = st(ctx)

	U.text(20, U.HEADER_Y, "BINDINGS", C.turq, 220)
	if not B then
		U.text_c(W / 2, H / 2, "bindings unavailable", C.dim, 170)
		U.footer(W, H, "unavailable")
		return
	end

	-- shaping editor sub-panel: rows + values on the left, a live response curve on the right
	if s.shape then
		local sp = s.shape
		local pw, ph = math.min(440, W - 60), math.min(#SHAPE_ROWS * 22 + 56, H - 110)
		local px, py = (W - pw) / 2, U.CONTENT_TOP
		U.rect(px, py, pw, ph, C.panel, 240)
		U.tline(px, py, px + pw, py, 2, C.turq, 255)
		U.text(px + 12, py + 8, U.ellipsize("SHAPE   " .. (sp.id or ""), pw - 24), C.turq, 230)
		local ry = py + 34
		for i, label in ipairs(SHAPE_ROWS) do
			local sel = (i == sp.sel)
			local yy = ry + (i - 1) * 22
			if sel then
				U.rect(px + 6, yy - 2, pw - 130, 18, sp.adjust and C.violet or C.turq, sp.adjust and 50 or 32)
			end
			U.text(px + 14, yy, label, sel and C.white or C.dim, sel and 235 or 165)
			U.text_r(px + pw - 124, yy, shape_display(sp, i), sel and C.white or C.green, sel and 235 or 180)
		end
		-- live response-curve preview (input 0..1 left→right, output bottom→top)
		local gx, gw = px + pw - 108, 92
		local gy, gh = ry, math.min(#SHAPE_ROWS * 22 - 6, ph - 50)
		U.rect(gx, gy, gw, gh, C.turq, 12)
		U.line(gx, gy + gh, gx + gw, gy + gh, C.border, 140)
		local prevx, prevy
		for k = 0, gw do
			local o = B.shape(k / gw, sp.sh)
			local xx, yy = gx + k, gy + gh - o * gh
			if prevx then
				U.line(prevx, prevy, xx, yy, C.turq, 210)
			end
			prevx, prevy = xx, yy
		end
		U.footer(
			W,
			H,
			sp.adjust and "turn: change value   sel: done   back: cancel" or "turn: row   sel: adjust   back: save"
		)
		return
	end

	-- an assign just resolved (a control bound the armed param) → persist + toast + send-back
	if s.learning and not B.is_assigning() then
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		if B.send_back then
			B.send_back(s.learning) -- push current value to the controller (motor fader / LED)
		end
		if ctx.toast then
			ctx.toast((B.tag(s.learning) or "assigned") .. " bound", "ok")
		end
		s.learning = nil
	end
	-- a MIDI-out learn just resolved (an inbound CC set the dest) → persist + toast
	if s.learning_out and not B.is_assigning_out() then
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		if ctx.toast then
			ctx.toast("MIDI-out " .. (B.out_tag(s.learning_out) or "set"), "ok")
		end
		s.learning_out = nil
	end

	U.text_r(W - 20, U.HEADER_Y, "assign a control to a param", C.dim, 150)
	U.line(20, 74, W - 20, 74, C.border, 140)

	local list = build(ctx)
	local n = #list + 1
	s.sel = math.max(1, math.min(s.sel or 1, n))

	if #list == 0 then
		U.text_c(W / 2, H / 2 - 8, "no parameters loaded", C.dim, 170)
		U.text_c(W / 2, H / 2 + 12, "load an effect on FX CHAIN, then return", C.dim, 140)
		U.footer(W, H, "load an effect first   [ < > ] FX CHAIN")
		return
	end

	local y0 = U.CONTENT_TOP + 6
	local rowH = 24
	local maxRows = math.max(3, math.floor((H - y0 - 52) / rowH))
	local off = 0
	if s.sel > maxRows then
		off = math.min(s.sel - maxRows, math.max(0, n - maxRows))
	end

	for row = 1, maxRows do
		local i = row + off
		if i > n then
			break
		end
		local y = y0 + (row - 1) * rowH
		local sel = (i == s.sel) and not s.menu
		if i > #list then -- the "clear all" action row
			if sel then
				U.rect(20, y, W - 40, rowH - 4, C.red, 30)
				U.tline(20, y, 20, y + rowH - 4, 3, C.red, 255)
			end
			U.text(36, y + (rowH - 4) / 2 - 8, "[ clear all bindings ]", sel and C.red or C.dim, sel and 230 or 150)
		else
			local it = list[i]
			local isperf = B.perf() == it.id
			local accent = isperf and C.violet or C.turq
			if i == s.sel then
				U.rect(20, y, W - 40, rowH - 4, accent, s.menu and 18 or 32)
				U.tline(20, y, 20, y + rowH - 4, 3, accent, 255)
			elseif isperf then
				U.tline(20, y, 20, y + rowH - 4, 3, C.violet, 200)
			end
			local label = U.ellipsize(it.sname .. ": " .. (it.p.label or "?"), math.floor(W * 0.52))
			U.text(36, y + (rowH - 4) / 2 - 8, label, sel and C.white or C.dim, (i == s.sel) and 240 or 175)
			-- bound-control tag (+ mode for discrete) and a PERF marker
			if s.learning == it.id and B.is_assigning() then
				local pulse = 0.5 + 0.5 * math.sin((ctx.S.t or 0) * 6)
				U.text_r(W - 28, y + (rowH - 4) / 2 - 8, "LEARN", accent, math.floor(120 + 135 * pulse))
			else
				local b = B.binding(it.id)
				local parts = {}
				if b and b.source then
					parts[#parts + 1] = (b.source == "cc" and ("CC" .. b.code) or ("FS" .. b.code))
						.. (b.source ~= "cc" and ("  " .. b.mode) or "")
				end
				if isperf then
					parts[#parts + 1] = "PERF"
				end
				local ot = B.out_tag(it.id)
				if ot then
					parts[#parts + 1] = ot
				end
				if B.shape_of(it.id) or B.enc_of(it.id) then
					parts[#parts + 1] = "~" -- shaped / relative-encoder binding
				end
				local tag = #parts > 0 and table.concat(parts, "   ") or "-"
				local lit = (#parts > 0)
				U.text_r(W - 28, y + (rowH - 4) / 2 - 8, tag, lit and C.green or C.dim, lit and 200 or 120)
			end
		end
	end

	-- inline action menu for the selected param
	local it = list[s.sel]
	if s.menu and it then
		local mx, my = W - 210, U.CONTENT_TOP + 6
		local mh = #MENU * 22 + 24
		U.rect(mx, my, 190, mh, C.panel, 235)
		U.tline(mx, my, mx + 190, my, 2, C.turq, 255)
		U.text(mx + 10, my + 6, U.ellipsize(it.p.label or "?", 168), C.turq, 220)
		for i, item in ipairs(MENU) do
			local ry = my + 24 + (i - 1) * 22
			local sel = (i == s.menu.sel)
			if sel then
				U.rect(mx + 4, ry - 2, 182, 18, C.turq, 36)
			end
			local label = item
			if item == "PERF" then
				label = "PERF: " .. (B.perf() == it.id and "ON" or "OFF")
			elseif item == "MODE" then
				local b = B.binding(it.id)
				label = "MODE: " .. ((b and b.source ~= "cc") and b.mode or "-")
			elseif item == "OUT" then
				label = "OUT: " .. (B.out_tag(it.id) or "-")
			elseif item == "OUT MODE" then
				label = "OUT MODE: " .. (B.override(it.id) or "auto")
			elseif item == "GRAB ENC" then
				label = "GRAB ENC: " .. (ctx.S._perf_edit and "ON" or "OFF")
			end
			U.text(mx + 12, ry, label, sel and C.white or C.dim, sel and 235 or 160)
		end
	end

	local hint
	if s.menu then
		hint = "turn: action   sel: do   back: close"
	elseif B.is_assigning() then
		hint = "twist a CC or tap a footswitch to bind...   back: cancel"
	else
		hint = "turn: select   sel: menu   wet/X: perf param"
	end
	U.footer(W, H, hint)
end

return M
