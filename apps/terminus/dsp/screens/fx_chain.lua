-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/fx_chain.lua — the signal chain: slots, bypass, wet, selection.
  Backend-agnostic: only talks to ctx.dsp.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "FX CHAIN", short = "FX" }

-- per-slot action menu (the one place reorder/change/clear/reset/wet are reachable
-- with the limited input vocabulary: select=move, activate=open/run, back=close).
local MENU = { "BYPASS", "WET", "MOVE UP", "MOVE DOWN", "CHANGE FX", "CLEAR", "RESET", "RANDOMIZE" }

-- the per-slot menu, with PLAY prepended for instruments so a loaded synth can be
-- played on the on-screen piano right from the chain.
local function slot_menu(ctx, s)
	local sl = ctx.dsp.slot(s.sel)
	local m = {}
	if sl and sl.loaded and sl.kind == "synth" then
		m[#m + 1] = "PLAY" -- play a loaded synth on the on-screen piano
	end
	if sl and sl.loaded and sl.presets and #sl.presets > 0 then
		m[#m + 1] = "PRESET" -- cycle the patch's factory presets
	end
	if #m == 0 then
		return MENU
	end
	for _, it in ipairs(MENU) do
		m[#m + 1] = it
	end
	return m
end

local function st(ctx)
	ctx.S.fx = ctx.S.fx or { sel = 1, mode = "select", menu_sel = 1 } -- mode: select|menu|wet
	ctx.S.fx.menu_sel = ctx.S.fx.menu_sel or 1
	return ctx.S.fx
end

local function open_or_pick(ctx, s)
	local sl = ctx.dsp.slot(s.sel)
	if sl and sl.loaded then
		s.mode, s.menu_sel = "menu", 1 -- loaded slot → per-slot action menu
	elseif ctx.pick_fx then
		ctx.pick_fx(s.sel) -- empty slot → effect picker
	end
end

local function run_menu_item(ctx, s, n)
	local dsp = ctx.dsp
	local item = slot_menu(ctx, s)[s.menu_sel]
	local sl = dsp.slot(s.sel)
	if item == "PLAY" then
		s.mode = "select"
		if ctx.piano then
			ctx.piano(s.sel) -- open the on-screen keyboard for this synth slot
		end
	elseif item == "PRESET" then
		-- cycle the patch's factory presets: reset to init (deterministic), then apply
		-- the preset's label→value overrides. Labels are unique per descriptor.
		local presets = sl and sl.presets
		if presets and #presets > 0 then
			s.preset_idx = ((s.preset_idx or 0) % #presets) + 1
			local pr = presets[s.preset_idx]
			local by_label = {}
			for _, p in ipairs(dsp.params(s.sel)) do
				by_label[p.label] = p
				if p.init ~= nil then
					dsp.set_param(s.sel, p.index, p.init)
				end
			end
			for label, val in pairs(pr.values or {}) do
				local p = by_label[label]
				if p then
					dsp.set_param(s.sel, p.index, val)
				end
			end
			if ctx.toast then
				ctx.toast("Preset: " .. (pr.name or "?"))
			end
		end
		s.mode = "select"
	elseif item == "BYPASS" then
		if sl then
			local newb = not sl.bypassed
			dsp.set_bypass(s.sel, newb)
			if sl.is_patch and ctx.live_set_bypass then
				ctx.live_set_bypass(s.sel, newb) -- keep the cross-process manifest in sync
			end
		end
		s.mode = "select"
	elseif item == "WET" then
		s.mode = "wet"
	elseif item == "MOVE UP" then
		if s.sel > 1 and dsp.swap_slots then
			dsp.swap_slots(s.sel, s.sel - 1)
			s.sel = s.sel - 1
		elseif ctx.toast then
			ctx.toast("Already at the top", "warn")
		end
		s.mode = "select"
	elseif item == "MOVE DOWN" then
		if s.sel < n and dsp.swap_slots then
			dsp.swap_slots(s.sel, s.sel + 1)
			s.sel = s.sel + 1
		elseif ctx.toast then
			ctx.toast("Already at the bottom", "warn")
		end
		s.mode = "select"
	elseif item == "CHANGE FX" then
		s.mode = "select"
		if ctx.pick_fx then
			ctx.pick_fx(s.sel)
		end
	elseif item == "CLEAR" then
		local was_patch = sl and sl.is_patch
		if dsp.unload_slot then
			dsp.unload_slot(s.sel)
		end
		if was_patch and ctx.live_remove then
			ctx.live_remove(s.sel) -- drop it from the cross-process manifest too
		end
		if ctx.toast then
			ctx.toast("Slot " .. s.sel .. " cleared")
		end
		s.mode = "select"
	elseif item == "RESET" then
		for _, p in ipairs(dsp.params(s.sel)) do
			if p.init ~= nil then
				dsp.set_param(s.sel, p.index, p.init)
			end
		end
		if ctx.toast then
			ctx.toast("Params reset")
		end
		s.mode = "select"
	elseif item == "RANDOMIZE" then
		for _, p in ipairs(dsp.params(s.sel)) do
			local lo, hi = p.min or 0, p.max or 1
			dsp.set_param(s.sel, p.index, lo + math.random() * (hi - lo))
		end
		if ctx.toast then
			ctx.toast("Params randomized")
		end
		s.mode = "select"
	end
end

function M.nav(ctx, action)
	local s = st(ctx)
	local n = ctx.dsp.slot_count()
	if n < 1 then
		return false
	end
	s.sel = math.max(1, math.min(n, s.sel))

	if s.mode == "wet" then -- WET level adjust sub-mode
		if action == "next" or action == "prev" then
			local sl = ctx.dsp.slot(s.sel)
			ctx.dsp.set_wet(s.sel, (sl and sl.wet or 0) + (action == "next" and 0.02 or -0.02))
			return true
		elseif action == "activate" or action == "back" then
			s.mode = "select"
			return true
		end
		return false
	elseif s.mode == "menu" then -- per-slot action menu
		local menu = slot_menu(ctx, s)
		if action == "next" then
			s.menu_sel = (s.menu_sel % #menu) + 1
			return true
		elseif action == "prev" then
			s.menu_sel = ((s.menu_sel - 2) % #menu) + 1
			return true
		elseif action == "back" then
			s.mode = "select"
			return true
		elseif action == "activate" or action == "wet" then
			run_menu_item(ctx, s, n)
			return true
		end
		return false
	end

	-- SELECT mode: turn = move selection, activate/wet = open menu (or picker if empty)
	if action == "next" then
		s.sel = (s.sel % n) + 1
		return true
	elseif action == "prev" then
		s.sel = ((s.sel - 2) % n) + 1
		return true
	elseif action == "activate" or action == "wet" then
		open_or_pick(ctx, s)
		return true
	end
	return false
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local CFG = ctx.CFG or {}
	local s = st(ctx)
	local n = ctx.dsp.slot_count()
	local m = ctx.dsp.meters() or {}
	local compact = W < 380
	local narrow = W < 560
	local x0 = 20

	-- header: chain summary (active / total · CPU). Compact keeps the count too.
	local hy = U.HEADER_Y
	local active_n = 0
	for i = 1, n do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and not sl.bypassed then
			active_n = active_n + 1
		end
	end
	U.text(x0, hy, compact and "FX CHAIN" or "SIGNAL CHAIN", C.turq, 220)
	U.text_r(
		W - 20,
		hy,
		compact and string.format("%d/%d", active_n, n)
			or string.format("%d/%d ON   CPU %d%%", active_n, n, math.floor(m.cpu or 0)),
		C.dim,
		160
	)
	U.line(x0, hy + 20, W - 20, hy + 20, C.border, 140)

	-- rack geometry (leave room for the footer hint + status band)
	local listY = hy + 30
	local rowH = math.max(compact and 20 or 22, math.min(compact and 30 or 40, (H - listY - 52) / math.max(n, 1)))
	local cableX = x0 + 11
	local bodyX = x0 + 26
	local bodyW = (W - 20) - bodyX
	local firstC = listY + rowH / 2
	local lastC = listY + (n - 1) * rowH + rowH / 2

	-- the signal cable threading the rack + a travelling pulse (the live path)
	U.line(cableX, firstC, cableX, lastC, C.border, 160)
	if ctx.S._playing ~= false and not CFG.reduce_motion and n > 1 then
		local py = firstC + (lastC - firstC) * ((ctx.S.t * 0.5) % 1)
		U.circle(cableX, py, 2, C.turq, 200)
	end

	for i = 1, n do
		local sl = ctx.dsp.slot(i)
		local y = listY + (i - 1) * rowH
		local cy = y + rowH / 2
		-- instruments read as violet across the whole row (node/rail/accent), FX cycle
		-- the per-slot palette, so a synth in the chain is obvious at a glance.
		local accent = (sl and sl.kind == "synth") and C.violet or U.SLOT_COLORS[((i - 1) % #U.SLOT_COLORS) + 1]
		local sel = (i == s.sel)
		local loaded = sl and sl.loaded
		local active = loaded and not sl.bypassed

		-- node on the cable: bright if active (glow tracks live signal level), hollow
		-- if bypassed, "addable" if empty+sel
		if active then
			local lv = (m.levels and m.levels[i]) or 0
			U.circle(cableX, cy, 4, accent, 230)
			U.circle(cableX, cy, 7 + lv * 5, accent, 55 + math.floor(lv * 120))
		elseif loaded then
			U.circle(cableX, cy, 3, C.dim, 180)
		else
			U.circle(cableX, cy, sel and 3 or 2, sel and C.turq or C.border, sel and 200 or 150)
		end

		-- row body + accent rail
		U.gradient_v(bodyX, y + 2, bodyW, rowH - 4, C.panel_hi, C.panel)
		if sel then
			U.rect(bodyX, y + 2, bodyW, rowH - 4, accent, 30)
			U.tline(bodyX, y + 2, bodyX + bodyW, y + 2, 1, accent, 160)
			U.tline(bodyX, y + rowH - 2, bodyX + bodyW, y + rowH - 2, 1, accent, 90)
		end
		U.tline(bodyX, y + 2, bodyX, y + rowH - 2, 3, active and accent or C.border, active and 255 or 120)

		U.text(bodyX + 10, cy - 8, string.format("%02d", i), C.dim, 180)
		if loaded then
			local name = U.ellipsize(sl.name or "USER", bodyW - 130)
			U.text(bodyX + 40, cy - 8, name, C.white, active and 255 or 150)
			-- instrument slots get a coloured tag, not just plain text
			if sl.kind == "synth" then
				U.text(bodyX + 40 + (#name + 1) * 8, cy - 8, "[SYN]", C.violet, 220)
			end
			-- a marketplace patch running live in the engine gets a turquoise [PCH] chip
			if sl.is_patch then
				U.text(bodyX + 40 + (#name + 1) * 8 + (sl.kind == "synth" and 6 * 8 or 0), cy - 8, "[PCH]", C.turq, 210)
			end
		else
			U.text(
				bodyX + 40,
				cy - 8,
				sel and "+ add effect" or "- empty -",
				sel and C.turq or C.dim,
				sel and 220 or 130
			)
		end

		-- ON/BYP pill (+ wet bar on wider panels)
		local pillW = 34
		local px = bodyX + bodyW - pillW - 8
		if loaded then
			local txt = (sl and sl.bypassed) and "BYP" or "ON"
			local col = (sl and sl.bypassed) and C.dim or C.green
			U.rect(px, y + 5, pillW, rowH - 10, col, 30)
			U.text_c(px + pillW / 2, cy - 8, txt, col, 230)
			-- wet/mix meter — ALWAYS shown (incl. compact, with a thinner bar), so
			-- panel users can see wet is adjustable. Scale to available width.
			local ww = compact and math.max(22, math.min(40, bodyW * 0.22))
				or (narrow and math.max(28, math.min(54, bodyW * 0.24)) or math.min(90, bodyW * 0.30))
			local wx = px - ww - 8
			local wetmode = (s.mode == "wet") and sel
			U.rect(wx, cy - 3, ww, 6, C.border, wetmode and 220 or 160)
			U.rect(wx, cy - 3, ww * (sl and sl.wet or 0), 6, accent, (sel or wetmode) and 255 or 150)
		end
	end

	-- per-slot action menu overlay
	if s.mode == "menu" then
		local sl = ctx.dsp.slot(s.sel)
		local menu = slot_menu(ctx, s)
		local mw, rh = 152, 20
		local mh = #menu * rh + 24
		local mx = math.min(W - mw - 16, bodyX + 60)
		local my = math.max(listY, math.min(H - mh - 38, listY + (s.sel - 1) * rowH))
		U.gradient_v(mx, my, mw, mh, C.panel_hi, C.panel)
		U.rect(mx, my, mw, mh, C.panel)
		U.tline(mx, my, mx + mw, my, 2, C.turq, 255)
		U.tline(mx, my + mh, mx + mw, my + mh, 2, C.turq, 255)
		U.text(mx + 10, my + 6, string.format("SLOT %02d", s.sel), C.turq, 230)
		for i, it in ipairs(menu) do
			local iy = my + 22 + (i - 1) * rh
			local isel = (i == s.menu_sel)
			local lbl = it
			if it == "BYPASS" then
				lbl = (sl and sl.bypassed) and "ENABLE" or "BYPASS"
			end
			-- dim items that would be a no-op for this slot
			local disabled = (it == "MOVE UP" and s.sel <= 1) or (it == "MOVE DOWN" and s.sel >= n)
			if isel then
				U.rect(mx + 4, iy - 2, mw - 8, rh - 2, C.turq, 40)
				U.tline(mx + 4, iy - 2, mx + 4, iy + rh - 4, 3, C.turq, 255)
			end
			U.text(
				mx + 14,
				iy + 2,
				lbl,
				(disabled and C.border) or (isel and C.white or C.dim),
				disabled and 110 or (isel and 255 or 180)
			)
		end
	end

	-- footer hint (consistent placement + vocabulary across screens)
	local hint = (s.mode == "wet") and "turn: WET level   sel/back: exit"
		or (s.mode == "menu") and "turn: choose   sel: do   back: close"
		or "turn: select slot   sel: menu (load/bypass/move)"
	U.footer(W, H, hint)
end

return M
