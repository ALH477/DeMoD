-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/params.lua — per-slot parameter editor (edits the FX-chain selection).
  Modal: turn to select a param; SELECT to enter adjust mode; turn to change; BACK exits.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "PARAMS", short = "PRM" }

local function st(ctx)
	ctx.S.par = ctx.S.par or { sel = 1, adjust = false, accel = {} }
	return ctx.S.par
end

local function cur_slot(ctx)
	return (ctx.S.fx and ctx.S.fx.sel) or 1
end

function M.nav(ctx, action)
	local U = ctx.U
	local s = st(ctx)
	local slot = cur_slot(ctx)
	local params = ctx.dsp.params(slot)
	if #params == 0 then
		return false
	end
	if s.last_slot ~= slot then -- land on param 1 when the edited slot changes
		s.sel, s.adjust, s.last_slot, s.accel = 1, false, slot, {}
	end
	s.sel = U.clamp(s.sel, 1, #params)
	local p = params[s.sel]
	local step = p.step or 0.01
	local pv = p.value or p.init or 0

	-- in adjust mode, holding inc/dec accelerates the step exponentially (U.accel);
	-- floor to whole steps so integer-stepped params stay on their grid. set_param clamps.
	if action == "next" then
		if s.adjust then
			local n = math.max(1, math.floor(U.accel(s.accel, 1, ctx.S.t or 0)))
			ctx.dsp.set_param(slot, p.index, pv + step * n)
		else
			s.sel, s.accel = (s.sel % #params) + 1, {}
		end
		return true
	elseif action == "prev" then
		if s.adjust then
			local n = math.max(1, math.floor(U.accel(s.accel, -1, ctx.S.t or 0)))
			ctx.dsp.set_param(slot, p.index, pv - step * n)
		else
			s.sel, s.accel = ((s.sel - 2) % #params) + 1, {}
		end
		return true
	elseif action == "activate" then
		s.adjust, s.accel = not s.adjust, {}
		return true
	elseif action == "back" then
		if s.adjust then
			s.adjust = false
			return true
		end
	elseif action == "randomize" then
		for _, pp in ipairs(params) do
			ctx.dsp.set_param(slot, pp.index, pp.min + math.random() * (pp.max - pp.min))
		end
		return true
	elseif action == "reset" then
		for _, pp in ipairs(params) do
			ctx.dsp.set_param(slot, pp.index, pp.init)
		end
		return true
	elseif action == "wet" then
		-- assign the focused param to the next interface control: register the target,
		-- then arm; the next MIDI CC (continuous) or footswitch (toggle) that arrives binds.
		if ctx.bindings then
			local sl = ctx.dsp.slot(slot)
			local id = "slot" .. slot .. ".p" .. p.index
			ctx.bindings.register_target(
				id,
				((sl and sl.name) or "slot") .. " " .. (p.label or "?"),
				slot,
				p.index,
				p.min or 0,
				p.max or 1,
				p.step or 0.01
			)
			ctx.bindings.begin_assign(id)
			s.learning = id
			if ctx.toast then
				ctx.toast("Assign: twist a CC or tap a footswitch", "info")
			end
		end
		return true
	end
	return false
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local slot = cur_slot(ctx)
	local sl = ctx.dsp.slot(slot)
	local params = ctx.dsp.params(slot)
	if s.last_slot ~= slot then -- keep selection in sync if the slot changed
		s.sel, s.adjust, s.last_slot, s.accel = 1, false, slot, {}
	end
	local accent = U.SLOT_COLORS[((slot - 1) % #U.SLOT_COLORS) + 1]

	-- header: which slot we're editing (slot-accent rail) + selected param range
	U.tline(20, U.HEADER_Y, 20, 74, 3, accent, 220)
	U.text(30, U.HEADER_Y, string.format("SLOT %02d", slot), C.dim, 180)
	U.text(30 + 72, U.HEADER_Y, (sl and sl.loaded) and (sl.name or "USER") or "- empty -", accent, 240)
	U.line(20, 74, W - 20, 74, C.border, 160)

	local compact = W < 380
	if #params == 0 then
		U.text_c(W / 2, H / 2 - 8, "no parameters here", C.dim, 170)
		U.text_c(W / 2, H / 2 + 12, "load an effect on FX CHAIN, then return", C.dim, 140)
		U.footer(W, H, "this slot is empty   [ < > ] FX CHAIN to load")
		return
	end
	s.sel = U.clamp(s.sel, 1, #params)

	-- a control just bound to the param we armed → toast + persist to the settings file
	if s.learning and ctx.bindings and not ctx.bindings.is_assigning() then
		local tag = ctx.bindings.tag(s.learning)
		if ctx.toast then
			ctx.toast(tag and (tag .. " bound") or "assign done", "ok")
		end
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		s.learning = nil
	end

	-- range of the selected param, shown in the header's right side
	do
		local p = params[s.sel]
		if p then
			U.text_r(
				W - 20,
				U.HEADER_Y,
				string.format("range %g .. %g %s", p.min or 0, p.max or 1, p.unit or ""),
				C.dim,
				150
			)
		end
	end

	local y0 = U.CONTENT_TOP + 6
	local rowH = math.max(compact and 22 or 26, math.min(compact and 32 or 40, (H - y0 - 52) / #params))
	for i, p in ipairs(params) do
		local y = y0 + (i - 1) * rowH
		local sel = (i == s.sel)
		local pval = p.value or p.init or 0
		local pmin = p.min or 0
		local pmax = p.max or 1
		local frac = (pval - pmin) / math.max(1e-6, (pmax - pmin))

		if sel then
			U.gradient_v(20, y, W - 40, rowH - 6, C.panel_hi, C.panel)
			U.rect(20, y, W - 40, rowH - 6, accent, s.adjust and 42 or 20) -- brighter while editing
			U.tline(20, y, 20, y + rowH - 6, 3, accent, 255)
		end
		-- label
		U.text(36, y + (rowH - 6) / 2 - 8, p.label or "?", sel and C.white or C.dim, sel and 255 or 180)
		-- value readout
		local vtxt = U.fmt(pval, p.unit or "")
		U.text_r(W - 44, y + (rowH - 6) / 2 - 8, vtxt, sel and (s.adjust and accent or C.white) or C.dim, 220)
		-- bar — responsive so it never collapses on a narrow guitar panel
		local bx = math.min(150, math.floor(W * 0.42))
		-- binding affordance: LEARN pulse on the armed param, else its bound-control tag
		if ctx.bindings then
			local bid = "slot" .. slot .. ".p" .. p.index
			if sel and s.learning == bid then
				local pulse = 0.5 + 0.5 * math.sin((ctx.S.t or 0) * 6)
				U.text_r(bx - 8, y + (rowH - 6) / 2 - 8, "LEARN", accent, math.floor(120 + 135 * pulse))
			else
				local ty = y + (rowH - 6) / 2 - 8
				local tag = ctx.bindings.tag(bid)
				local tx = bx - 8
				if tag then
					U.text_r(tx, ty, tag, C.dim, 150)
					tx = tx - (#tag * 8 + 10)
				end
				-- modulation indicator (LFO / macro driving this param)
				local mtag = ctx.modulation and ctx.modulation.target_info(bid)
				if mtag then
					U.text_r(tx, ty, mtag, C.violet, 185)
				end
			end
		end
		local bw = math.max(24, W - bx - math.min(150, math.floor(W * 0.34)))
		U.rect(bx, y + (rowH - 6) / 2 - 3, bw, 6, C.border, 160)
		U.rect(bx, y + (rowH - 6) / 2 - 3, bw * frac, 6, accent, sel and 255 or 150)
		if sel then
			U.circle(bx + bw * frac, y + (rowH - 6) / 2, s.adjust and 4 or 3, accent, 255)
		end
	end

	local hint = s.adjust and "turn: adjust value   sel/back: done"
		or "turn: select   sel: adjust   wet/X: assign control"
	U.footer(W, H, hint)
end

return M
