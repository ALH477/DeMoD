-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/mod_matrix.lua — the MODULATION MATRIX (LFO / env-follower / step).

  Each source generates a value that rides ON TOP of a param's set value (base + depth *
  signal) and writes through the control surface, so a modulated param also emits MIDI out.
  LFOs tempo-sync to the MIDI clock. State lives in ctx.modulation; persisted via
  ctx.save_bindings. A live value bar shows each source moving in real time.
  © 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "MOD MATRIX", short = "MOD" }

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
	ctx.S.mod = ctx.S.mod or { view = "list", sel = 1 }
	return ctx.S.mod
end

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

-- the editable fields of a source (varies by kind), as a row spec list
local function fields(s)
	if s.kind == "lfo" then
		local f = { "Shape", "Sync" }
		f[#f + 1] = s.sync and "Div" or "Rate"
		f[#f + 1] = "Depth"
		f[#f + 1] = "Polarity"
		return f
	elseif s.kind == "env" then
		return { "Slot", "Attack", "Release", "Gain" }
	elseif s.kind == "step" then
		return { "Length", "Edit Steps", "Randomize" }
	end
	return {}
end

local function field_display(MOD, s, label)
	if label == "Shape" then
		return s.shape or "sine"
	elseif label == "Sync" then
		return s.sync and "ON" or "OFF"
	elseif label == "Div" then
		return s.div or "1/4"
	elseif label == "Rate" then
		return string.format("%.2f Hz", s.rate_hz or 1)
	elseif label == "Depth" then
		return string.format("%d%%", math.floor((s.depth or 1) * 100 + 0.5))
	elseif label == "Polarity" then
		return s.bipolar and "bipolar" or "unipolar"
	elseif label == "Slot" then
		return tostring(s.slot or 1)
	elseif label == "Attack" then
		return (s.attack or 10) .. " ms"
	elseif label == "Release" then
		return (s.release or 120) .. " ms"
	elseif label == "Gain" then
		return string.format("%.1fx", s.gain or 1)
	elseif label == "Length" then
		return tostring(#(s.steps or {}))
	elseif label == "Edit Steps" then
		return "[ edit ]"
	elseif label == "Randomize" then
		return "[ go ]"
	end
	return ""
end

local function field_adjust(MOD, ctx, s, label, dir)
	if label == "Shape" then
		s.shape = cycle(MOD.LFO_SHAPES, s.shape or "sine", dir)
	elseif label == "Sync" then
		s.sync = not s.sync
	elseif label == "Div" then
		s.div = cycle(MOD.DIVS, s.div or "1/4", dir)
	elseif label == "Rate" then
		s.rate_hz = math.max(0.02, math.min(20, (s.rate_hz or 1) + dir * 0.05))
	elseif label == "Depth" then
		s.depth = math.max(0, math.min(1, (s.depth or 1) + dir * 0.05))
	elseif label == "Polarity" then
		s.bipolar = not s.bipolar
	elseif label == "Slot" then
		s.slot = math.max(1, math.min(ctx.dsp.slot_count(), (s.slot or 1) + dir))
	elseif label == "Attack" then
		s.attack = math.max(1, math.min(500, (s.attack or 10) + dir * 5))
	elseif label == "Release" then
		s.release = math.max(1, math.min(2000, (s.release or 120) + dir * 10))
	elseif label == "Gain" then
		s.gain = math.max(0, math.min(4, (s.gain or 1) + dir * 0.1))
	elseif label == "Length" then
		local n = math.max(1, math.min(16, #(s.steps or {}) + dir))
		local steps = {}
		for i = 1, n do
			steps[i] = (s.steps and s.steps[i]) or (i / n)
		end
		s.steps = steps
	elseif label == "Randomize" then
		for i = 1, #(s.steps or {}) do
			s.steps[i] = math.random()
		end
	end
end

local function detail_rows(MOD, s)
	local rows = {}
	for _, label in ipairs(fields(s)) do
		rows[#rows + 1] = { kind = "field", label = label }
	end
	for _, r in ipairs(MOD.routes_of(s.id)) do
		rows[#rows + 1] = { kind = "route", r = r }
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
				MOD.route_add(s.sid, it.id, 1.0, nil)
				save()
				ctx.toast("Route added", "ok")
			end
			s.view = "detail"
		elseif action == "back" then
			s.view = "detail"
		end
		return true
	end

	if s.view == "route" then
		local r = s.route
		s.rsel = s.rsel or 1 -- 1 = Depth (turn adjusts), 2 = Remove route (keyboard-reachable)
		if action == "next" or action == "prev" then
			local dir = action == "next" and 1 or -1
			if s.rsel == 1 and s.adjust then -- adjust depth in place
				r.depth = math.max(0, math.min(1, (r.depth or 1) + dir * 0.05))
			else
				s.rsel = (s.rsel == 1) and 2 or 1 -- move between Depth / Remove
			end
		elseif action == "activate" then
			if s.rsel == 1 then
				s.adjust = not s.adjust
			else -- Remove route
				MOD.route_remove(s.sid, r.target)
				save()
				ctx.toast("Route removed", "warn")
				s.adjust, s.view = false, "detail"
			end
		elseif action == "wet" then -- accelerator: remove route
			MOD.route_remove(s.sid, r.target)
			save()
			s.adjust, s.view = false, "detail"
		elseif action == "back" then
			if s.adjust then
				s.adjust = false
			else
				save()
				s.adjust, s.view = false, "detail"
			end
		end
		return true
	end

	-- step-sequencer value editor
	if s.view == "steps" then
		local src = MOD.source(s.sid)
		local steps = (src and src.steps) or {}
		if #steps == 0 then
			s.view = "detail"
			return true
		end
		s.stsel = math.max(1, math.min(s.stsel or 1, #steps))
		if action == "next" then
			if s.adjust then
				steps[s.stsel] = math.min(1, (steps[s.stsel] or 0) + 0.05)
			else
				s.stsel = math.min(#steps, s.stsel + 1)
			end
		elseif action == "prev" then
			if s.adjust then
				steps[s.stsel] = math.max(0, (steps[s.stsel] or 0) - 0.05)
			else
				s.stsel = math.max(1, s.stsel - 1)
			end
		elseif action == "activate" then
			s.adjust = not s.adjust
		elseif action == "back" then
			if s.adjust then
				s.adjust = false
			else
				save()
				s.view = "detail"
			end
		end
		return true
	end

	if s.view == "detail" then
		local src = MOD.source(s.sid)
		if not src then
			s.view = "list"
			return true
		end
		local rows = detail_rows(MOD, src)
		s.dsel = math.max(1, math.min(s.dsel or 1, #rows))
		local row = rows[s.dsel]
		if action == "next" or action == "prev" then
			local dir = action == "next" and 1 or -1
			if s.adjust and row.kind == "field" then
				field_adjust(MOD, ctx, src, row.label, dir)
			else
				s.dsel = math.max(1, math.min(s.dsel + dir, #rows))
			end
		elseif action == "activate" then
			if row.kind == "field" then
				if row.label == "Randomize" then
					field_adjust(MOD, ctx, src, row.label, 1)
					save()
				elseif row.label == "Edit Steps" then
					s.view, s.stsel, s.adjust = "steps", 1, false
				else
					s.adjust = not s.adjust
				end
			elseif row.kind == "route" then
				s.view, s.route, s.adjust, s.rsel = "route", row.r, false, 1
			elseif row.kind == "addroute" then
				s.view, s.psel = "pick", 1
			elseif row.kind == "delete" then
				MOD.source_remove(s.sid)
				save()
				s.view = "list"
				ctx.toast("Source removed", "ok")
			end
		elseif action == "wet" and row.kind == "route" then
			MOD.route_remove(s.sid, row.r.target)
			save()
		elseif action == "back" then
			if s.adjust then
				s.adjust = false
			else
				save()
				s.view = "list"
			end
		end
		return true
	end

	-- list view (+ add rows)
	local srcs = MOD.sources()
	local ADD = { "lfo", "env", "step" }
	local n = #srcs + #ADD
	s.sel = math.max(1, math.min(s.sel or 1, n))
	if action == "next" then
		s.sel = math.min(s.sel + 1, n)
	elseif action == "prev" then
		s.sel = math.max(s.sel - 1, 1)
	elseif action == "activate" then
		if s.sel > #srcs then
			local kind = ADD[s.sel - #srcs]
			local src = MOD.source_new(nil, kind, {})
			save()
			s.view, s.sid, s.dsel, s.adjust = "detail", src.id, 1, false
		else
			s.view, s.sid, s.dsel, s.adjust = "detail", srcs[s.sel].id, 1, false
		end
	end
	return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────
local function vbar(U, C, x, y, w, v01, accent)
	U.rect(x, y, w, 6, C.border, 90)
	U.rect(x, y, math.floor(w * (v01 or 0)), 6, accent, 210)
end

-- live scrolling scope: connect the source's history samples (0..1) into a waveform
local function scope(U, C, x, y, w, h, hist, accent)
	U.rect(x, y, w, h, accent, 10)
	U.line(x, y + h / 2, x + w, y + h / 2, C.border, 70) -- midline
	local n = #hist
	if n < 2 then
		return
	end
	local px, py
	for i = 1, n do
		local xx = x + (i - 1) / (n - 1) * w
		local yy = y + h - (hist[i] or 0) * h
		if px then
			U.line(px, py, xx, yy, accent, 210)
		end
		px, py = xx, yy
	end
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local MOD, B = ctx.modulation, ctx.bindings
	U.text(20, U.HEADER_Y, "MOD MATRIX", C.turq, 220)
	if not (MOD and B) then
		U.text_c(W / 2, H / 2, "modulation unavailable", C.dim, 170)
		U.footer(W, H, "unavailable")
		return
	end
	dm.redraw() -- keep live source bars animating
	local s = stt(ctx)
	U.line(20, 74, W - 20, 74, C.border, 140)
	local y0 = U.CONTENT_TOP + 6
	local rowH = 24

	if s.view == "pick" then
		U.text_r(W - 20, U.HEADER_Y, "pick a parameter to modulate", C.dim, 150)
		local list = param_list(ctx)
		if #list == 0 then
			U.text_c(W / 2, H / 2, "no parameters loaded - load an effect first", C.dim, 160)
			U.footer(W, H, "back: cancel")
			return
		end
		for i = 1, math.min(#list, math.floor((H - y0 - 52) / rowH)) do
			local it, sel = list[i], i == s.psel
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
		local r = s.route
		s.rsel = s.rsel or 1
		U.text_r(W - 20, U.HEADER_Y, U.ellipsize(r and r.target or "", 240), C.dim, 150)
		-- row 1: Depth
		local dsel = s.rsel == 1
		if dsel then
			U.rect(20, y0, W - 40, rowH - 4, s.adjust and C.violet or C.turq, s.adjust and 50 or 32)
			U.tline(20, y0, 20, y0 + rowH - 4, 3, C.turq, 255)
		end
		U.text(36, y0 + 4, "Depth", dsel and C.white or C.dim, dsel and 235 or 170)
		U.text_r(W - 36, y0 + 4, string.format("%d%%", math.floor((r.depth or 1) * 100 + 0.5)), C.green, 220)
		vbar(U, C, 36, y0 + 30, W - 72, r.depth, C.violet)
		-- row 2: Remove route
		local ry = y0 + 50
		local rsel = s.rsel == 2
		if rsel then
			U.rect(20, ry, W - 40, rowH - 4, C.red, 45)
			U.tline(20, ry, 20, ry + rowH - 4, 3, C.red, 255)
		end
		U.text(36, ry + 4, "[ remove route ]", rsel and C.red or C.dim, rsel and 235 or 150)
		U.footer(
			W,
			H,
			s.adjust and "turn: depth   sel/back: done"
				or "turn: row   sel: "
					.. (s.rsel == 1 and "adjust depth" or "remove")
					.. "   back: done   tab: screen"
		)
		return
	end

	if s.view == "steps" then
		local src = MOD.source(s.sid)
		local steps = (src and src.steps) or {}
		U.text_r(W - 20, U.HEADER_Y, "step sequencer  " .. (s.sid or ""), C.dim, 150)
		local n = #steps
		if n == 0 then
			U.footer(W, H, "back")
			return
		end
		local gx, gw = 36, W - 72
		local gy = y0 + 10
		local gh = math.max(60, math.min(H - y0 - 70, 170))
		U.rect(gx, gy, gw, gh, C.turq, 8)
		U.line(gx, gy + gh, gx + gw, gy + gh, C.border, 120)
		local bw = gw / n
		for i = 1, n do
			local v = steps[i] or 0
			local x = gx + (i - 1) * bw
			local bh = math.floor(v * gh)
			local sel = i == s.stsel
			local cur = src._idx == i
			local col = cur and C.violet or (sel and C.white or C.turq)
			U.rect(x + 2, gy + gh - bh, math.max(2, bw - 4), bh, col, sel and 235 or (cur and 205 or 130))
			if sel then
				U.tline(x + 2, gy, x + 2, gy + gh, 2, C.white, 110)
			end
		end
		U.footer(W, H, s.adjust and "turn: value   sel/back: done" or "turn: step   sel: adjust   back: out")
		return
	end

	if s.view == "detail" then
		local src = MOD.source(s.sid)
		if not src then
			U.footer(W, H, "back")
			return
		end
		U.text_r(W - 20, U.HEADER_Y, (src.kind:upper()) .. "  " .. src.id, C.violet, 200)
		-- live scrolling scope of the source's output
		local scopeH = 36
		scope(U, C, 36, 80, W - 72, scopeH, MOD.history(s.sid), C.turq)
		local rows = detail_rows(MOD, src)
		local top = 80 + scopeH + 8
		for i, row in ipairs(rows) do
			local sel = i == (s.dsel or 1)
			local y = top + (i - 1) * rowH
			if sel then
				local adj = s.adjust and row.kind == "field"
				U.rect(20, y, W - 40, rowH - 4, adj and C.violet or C.turq, adj and 50 or 32)
				U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
			end
			if row.kind == "field" then
				U.text(36, y + 4, row.label, sel and C.white or C.dim, sel and 235 or 170)
				U.text_r(
					W - 36,
					y + 4,
					field_display(MOD, src, row.label),
					sel and C.white or C.green,
					sel and 235 or 180
				)
			elseif row.kind == "route" then
				U.text(
					36,
					y + 4,
					U.ellipsize(row.r.target, math.floor(W * 0.5)),
					sel and C.white or C.dim,
					sel and 235 or 170
				)
				U.text_r(
					W - 36,
					y + 4,
					"depth " .. math.floor((row.r.depth or 1) * 100 + 0.5) .. "%",
					C.green,
					sel and 220 or 160
				)
			elseif row.kind == "addroute" then
				U.text(36, y + 4, "[ + add route ]", sel and C.turq or C.dim, sel and 235 or 150)
			elseif row.kind == "delete" then
				U.text(36, y + 4, "[ delete source ]", sel and C.red or C.dim, sel and 230 or 150)
			end
		end
		U.footer(W, H, "turn: row   sel: open/adjust   back: list   tab: screen")
		return
	end

	-- list view
	U.text_r(W - 20, U.HEADER_Y, "LFO / env / step -> params", C.dim, 150)
	local srcs = MOD.sources()
	local ADD = { "+ LFO", "+ ENV", "+ STEP" }
	local n = #srcs + #ADD
	s.sel = math.max(1, math.min(s.sel or 1, n))
	if #srcs == 0 then
		U.text_c(W / 2, y0 + 24, "no modulation sources yet", C.dim, 170)
	end
	for i = 1, n do
		local y = y0 + (i - 1) * rowH
		local sel = i == s.sel
		if sel then
			U.rect(20, y, W - 40, rowH - 4, C.turq, 32)
			U.tline(20, y, 20, y + rowH - 4, 3, C.turq, 255)
		end
		if i > #srcs then
			U.text(36, y + 4, ADD[i - #srcs], sel and C.turq or C.dim, sel and 235 or 150)
		else
			local src = srcs[i]
			U.text(36, y + 4, src.kind:upper() .. "  " .. src.id, sel and C.white or C.dim, sel and 235 or 175)
			U.text_r(W - 170, y + 4, #MOD.routes_of(src.id) .. " rt", C.dim, 160)
			vbar(U, C, W - 130, y + 7, 90, src.bipolar and ((src._val or 0) + 1) / 2 or (src._val or 0), C.violet)
		end
	end
	U.footer(W, H, "turn: select   sel: open   ( add LFO/ENV/STEP at the end )")
end

return M
