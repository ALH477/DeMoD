-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/mixer.lua — the dedicated channel-strip mixer.

  One strip per LOADED slot (in chain order) + a pinned MASTER strip. Each strip:
  a live L/R meter with peak-hold, a gain fader (shown in dB), a pan indicator, and
  mute / solo toggles. Backend-agnostic — talks only to ctx.dsp + ctx.mixp helpers.

  Honest serial-vs-parallel semantics: the rack is a serial FX-insert chain with
  parallel synth sources summed in, so —
    · synth slots get the full strip (gain/pan/mute/solo, mute = drop the source),
    · FX-insert slots get gain/pan + a mute button that ALIASES TO BYPASS (a literal
      mute would kill everything downstream), and NO solo,
    · the master strip is gain only (set_gain).
  Gain/pan/mute/solo are negative-indexed pseudo-params (dsp/mixer_params.lua), so a
  fader move is bindable/automatable like any other param for free.

  Reflow: vertical channel strips on a wide panel; horizontal rows on a narrow guitar
  panel (vertical faders are unusable at 320px).

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "MIXER", short = "MIX" }

local function st(ctx)
	ctx.S.mix = ctx.S.mix or { sel = 1, ctrl = 1, editing = false, scroll = 1, peak = {}, accel = {} }
	return ctx.S.mix
end

