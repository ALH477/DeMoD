-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/macros.lua — the MACRO manager (one control -> many params).

  A macro fans one value out to several parameters, each through its own shaping
  (range / curve / invert). Drive it from its assigned CC (DRIVER), from a gamepad/
  encoder, or by sweeping the VALUE row here. State lives in ctx.modulation
  (modulation.lua); routes write through ctx.bindings (control_surface) so each routed
  param moves AND emits MIDI out, echo-safe. Persisted via ctx.save_bindings.
  © 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "MACROS", short = "MAC" }

local CURVE_OPTS = { "lin", "exp", "log", "s" }
local ROUTE_ROWS = { "Curve", "Invert", "Range Lo", "Range Hi", "Remove" }

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

local function stt(ctx)
	ctx.S.mac = ctx.S.mac or { view = "list", sel = 1 }
	return ctx.S.mac
end

-- flat list of every param across loaded slots (same ids the BINDINGS screen uses)
local function param_list(ctx)
	local list = {}
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded then
			for _, p in ipairs(ctx.dsp.params(i) or {}) do
				list[#list + 1] =
					{ slot = i, sname = sl.name or ("SLOT " .. i), p = p, id = "slot" .. i .. ".p" .. p.index }
			end
		end
	end
	return list
end

local function register(ctx, it)
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

-- rows shown in a macro's detail view
local function detail_rows(mac)
	local rows = { { kind = "value" }, { kind = "driver" }, { kind = "perf" } }
	for i, r in ipairs(mac.routes) do
		rows[#rows + 1] = { kind = "route", idx = i, r = r }
	end
	rows[#rows + 1] = { kind = "addroute" }
	rows[#rows + 1] = { kind = "delete" }
	return rows
end

-- ── nav ──────────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local MOD, B = ctx.modulation, ctx.bindings
	if not (MOD and B) then
		return false
	end
	-- never swallow the global navigation actions: tab/tab_prev switch screens, play_stop
	-- toggles the master song transport. Returning false lets dsp_studio's nav handle them,
	-- so you're never trapped on this screen (it otherwise returns true for everything).
	if action == "tab" or action == "tab_prev" or action == "play_stop" then
		return false
	end
	local s = stt(ctx)
	local save = ctx.save_bindings or function() end

	-- param picker (adding a route)
	if s.view == "pick" then
		local list = param_list(ctx)
		s.psel = math.max(1, math.min(s.psel or 1, math.max(1, #list)))
		if action == "next" then
			s.psel = math.min(s.psel + 1, #list)
		elseif action == "prev" then
			s.psel = math.max(s.psel - 1, 1)
		elseif action == "activate" then
			local it = list[s.psel]
			if it then
				register(ctx, it)
				MOD.macro_add_route(s.mid, it.id, nil)
				save()
				ctx.toast("Route added", "ok")
			end
			s.view = "detail"
		elseif action == "back" then
			s.view = "detail"
		end
		return true
	end

	-- route shaping editor
	if s.view == "route" then
		local sh = s.rsh
		local r = ROUTE_ROWS[s.rsel or 1]
		if action == "next" or action == "prev" then
			local dir = action == "next" and 1 or -1
			if s.adjust then
				if r == "Curve" then
					sh.curve = cycle(CURVE_OPTS, sh.curve or "lin", dir)
				elseif r == "Invert" then
					sh.invert = not sh.invert
				elseif r == "Range Lo" then
					sh.lo = math.max(0, math.min(1, (sh.lo or 0) + dir * 0.05))
				elseif r == "Range Hi" then
					sh.hi = math.max(0, math.min(1, (sh.hi or 1) + dir * 0.05))
				end
			else
				s.rsel = (((s.rsel or 1) - 1 + dir) % #ROUTE_ROWS) + 1
			end
		elseif action == "activate" then
			if r == "Remove" then
				MOD.macro_remove_route(s.mid, s.ridx)
				save()
				s.view = "detail"
			else
				s.adjust = not s.adjust
			end
		elseif action == "back" then
			if s.adjust then
				s.adjust = false
			else
				local mac = MOD.macro(s.mid)
				local rt = mac and mac.routes[s.ridx]
				if rt then
					local clean = (sh.curve == nil or sh.curve == "lin")
						and not sh.invert
						and (sh.lo or 0) == 0
						and (sh.hi or 1) == 1
					rt.sh = clean and nil or sh
				end
				save()
				s.view = "detail"
			end
		end
		return true
	end

	-- macro detail (rows = value, driver, routes..., add route, delete)
	if s.view == "detail" then
		local mac = MOD.macro(s.mid)
		if not mac then
			s.view = "list"
			return true
		end
		local rows = detail_rows(mac)
		s.dsel = math.max(1, math.min(s.dsel or 1, #rows))
		local row = rows[s.dsel]
		if action == "next" or action == "prev" then
			local dir = action == "next" and 1 or -1
			if s.adjust and row.kind == "value" then
				MOD.macro_set(s.mid, math.max(0, math.min(1, MOD.macro_value(s.mid) + dir * 0.05)))
			else
				s.dsel = math.max(1, math.min(s.dsel + dir, #rows))
			end
		elseif action == "activate" then
			if row.kind == "value" then
				s.adjust = not s.adjust
			elseif row.kind == "driver" then
				MOD.begin_assign_driver(s.mid)
				s.learning_driver = true
				ctx.toast("Driver: twist a CC", "info")
			elseif row.kind == "perf" then
				local on = not MOD.is_perf("macro", s.mid)
				MOD.set_perf(on and "macro" or nil, s.mid)
				save()
				ctx.toast(on and "Perf: gamepad/encoder sweeps this macro" or "Perf cleared", "info")
			elseif row.kind == "route" then
				local rt = mac.routes[row.idx]
				s.view, s.ridx, s.rsel, s.adjust = "route", row.idx, 1, false
				s.rsh = {
					curve = rt.sh and rt.sh.curve,
					invert = rt.sh and rt.sh.invert,
					lo = rt.sh and rt.sh.lo,
					hi = rt.sh and rt.sh.hi,
				}
			elseif row.kind == "addroute" then
				s.view, s.psel = "pick", 1
			elseif row.kind == "delete" then
				MOD.macro_remove(s.mid)
				save()
				s.view = "list"
				ctx.toast("Macro deleted", "ok")
			end
		elseif action == "wet" and row.kind == "route" then
			MOD.macro_remove_route(s.mid, row.idx)
			save()
		elseif action == "back" then
			if s.adjust then
				s.adjust = false
			else
				s.view = "list"
			end
		end
		return true
	end

	-- macro list (+ "new macro" row)
	local macs = MOD.macros()
	local n = #macs + 1
	s.sel = math.max(1, math.min(s.sel or 1, n))
	if action == "next" then
		s.sel = math.min(s.sel + 1, n)
	elseif action == "prev" then
		s.sel = math.max(s.sel - 1, 1)
	elseif action == "activate" then
		if s.sel > #macs then -- the "new macro" row
			local mac = MOD.macro_new(nil, "Macro " .. (MOD.macro_count() + 1))
			save()
			s.view, s.mid, s.dsel, s.adjust = "detail", mac.id, 1, false
		else
			s.view, s.mid, s.dsel, s.adjust = "detail", macs[s.sel].id, 1, false
		end
	elseif action == "wet" and s.sel <= #macs then
		-- toggle this macro as the encoder/gamepad performance focus
		local id = macs[s.sel].id
		MOD.set_perf(MOD.is_perf("macro", id) and nil or "macro", id)
		save()
		ctx.toast(MOD.is_perf("macro", id) and "Perf: gamepad/encoder sweeps this macro" or "Perf cleared", "info")
	end
	return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────
local function bar(U, C, x, y, w, v01, accent)
	U.rect(x, y, w, 6, C.border, 90)
	U.rect(x, y, math.floor(w * (v01 or 0)), 6, accent, 200)
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local MOD, B = ctx.modulation, ctx.bindings
	U.text(20, U.HEADER_Y, "MACROS", C.turq, 220)
	if not (MOD and B) then
		U.text_c(W / 2, H / 2, "macros unavailable", C.dim, 170)
		U.footer(W, H, "unavailable")
		return
	end
	local s = stt(ctx)

	-- a driver learn just resolved → persist + toast
	if s.learning_driver and not MOD.is_assigning_driver() then
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		ctx.toast("Driver assigned", "ok")
		s.learning_driver = nil
	end

	U.line(20, 74, W - 20, 74, C.border, 140)
	local y0 = U.CONTENT_TOP + 6
	local rowH = 24

	if s.view == "pick" then
		U.text_r(W - 20, U.HEADER_Y, "pick a parameter to route", C.dim, 150)
		local list = param_list(ctx)
		if #list == 0 then
			U.text_c(W / 2, H / 2, "no parameters loaded - load an effect first", C.dim, 160)
			U.footer(W, H, "back: cancel")
			return
		end
		for i = 1, math.min(#list, math.floor((H - y0 - 52) / rowH)) do
			local it = list[i]
			local sel = i == s.psel
			local y = y0 + (i - 1) * rowH
			if sel then
				U.rect(20, y, W - 40, rowH - 4, C.turq, 32)
				U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
			end
			U.text(
				36,
				y + 4,
				U.ellipsize(it.sname .. ": " .. (it.p.label or "?"), W - 80),
				sel and C.white or C.dim,
				sel and 235 or 170
			)
		end
		U.footer(W, H, "turn: select   sel: add route   back: cancel")
		return
	end

	if s.view == "route" then
		local mac = MOD.macro(s.mid)
		local rt = mac and mac.routes[s.ridx]
		U.text_r(W - 20, U.HEADER_Y, U.ellipsize(rt and rt.target or "", 240), C.dim, 150)
		local sh = s.rsh or {}
		for i, label in ipairs(ROUTE_ROWS) do
			local sel = i == (s.rsel or 1)
			local y = y0 + (i - 1) * rowH
			if sel then
				U.rect(20, y, W - 40, rowH - 4, s.adjust and C.violet or C.turq, s.adjust and 50 or 32)
			end
			local val = ""
			if label == "Curve" then
				val = sh.curve or "lin"
			elseif label == "Invert" then
				val = sh.invert and "ON" or "OFF"
			elseif label == "Range Lo" then
				val = string.format("%d%%", math.floor((sh.lo or 0) * 100 + 0.5))
			elseif label == "Range Hi" then
				val = string.format("%d%%", math.floor((sh.hi or 1) * 100 + 0.5))
			end
			U.text(36, y + 4, label, sel and C.white or C.dim, sel and 235 or 165)
			U.text_r(W - 36, y + 4, val, sel and C.white or C.green, sel and 235 or 180)
		end
		U.footer(W, H, s.adjust and "turn: change   sel: done   back: cancel" or "turn: row   sel: adjust   back: save")
		return
	end

	if s.view == "detail" then
		local mac = MOD.macro(s.mid)
		if not mac then
			U.footer(W, H, "back")
			return
		end
		U.text_r(W - 20, U.HEADER_Y, U.ellipsize(mac.label or mac.id, 240), C.violet, 200)
		local rows = detail_rows(mac)
		for i, row in ipairs(rows) do
			local sel = i == (s.dsel or 1)
			local y = y0 + (i - 1) * rowH
			if sel then
				U.rect(
					20,
					y,
					W - 40,
					rowH - 4,
					(s.adjust and row.kind == "value") and C.violet or C.turq,
					(s.adjust and row.kind == "value") and 50 or 32
				)
				U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
			end
			if row.kind == "value" then
				U.text(36, y + 4, "Value", sel and C.white or C.dim, sel and 235 or 170)
				bar(U, C, W - 180, y + 7, 140, MOD.macro_value(s.mid), C.violet)
			elseif row.kind == "driver" then
				local d = mac.driver
				local tag = s.learning_driver and "LEARN..."
					or (d and ((d.source == "foot" and "FS" or "CC") .. tostring(d.code)) or "none")
				U.text(36, y + 4, "Driver", sel and C.white or C.dim, sel and 235 or 170)
				U.text_r(W - 36, y + 4, tag, sel and C.white or C.green, sel and 235 or 175)
			elseif row.kind == "perf" then
				U.text(36, y + 4, "Perf (gamepad)", sel and C.white or C.dim, sel and 235 or 170)
				U.text_r(
					W - 36,
					y + 4,
					MOD.is_perf("macro", s.mid) and "ON" or "OFF",
					sel and C.white or C.green,
					sel and 235 or 175
				)
			elseif row.kind == "route" then
				local tg = U.ellipsize(row.r.target, math.floor(W * 0.4))
				local sh = row.r.sh
				local meta = sh
						and ((sh.curve or "lin") .. " " .. math.floor((sh.lo or 0) * 100 + 0.5) .. "-" .. math.floor(
							(sh.hi or 1) * 100 + 0.5
						))
					or "lin"
				U.text(36, y + 4, tg, sel and C.white or C.dim, sel and 235 or 170)
				U.text_r(W - 36, y + 4, meta, C.green, sel and 220 or 160)
			elseif row.kind == "addroute" then
				U.text(36, y + 4, "[ + add route ]", sel and C.turq or C.dim, sel and 235 or 150)
			elseif row.kind == "delete" then
				U.text(36, y + 4, "[ delete macro ]", sel and C.red or C.dim, sel and 230 or 150)
			end
		end
		U.footer(W, H, "turn: row   sel: open/adjust   back: list   tab: screen")
		return
	end

	-- list view
	U.text_r(W - 20, U.HEADER_Y, "one control -> many params", C.dim, 150)
	local macs = MOD.macros()
	local n = #macs + 1
	s.sel = math.max(1, math.min(s.sel or 1, n))
	if #macs == 0 then
		U.text_c(W / 2, y0 + 30, "no macros yet", C.dim, 170)
	end
	for i = 1, n do
		local y = y0 + (i - 1) * rowH
		local sel = i == s.sel
		if sel then
			U.rect(20, y, W - 40, rowH - 4, C.turq, 32)
			U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
		end
		if i > #macs then
			U.text(36, y + 4, "[ + new macro ]", sel and C.turq or C.dim, sel and 235 or 150)
		else
			local mac = macs[i]
			U.text(
				36,
				y + 4,
				U.ellipsize(mac.label or mac.id, math.floor(W * 0.45)),
				sel and C.white or C.dim,
				sel and 235 or 175
			)
			if MOD.is_perf("macro", mac.id) then
				U.text_r(W - 245, y + 4, "PERF", C.turq, 205)
			end
			U.text_r(W - 190, y + 4, #mac.routes .. (#mac.routes == 1 and " route" or " routes"), C.dim, 160)
			bar(U, C, W - 150, y + 7, 110, mac.value01, C.violet)
		end
	end
	U.footer(W, H, "turn: select   sel: open   tab: screen   ( + new macro )")
end

return M
