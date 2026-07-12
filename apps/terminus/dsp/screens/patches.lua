-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/patches.lua — live patches manager.

  The dedicated place to see what marketplace patches are running in the engine and
  turn them on/off. One focus field over: an ADD row (opens the FX picker on the next
  free slot), each running patch (toggle ON/BYP or UNLOAD via a tiny menu), and an
  UNLOAD-ALL row. Backend-agnostic — only talks to ctx.dsp + the ctx.* patch helpers
  defined in dsp_studio.lua (load_patch_entry / free_slot / unload_all_patches).
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "PATCHES", short = "PCH" }

local function st(ctx)
	ctx.S.patches = ctx.S.patches or { sel = 1, mode = "list", menu_sel = 1 }
	return ctx.S.patches
end

-- focus rows: ADD, each live patch slot, then UNLOAD-ALL (only when something is live)
local function rows(ctx)
	local r = { { kind = "add", free = ctx.free_slot and ctx.free_slot() or nil } }
	local live = 0
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and sl.is_patch then
			r[#r + 1] = { kind = "live", slot = i, sl = sl }
			live = live + 1
		end
	end
	if live > 0 then
		r[#r + 1] = { kind = "all" }
	end
	return r, live
end

-- per-patch action menu (positions: 1 toggle, 2 unload, 3 cancel)
local function run_menu(ctx, row)
	local s = st(ctx)
	if row and row.kind == "live" then
		local sl = ctx.dsp.slot(row.slot)
		if s.menu_sel == 1 then -- toggle ON/BYP
			if sl then
				ctx.dsp.set_bypass(row.slot, not sl.bypassed)
				if ctx.live_set_bypass then
					ctx.live_set_bypass(row.slot, not sl.bypassed)
				end
			end
		elseif s.menu_sel == 2 then -- unload (turn off completely)
			if ctx.dsp.unload_slot then
				ctx.dsp.unload_slot(row.slot)
			end
			if ctx.live_remove then
				ctx.live_remove(row.slot)
			end
			if ctx.toast then
				ctx.toast("Unloaded " .. ((sl and sl.name) or "patch"))
			end
		end
	end
	s.mode = "list"
end

function M.nav(ctx, action)
	local s = st(ctx)
	local r = rows(ctx)
	s.sel = math.max(1, math.min(s.sel, #r))
	if s.mode == "menu" then
		if action == "next" then
			s.menu_sel = (s.menu_sel % 3) + 1
			return true
		elseif action == "prev" then
			s.menu_sel = ((s.menu_sel - 2) % 3) + 1
			return true
		elseif action == "activate" then
			run_menu(ctx, r[s.sel])
			return true
		elseif action == "back" then
			s.mode = "list"
			return true
		end
		return false
	end
	if action == "next" then
		s.sel = (s.sel % #r) + 1
		return true
	elseif action == "prev" then
		s.sel = ((s.sel - 2) % #r) + 1
		return true
	elseif action == "activate" or action == "wet" then
		local row = r[s.sel]
		if not row then
			return true
		end
		if row.kind == "add" then
			if row.free and ctx.pick_fx then
				ctx.pick_fx(row.free) -- reuse the (patch-aware) FX picker on the free slot
			elseif ctx.toast then
				ctx.toast("Rack full - clear a slot first", "warn")
			end
		elseif row.kind == "live" then
			s.mode, s.menu_sel = "menu", 1
		elseif row.kind == "all" then
			if ctx.unload_all_patches then
				ctx.unload_all_patches()
			end
			s.sel = 1
		end
		return true
	end
	return false -- back falls through to the chrome (returns to FX chain)
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local r, live = rows(ctx)
	local mt = ctx.dsp.meters() or {}
	U.header(W, "LIVE PATCHES", string.format("%d running", live), C.turq)
	local x0 = 20
	local y = U.CONTENT_TOP + 18
	local rowH = 26

	for i, row in ipairs(r) do
		local sel = (i == s.sel)
		local ry = y + (i - 1) * rowH
		if sel then
			U.rect(x0, ry - 2, W - 40, rowH - 4, C.turq, 28)
			U.tline(x0, ry - 2, x0, ry + rowH - 6, 3, C.turq, 200)
		end
		if row.kind == "add" then
			local lbl = row.free and ("+ ADD PATCH   -> slot " .. row.free) or "+ ADD PATCH   (rack full)"
			U.text(x0 + 12, ry + 3, lbl, row.free and (sel and C.white or C.turq) or C.dim, sel and 255 or 180)
		elseif row.kind == "all" then
			U.text(x0 + 12, ry + 3, "UNLOAD ALL PATCHES", sel and C.white or C.red, sel and 255 or 190)
		else
			local sl = row.sl
			local active = sl.loaded and not sl.bypassed
			local accent = (sl.kind == "synth") and C.violet or C.turq
			local lv = (mt.levels and mt.levels[row.slot]) or 0
			U.circle(
				x0 + 7,
				ry + rowH / 2 - 2,
				active and 4 or 3,
				active and accent or C.dim,
				active and (150 + math.floor(lv * 100)) or 140
			)
			U.text(x0 + 24, ry + 3, string.format("%02d", row.slot), C.dim, 160)
			U.text(
				x0 + 52,
				ry + 3,
				U.ellipsize(sl.name or "PATCH", W - 240),
				sel and C.white or (active and C.white or C.dim),
				active and 255 or 150
			)
			if sl.kind == "synth" then
				U.text_r(W - 80, ry + 3, "[SYN]", C.violet, 200)
			end
			U.text_r(W - 24, ry + 3, active and "ON" or "BYP", active and C.green or C.dim, 220)
		end
	end

	if live == 0 then
		U.text(x0 + 12, y + rowH + 10, "No patches running.", C.dim, 170)
		U.text(x0 + 12, y + rowH + 28, "Add one above, or load from the FX picker (CHANGE FX).", C.dim, 140)
	end

	if s.mode == "menu" then
		local row = r[s.sel]
		local sl = row and row.sl
		local items = { (sl and not sl.bypassed) and "BYPASS" or "ENABLE", "UNLOAD", "CANCEL" }
		local mw, rh = 150, 22
		local mh = #items * rh + 12
		local mx = math.min(W - mw - 20, x0 + 90)
		local my = math.min(H - mh - 36, y + (s.sel - 1) * rowH)
		U.gradient_v(mx, my, mw, mh, C.panel_hi, C.panel)
		U.rect(mx, my, mw, mh, C.panel)
		U.tline(mx, my, mx + mw, my, 2, C.turq, 255)
		U.tline(mx, my + mh, mx + mw, my + mh, 2, C.turq, 255)
		for i, it in ipairs(items) do
			local iy = my + 6 + (i - 1) * rh
			local isel = (i == s.menu_sel)
			if isel then
				U.rect(mx + 4, iy - 2, mw - 8, rh - 2, C.turq, 40)
				U.tline(mx + 4, iy - 2, mx + 4, iy + rh - 4, 3, C.turq, 255)
			end
			U.text(mx + 12, iy + 2, it, isel and C.white or C.dim, isel and 255 or 180)
		end
	end

	local hint = (s.mode == "menu") and "turn: choose   sel: do   back: close"
		or "turn: select   sel: add / toggle / unload   back: FX"
	U.footer(W, H, hint)
end

return M