-- the list of strips: every loaded slot, then MASTER (pinned last)
local function build_strips(ctx)
	local strips = {}
	for i = 1, ctx.dsp.slot_count() do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded then
			strips[#strips + 1] = { slot = i, synth = (sl.kind == "synth") }
		end
	end
	strips[#strips + 1] = { master = true }
	return strips
end

-- which controls a strip exposes, in focus order
local function controls(strip)
	if strip.master then
		return { "gain" }
	elseif strip.synth then
		return { "gain", "pan", "mute", "solo" }
	end
	return { "gain", "pan", "mute" } -- FX insert: mute aliases to bypass, no solo
end

-- ── value access (master gain vs per-slot pseudo-params) ──────────────────
local function get_gain(ctx, strip)
	if strip.master then
		return (ctx.dsp.master_strip and ctx.dsp.master_strip().gain) or 1.0
	end
	return ctx.dsp.get_slot_gain(strip.slot)
end

local function set_gain(ctx, strip, g)
	g = math.max(0, math.min(1.5, g))
	if strip.master then
		ctx.dsp.set_gain(g)
	else
		ctx.dsp.set_slot_gain(strip.slot, g)
	end
end

local function is_muted(ctx, strip)
	if strip.master or not strip.slot then
		return false
	end
	if strip.synth then
		return ctx.dsp.get_slot_mute(strip.slot)
	end
	return ctx.dsp.slot(strip.slot).bypassed -- FX insert: mute is bypass
end

local function toggle_mute(ctx, strip)
	if strip.master or not strip.slot then
		return
	end
	if strip.synth then
		ctx.dsp.set_slot_mute(strip.slot, not ctx.dsp.get_slot_mute(strip.slot))
	else
		ctx.dsp.set_bypass(strip.slot, not ctx.dsp.slot(strip.slot).bypassed)
	end
end

-- live post-fader level for a strip's meter (master = loudest active channel)
local function strip_level(ctx, m, strip)
	if strip.master then
		local mx = 0
		for _, v in ipairs(m.levels or {}) do
			if v > mx then
				mx = v
			end
		end
		return mx, mx
	end
	local i = strip.slot
	local l = (m.levels_l and m.levels_l[i]) or (m.levels and m.levels[i]) or 0
	local r = (m.levels_r and m.levels_r[i]) or (m.levels and m.levels[i]) or 0
	return l, r
end

local function db_str(ctx, g)
	local db = ctx.mixp.amp_to_db(g)
	if db == -math.huge then
		return "-INF"
	end
	return string.format("%+.1f", db) -- "dB" suffix drawn separately to save width
end

-- ── peak-hold (engine-independent; decays in the screen) ──────────────────
function M.update(ctx, dt)
	local s = st(ctx)
	local m = ctx.dsp.meters() or {}
	for _, strip in ipairs(build_strips(ctx)) do
		local key = strip.master and "M" or ("s" .. strip.slot)
		local l, r = strip_level(ctx, m, strip)
		local lv = math.max(l, r)
		local p = (s.peak[key] or 0) - dt * 0.6 -- ~0.6/s fall
		s.peak[key] = math.max(lv, p < 0 and 0 or p)
	end
	if ctx.S._playing ~= false then
		dm.redraw() -- meters animate → keep the overlay live
	end
end

-- ── input ─────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local s = st(ctx)
	local strips = build_strips(ctx)
	s.sel = math.max(1, math.min(#strips, s.sel))
	local strip = strips[s.sel]
	local cs = controls(strip)
	s.ctrl = math.max(1, math.min(#cs, s.ctrl))
	local ctrl = cs[s.ctrl]

	s.level = s.level or "strip" -- drill-in focus: "strip" -> "control" (-> "editing")

	-- secondary (X / hardware long-press): quick-mute the focused strip from any level.
	-- This is an accelerator ONLY — every action below is reachable with arrows/Enter/Esc,
	-- since the desktop keyboard has no "wet" key. tab/tab_prev are never intercepted, so
	-- they always switch screens (you're never trapped on the mixer).
	if action == "wet" then
		toggle_mute(ctx, strip)
		return true
	end

	if s.editing then -- value-adjust sub-mode (gain / pan)
		if action == "next" or action == "prev" then
			local dir = (action == "next") and 1 or -1
			local mult = ctx.U.accel(s.accel, dir, ctx.S.t or 0)
			if ctrl == "gain" then
				set_gain(ctx, strip, get_gain(ctx, strip) + dir * 0.02 * mult)
			elseif ctrl == "pan" then
				local p = ctx.dsp.get_slot_pan(strip.slot) + dir * 0.02 * mult
				ctx.dsp.set_slot_pan(strip.slot, math.max(-1, math.min(1, p)))
			end
			return true
		elseif action == "activate" or action == "back" then
			s.editing = false
			return true
		end
		return false
	end

	if s.level == "control" then -- drilled into a strip: pick + act on a control
		if action == "next" then
			s.ctrl = (s.ctrl % #cs) + 1
			return true
		elseif action == "prev" then
			s.ctrl = ((s.ctrl - 2) % #cs) + 1
			return true
		elseif action == "activate" then
			if ctrl == "gain" or ctrl == "pan" then
				s.editing = true
			elseif ctrl == "mute" then
				toggle_mute(ctx, strip)
			elseif ctrl == "solo" then
				ctx.dsp.set_slot_solo(strip.slot, not ctx.dsp.get_slot_solo(strip.slot))
			end
			return true
		elseif action == "back" then
			s.level = "strip" -- ascend back to channel select
			return true
		end
		return false -- tab/tab_prev/play_stop fall through to the global handler
	end

	-- strip level (default): pick a channel; Enter drills into its controls
	if action == "next" then
		s.sel = (s.sel % #strips) + 1
		s.ctrl = 1
		return true
	elseif action == "prev" then
		s.sel = ((s.sel - 2) % #strips) + 1
		s.ctrl = 1
		return true
	elseif action == "activate" then
		s.level, s.ctrl = "control", 1
		return true
	end
	return false -- back at strip level falls through → app leaves the screen
end

-- ── drawing ────────────────────────────────────────────────────────────────
local function meter_v(U, C, x, w, top, bot, lv, peak)
	local h = bot - top
	U.rect(x, top, w, h, C.panel, 150) -- track
	local fh = math.min(1, lv) * h
	local col = lv > 0.85 and C.red or (lv > 0.6 and C.yellow or C.green)
	if fh > 0 then
		U.rect(x, bot - fh, w, fh, col, 220)
	end
	if peak and peak > 0.01 then -- peak-hold tick
		local py = bot - math.min(1, peak) * h
		U.line(x, py, x + w, py, peak > 0.85 and C.red or C.white, 200)
	end
end

-- a vertical channel strip
local function draw_strip_v(ctx, strip, sx, sw, top, bot, sel, s, m)
	local U, C = ctx.U, ctx.C
	local cs = controls(strip)
	local accent = strip.master and C.turq
		or (strip.synth and C.violet or U.SLOT_COLORS[((strip.slot - 1) % #U.SLOT_COLORS) + 1])

	-- strip body + selection rail
	U.gradient_v(sx, top, sw, bot - top, C.panel_hi, C.panel)
	if sel then
		U.rect(sx, top, sw, bot - top, accent, 26)
		U.tline(sx, top, sx + sw, top, 2, accent, 200)
	end
	U.tline(sx, top, sx, bot, 2, accent, sel and 230 or 110)

	-- header: name + tag
	local sl = strip.slot and ctx.dsp.slot(strip.slot)
	local label = strip.master and "MASTER"
		or U.ellipsize(sl.name ~= "" and sl.name or ("SLOT " .. strip.slot), sw - 16)
	U.text(sx + 6, top + 5, label, sel and C.white or C.dim, sel and 255 or 170)
	if sl and sl.kind == "synth" then
		U.text(sx + 6, top + 19, "[SYN]", C.violet, 200)
	elseif sl and sl.is_patch then
		U.text(sx + 6, top + 19, "[PCH]", C.turq, 200)
	elseif not strip.master then
		U.text(sx + 6, top + 19, "[FX]", C.dim, 150)
	end

	-- vertical region for fader + meter
	local vtop = top + 36
	local vbot = bot - 50
	local faderX = sx + 12
	local faderW = 10
	-- fader track + unity (0 dB) tick + handle
	U.rect(faderX, vtop, faderW, vbot - vtop, C.panel, 180)
	local function focus(name)
		return sel and s.level == "control" and cs[s.ctrl] == name
	end
	local g = get_gain(ctx, strip)
	local fill = math.min(1, g / 1.5)
	local unityY = vbot - (1.0 / 1.5) * (vbot - vtop)
	U.line(faderX - 2, unityY, faderX + faderW + 2, unityY, C.border, 160)
	local hy = vbot - fill * (vbot - vtop)
	local gfocus = focus("gain")
	local editing_gain = gfocus and s.editing
	U.rect(faderX - 2, hy - 3, faderW + 4, 6, editing_gain and C.white or accent, gfocus and 255 or 150)
	if gfocus then
		U.tline(faderX - 4, vtop - 2, faderX - 4, vbot + 2, 2, accent, 220)
	end
	-- L/R meter to the right of the fader
	local l, r = strip_level(ctx, m, strip)
	local peak = s.peak[strip.master and "M" or ("s" .. strip.slot)]
	meter_v(U, C, sx + 34, 7, vtop, vbot, l, peak)
	meter_v(U, C, sx + 44, 7, vtop, vbot, r, peak)

	-- dB value under the fader
	U.text(sx + 6, vbot + 4, db_str(ctx, g) .. " dB", gfocus and C.white or C.dim, gfocus and 230 or 150)

	-- pan indicator (skipped on master for now — mono master)
	local py = vbot + 20
	if not strip.master then
		local pfocus = focus("pan")
		local p = ctx.dsp.get_slot_pan(strip.slot)
		local ptrackX, ptrackW = sx + 8, sw - 16
		U.line(ptrackX, py + 3, ptrackX + ptrackW, py + 3, C.border, 150)
		U.line(ptrackX + ptrackW / 2, py, ptrackX + ptrackW / 2, py + 6, C.border, 150) -- centre
		local dotX = ptrackX + (p + 1) / 2 * ptrackW
		U.circle(dotX, py + 3, 3, pfocus and (s.editing and C.white or C.turq) or accent, pfocus and 255 or 180)
		local ptxt = (math.abs(p) < 0.01) and "C"
			or (string.format("%s%d", p < 0 and "L" or "R", math.floor(math.abs(p) * 100)))
		U.text_r(sx + sw - 6, py - 1, ptxt, pfocus and C.white or C.dim, pfocus and 220 or 140)
	end

	-- M / S pills at the bottom
	local by = bot - 18
	if not strip.master then
		local muted = is_muted(ctx, strip)
		local mlbl = strip.synth and "M" or "B" -- FX insert: mute is bypass
		local mfocus = focus("mute")
		U.rect(sx + 8, by, 22, 14, muted and C.red or C.panel, muted and 70 or 120)
		U.text_c(sx + 19, by - 1, mlbl, muted and C.red or (mfocus and C.white or C.dim), mfocus and 255 or 180)
		if mfocus then
			U.tline(sx + 8, by + 14, sx + 30, by + 14, 2, accent, 220)
		end
		if strip.synth then
			local soloed = ctx.dsp.get_slot_solo(strip.slot)
			local sfocus = focus("solo")
			U.rect(sx + 36, by, 22, 14, soloed and C.yellow or C.panel, soloed and 70 or 120)
			U.text_c(sx + 47, by - 1, "S", soloed and C.yellow or (sfocus and C.white or C.dim), sfocus and 255 or 180)
			if sfocus then
				U.tline(sx + 36, by + 14, sx + 58, by + 14, 2, accent, 220)
			end
		end
	end
end

local function draw_vertical(ctx, W, H, strips, s, m)
	local top = ctx.U.CONTENT_TOP
	local bot = H - 50
	local x0 = 20
	local sw = 84
	local count = math.max(1, math.floor((W - 2 * x0) / sw))
	-- keep the selection in view
	if s.sel < s.scroll then
		s.scroll = s.sel
	elseif s.sel > s.scroll + count - 1 then
		s.scroll = s.sel - count + 1
	end
	s.scroll = math.max(1, math.min(s.scroll, math.max(1, #strips - count + 1)))
	for col = 0, count - 1 do
		local idx = s.scroll + col
		local strip = strips[idx]
		if strip then
			draw_strip_v(ctx, strip, x0 + col * sw + 2, sw - 6, top, bot, idx == s.sel, s, m)
		end
	end
	if #strips > count then
		ctx.U.text_r(
			W - 20,
			top - 16,
			string.format("%d-%d/%d", s.scroll, s.scroll + count - 1, #strips),
			ctx.C.dim,
			140
		)
	end
end

-- a horizontal strip row (narrow guitar panel)
local function draw_strip_h(ctx, strip, y, rowH, W, sel, s, m)
	local U, C = ctx.U, ctx.C
	local cs = controls(strip)
	local accent = strip.master and C.turq
		or (strip.synth and C.violet or U.SLOT_COLORS[((strip.slot - 1) % #U.SLOT_COLORS) + 1])
	local x0 = 20
	local rowW = W - 2 * x0
	local cy = y + rowH / 2
	U.gradient_v(x0, y + 2, rowW, rowH - 4, C.panel_hi, C.panel)
	if sel then
		U.rect(x0, y + 2, rowW, rowH - 4, accent, 26)
	end
	U.tline(x0, y + 2, x0, y + rowH - 2, 3, accent, sel and 230 or 120)
	local function focus(name)
		return sel and s.level == "control" and cs[s.ctrl] == name
	end

	-- name
	local sl = strip.slot and ctx.dsp.slot(strip.slot)
	local label = strip.master and "MASTER" or U.ellipsize(sl.name ~= "" and sl.name or ("SLOT " .. strip.slot), 80)
	U.text(x0 + 8, cy - 8, label, sel and C.white or C.dim, sel and 255 or 170)

	-- gain bar + dB (mid)
	local g = get_gain(ctx, strip)
	local gx, gw = x0 + 110, math.max(40, rowW * 0.28)
	local gfocus = focus("gain")
	U.rect(gx, cy - 3, gw, 6, C.border, 150)
	U.rect(
		gx,
		cy - 3,
		gw * math.min(1, g / 1.5),
		6,
		gfocus and (s.editing and C.white or accent) or accent,
		gfocus and 255 or 160
	)
	U.line(gx + gw * (1.0 / 1.5), cy - 6, gx + gw * (1.0 / 1.5), cy + 4, C.border, 160) -- unity tick
	U.text(gx, cy + 6, db_str(ctx, g) .. "dB", gfocus and C.white or C.dim, gfocus and 220 or 140)

	-- meter (thin, above the gain bar)
	local l, r = strip_level(ctx, m, strip)
	local lv = math.max(l, r)
	local mcol = lv > 0.85 and C.red or (lv > 0.6 and C.yellow or C.green)
	U.rect(gx, cy - 11, gw, 3, C.panel, 150)
	U.rect(gx, cy - 11, gw * math.min(1, lv), 3, mcol, 200)

	-- pan + M/S at the right
	local rx = x0 + rowW - 96
	if not strip.master then
		local pfocus = focus("pan")
		local p = ctx.dsp.get_slot_pan(strip.slot)
		local ptxt = (math.abs(p) < 0.01) and "C"
			or string.format("%s%d", p < 0 and "L" or "R", math.floor(math.abs(p) * 100))
		U.text(rx, cy - 8, "pan " .. ptxt, pfocus and C.white or C.dim, pfocus and 230 or 150)

		local muted = is_muted(ctx, strip)
		local mlbl = strip.synth and "M" or "B"
		local mfocus = focus("mute")
		U.rect(rx + 56, cy - 8, 16, 16, muted and C.red or C.panel, muted and 70 or 120)
		U.text_c(rx + 64, cy - 8, mlbl, muted and C.red or (mfocus and C.white or C.dim), mfocus and 255 or 180)
		if strip.synth then
			local soloed = ctx.dsp.get_slot_solo(strip.slot)
			local sfocus = focus("solo")
			U.rect(rx + 76, cy - 8, 16, 16, soloed and C.yellow or C.panel, soloed and 70 or 120)
			U.text_c(rx + 84, cy - 8, "S", soloed and C.yellow or (sfocus and C.white or C.dim), sfocus and 255 or 180)
		end
	end
end

local function draw_horizontal(ctx, W, H, strips, s, m)
	local top = ctx.U.CONTENT_TOP
	local bot = H - 50
	local rowH = math.max(34, math.min(48, (bot - top) / math.max(#strips, 1)))
	local count = math.max(1, math.floor((bot - top) / rowH))
	if s.sel < s.scroll then
		s.scroll = s.sel
	elseif s.sel > s.scroll + count - 1 then
		s.scroll = s.sel - count + 1
	end
	s.scroll = math.max(1, math.min(s.scroll, math.max(1, #strips - count + 1)))
	for row = 0, count - 1 do
		local idx = s.scroll + row
		local strip = strips[idx]
		if strip then
			draw_strip_h(ctx, strip, top + row * rowH, rowH, W, idx == s.sel, s, m)
		end
	end
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local m = ctx.dsp.meters() or {}
	local strips = build_strips(ctx)
	s.sel = math.max(1, math.min(#strips, s.sel))

	local narrow = W < 380
	U.text(20, U.HEADER_Y, "MIXER", C.turq, 220)
	local chans = #strips - 1
	U.text_r(W - 20, U.HEADER_Y, string.format("%d CH   CPU %d%%", chans, math.floor(m.cpu or 0)), C.dim, 160)
	U.line(20, 74, W - 20, 74, C.border, 140)

	if narrow then
		draw_horizontal(ctx, W, H, strips, s, m)
	else
		draw_vertical(ctx, W, H, strips, s, m)
	end

	local strip = strips[s.sel]
	local ctrl = controls(strip)[s.ctrl] or "gain"
	local hint
	if s.editing then
		hint = "turn: " .. ctrl .. "   sel/back: done"
	elseif s.level == "control" then
		hint = "turn: control   sel: "
			.. ((ctrl == "mute" or ctrl == "solo") and "toggle" or "edit")
			.. "   back: channels   tab: screen"
	else
		hint = "turn: channel   sel: open   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
