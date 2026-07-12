-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/routing.lua — engine-centric audio routing.

  A simple signal-flow view: SOURCES -> [DeMoD RACK] -> SINKS. Pick what feeds the
  rack input and where its output goes; each row is a stereo pair you connect or
  disconnect. Drives the JACK/PipeWire graph through ctx.route (route.lua ->
  scripts/demod-route.sh). The whole thing is one focus field (turn to pick a row,
  press to toggle) so it works on an encoder exactly as on mouse/keyboard.

  Off the engine (stub backend / no demod-rt) it shows an illustrative synthetic
  graph so the model is legible, and toggling is a no-op with a hint.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "ROUTING", short = "RTG" }

local function st(ctx)
	ctx.S.route = ctx.S.route or { sel = 1, poll = 99, graph = nil, show_monitors = false }
	return ctx.S.route
end

-- real (editable) routing only when we can shell out AND a real engine is present
local function available(ctx)
	local bn = ctx.dsp.backend_name and ctx.dsp.backend_name() or "stub"
	return ctx.route ~= nil and ctx.route.available() and bn ~= "stub"
end

-- flatten the focus list: a leading view-toggle row (keyboard-reachable), then
-- sources, then sinks. Index 1 is always the monitors toggle, so draw() offsets the
-- source/sink rows by +1 to keep `li == s.sel` aligned.
local function items(s)
	local g = s.graph
	local list = { { role = "monitors" } }
	if g then
		for _, r in ipairs(g.sources or {}) do
			list[#list + 1] = { role = "source", row = r }
		end
		for _, r in ipairs(g.sinks or {}) do
			list[#list + 1] = { role = "sink", row = r }
		end
	end
	return list
end

function M.update(ctx, dt)
	local s = st(ctx)
	if not ctx.route then
		return
	end
	s.poll = (s.poll or 0) + (dt or 0)
	if s.poll > 1.0 then -- ~1 Hz: the graph rarely changes and the query forks pw-link
		s.poll = 0
		s.graph = ctx.route.graph({ live = available(ctx), monitors = s.show_monitors })
		local n = #items(s)
		s.sel = math.max(1, math.min(s.sel or 1, math.max(1, n)))
	end
end

function M.nav(ctx, action)
	local s = st(ctx)
	local list = items(s)
	if action == "next" then
		s.sel = math.min((s.sel or 1) + 1, math.max(1, #list))
		return true
	elseif action == "prev" then
		s.sel = math.max((s.sel or 1) - 1, 1)
		return true
	elseif action == "wet" then -- accelerator (X / hardware long-press): toggle monitors
		s.show_monitors = not s.show_monitors
		s.poll = 9 -- re-query immediately with the new monitor setting
		if ctx.toast then
			ctx.toast(s.show_monitors and "Showing monitor sources" or "Hiding monitor sources", "ok")
		end
		return true
	elseif action == "activate" then
		local it = list[s.sel]
		if not it then
			return true
		end
		if it.role == "monitors" then -- the leading view-toggle row (keyboard-reachable)
			s.show_monitors = not s.show_monitors
			s.poll = 9
			if ctx.toast then
				ctx.toast(s.show_monitors and "Showing monitor sources" or "Hiding monitor sources", "ok")
			end
			return true
		end
		if not available(ctx) or (s.graph and s.graph.synthetic) then
			if ctx.toast then
				local why = (s.graph and s.graph.reason == "pwlink") and "Needs PipeWire (pw-link)"
					or "Routing needs the audio engine"
				ctx.toast(why, "warn")
			end
			return true
		end
		local r = it.row
		if r.connected then
			ctx.route.disconnect(it.role, r.portL, r.portR)
		else
			ctx.route.connect(it.role, r.portL, r.portR)
		end
		r.connected = not r.connected -- optimistic; the next poll reconciles with reality
		s.poll = 9 -- force a graph refresh on the next update (fast reconcile)
		if ctx.toast then
			ctx.toast((r.connected and "Connected " or "Disconnected ") .. (r.label or ""), "ok")
		end
		return true
	end
	return false -- "back" falls through to the chrome (returns to FX chain)
end

-- draw one routing row + its endpoint node; returns the node's {x,y}
local function draw_row(ctx, r, sel, x, y, w, nodeX, side)
	local U, C = ctx.U, ctx.C
	local rowH = 20
	if sel then
		U.rect(x, y - 2, w, rowH, C.turq, 28)
		U.tline(x, y - 2, x, y + rowH - 2, 3, C.turq, 200)
	end
	local col = r.connected and C.turq or C.dim
	-- "*" marks the system default device (legend in the footer)
	local name = r.label or "?"
	if side == "left" then
		local label = U.ellipsize((r.default and "* " or "") .. name, w - 22)
		U.text(x + 8, y + 2, label, sel and C.white or col, sel and 230 or 170)
	else
		local label = U.ellipsize(name .. (r.default and " *" or ""), w - 22)
		U.text_r(x + w - 8, y + 2, label, sel and C.white or col, sel and 230 or 170)
	end
	local ny = y + rowH / 2 - 1
	if r.connected then
		U.circle(nodeX, ny, 4, C.turq, 230)
	else
		U.circle(nodeX, ny, 3, C.border, 180)
	end
	return nodeX, ny
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	if not s.graph then
		s.graph = (ctx.route and ctx.route.graph({ live = available(ctx), monitors = s.show_monitors }))
			or { sources = {}, sinks = {}, eng = {} }
	end
	local g = s.graph

	-- header right-text reflects WHY the graph is what it is
	local right = "PipeWire"
	if g.synthetic then
		right = (g.reason == "pwlink" and "needs PipeWire") or (g.reason == "engine" and "engine down") or "preview"
	end
	U.header(W, "ROUTING", right, C.turq)

	-- column geometry: [ SOURCES ][ RACK ][ SINKS ]
	local pad = 20
	local rackW = 92
	local gap = 14
	local colW = math.floor((W - pad * 2 - rackW - gap * 2) / 2)
	local leftX = pad
	local rackX = leftX + colW + gap
	local rightX = rackX + rackW + gap
	local topY = U.CONTENT_TOP + 18
	local botY = H + U.CONTENT_BOTTOM
	local rowH = 20

	U.text(leftX + 8, U.CONTENT_TOP, "SOURCES", C.dim, 150)
	U.text_r(rightX + colW - 8, U.CONTENT_TOP, "SINKS", C.dim, 150)

	-- the leading focus item (s.sel == 1): a monitors view toggle, drawn centered over
	-- the rack column so it's keyboard-reachable (sel toggles it; wet still works too).
	local mon_sel = (s.sel or 1) == 1
	U.text_c(
		rackX + rackW / 2,
		U.CONTENT_TOP,
		s.show_monitors and "[monitors ON]" or "[monitors OFF]",
		mon_sel and C.turq or C.dim,
		mon_sel and 235 or 140
	)

	local sources, sinks = g.sources or {}, g.sinks or {}
	local nrows = #sources + #sinks

	-- rack box (the fixed middle): shows the LOADED CHAIN as inner nodes (top->bottom =
	-- signal order) so a patch running live in the engine is visible right here in the
	-- flow. Stock effects read dim/white, synths violet, marketplace patches turquoise.
	local mt = ctx.dsp.meters() or {}
	local chain = {}
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded then
			chain[#chain + 1] = { i = i, sl = sl, lv = (mt.levels and mt.levels[i]) or 0 }
		end
	end
	local lv = 0
	for _, c in ipairs(chain) do
		lv = math.max(lv, c.lv)
	end
	local midY = math.floor((topY + botY) / 2)
	local nodeH = 13
	local rackH = math.min(math.max(60, #chain * nodeH + 26), math.max(60, botY - topY - 8))
	local rackY = midY - math.floor(rackH / 2)
	U.gradient_v(rackX, rackY, rackW, rackH, C.panel_hi, C.panel)
	U.tline(rackX, rackY, rackX + rackW, rackY, 1, C.turq, 140)
	U.tline(rackX, rackY + rackH, rackX + rackW, rackY + rackH, 1, C.turq, 80)
	U.text_c(rackX + rackW / 2, rackY + 4, "RACK", C.white, 220)
	local maxNodes = math.max(0, math.floor((rackH - 20) / nodeH))
	for k = 1, math.min(#chain, maxNodes) do
		local c, sl = chain[k], chain[k].sl
		local active = not sl.bypassed
		local accent = sl.is_patch and C.turq or (sl.kind == "synth" and C.violet or C.dim)
		local ny = rackY + 18 + (k - 1) * nodeH
		U.circle(
			rackX + 8,
			ny + 4,
			active and 3 or 2,
			active and accent or C.border,
			active and (140 + math.floor(c.lv * 110)) or 120
		)
		U.text(
			rackX + 16,
			ny,
			U.ellipsize(sl.name or "?", rackW - 18),
			active and (sl.is_patch and C.turq or C.white) or C.dim,
			active and 220 or 130
		)
	end
	if #chain > maxNodes then
		U.text_c(rackX + rackW / 2, rackY + rackH - 10, "+" .. (#chain - maxNodes) .. " more", C.dim, 140)
	elseif #chain == 0 then
		U.text_c(rackX + rackW / 2, midY, "(empty)", C.dim, 130)
	end
	local inX, inY = rackX, midY
	local outX, outY = rackX + rackW, midY
	U.circle(inX, inY, 4 + lv * 4, C.turq, 90 + math.floor(lv * 140))
	U.circle(inX, inY, 3, C.turq, 230)
	U.circle(outX, outY, 4 + lv * 4, C.turq, 90 + math.floor(lv * 140))
	U.circle(outX, outY, 3, C.turq, 230)
	U.text_c(rackX + rackW / 2, rackY - 12, "in     out", C.dim, 120)

	-- rows: sources fill the left column top-down, sinks the right column. The
	-- flat focus index `li` runs sources-then-sinks, matching items()/s.sel.
	local conns = {} -- {x, y, is_source} for each connected row, to draw lines after
	local li = 1 -- index 1 is the monitors toggle row; sources/sinks follow
	for ri, r in ipairs(sources) do
		li = li + 1
		local y = topY + (ri - 1) * (rowH + 4)
		if y + rowH <= botY then
			local nx, ny = draw_row(ctx, r, li == s.sel, leftX, y, colW, leftX + colW - 6, "left")
			if r.connected then
				conns[#conns + 1] = { nx, ny, true }
			end
		end
	end
	for ri, r in ipairs(sinks) do
		li = li + 1
		local y = topY + (ri - 1) * (rowH + 4)
		if y + rowH <= botY then
			local nx, ny = draw_row(ctx, r, li == s.sel, rightX, y, colW, rightX + 6, "right")
			if r.connected then
				conns[#conns + 1] = { nx, ny, false }
			end
		end
	end

	-- connection lines from each connected row's node to the matching rack port
	for _, nd in ipairs(conns) do
		if nd[3] then
			U.line(nd[1], nd[2], inX, inY, C.turq, 120)
		else
			U.line(outX, outY, nd[1], nd[2], C.turq, 120)
		end
	end

	if nrows == 0 then
		U.text_c(W / 2, midY + 50, "(no audio ports found)", C.dim, 150)
	end

	if g.synthetic then
		local msg = (g.reason == "pwlink" and "PREVIEW - needs PipeWire (pw-link)")
			or (g.reason == "engine" and "PREVIEW - the audio engine isn't running")
			or "PREVIEW - routing needs the desktop rig"
		U.text_c(W / 2, botY - 4, msg, C.dim, 150)
	end

	local hint
	if (s.sel or 1) == 1 then
		hint = "sel: " .. (s.show_monitors and "hide" or "show") .. " monitors   turn: rows   back: FX"
	else
		hint = "turn: pick   sel: link   * default   back: FX   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
