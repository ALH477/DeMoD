-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/scenes.lua — SCENES: snapshot the whole rack, then morph between two.

  A scene captures the current value of every control-surface target. Pick an A and a B
  scene and sweep POSITION (or assign a DRIVER CC) to crossfade the entire rack live —
  each interpolated param writes through the control surface, so morphing also emits MIDI
  out. State lives in ctx.modulation; persisted via ctx.save_bindings.
  © 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "SCENES", short = "SCN" }

local function stt(ctx)
	ctx.S.scn = ctx.S.scn or { sel = 1 }
	return ctx.S.scn
end

-- cycle a scene name slot (nil -> first -> ... -> last -> nil)
local function cycle_scene(names, cur, dir)
	local list = { false }
	for _, n in ipairs(names) do
		list[#list + 1] = n
	end
	local idx = 1
	for i, v in ipairs(list) do
		if v == cur then
			idx = i
			break
		end
	end
	local v = list[((idx - 1 + dir) % #list) + 1]
	return v or nil
end

local function cycle_in(list, cur, dir)
	local idx = 1
	for i, v in ipairs(list) do
		if v == cur then
			idx = i
			break
		end
	end
	return list[((idx - 1 + dir) % #list) + 1]
end

local function rows(MOD)
	local r = {
		{ kind = "a" },
		{ kind = "b" },
		{ kind = "pos" },
		{ kind = "driver" },
		{ kind = "perf" },
		{ kind = "seq" },
		{ kind = "seqdiv" },
	}
	for _, name in ipairs(MOD.scenes()) do
		r[#r + 1] = { kind = "scene", name = name }
	end
	r[#r + 1] = { kind = "capture" }
	return r
end

-- ── nav ──────────────────────────────────────────────────────────────────────
function M.nav(ctx, action)
	local MOD = ctx.modulation
	if not MOD then
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
	local rr = rows(MOD)
	s.sel = math.max(1, math.min(s.sel or 1, #rr))
	local row = rr[s.sel]
	local names = MOD.scenes()
	local mph = MOD.morph()

	if action == "next" or action == "prev" then
		s.armed = false -- moving the cursor cancels a pending delete
		local dir = action == "next" and 1 or -1
		if s.adjust and row.kind == "pos" then
			MOD.morph_set_pos(math.max(0, math.min(1, (mph.pos or 0) + dir * 0.05)))
		elseif s.adjust and row.kind == "a" then
			MOD.set_morph(cycle_scene(names, mph.a, dir), mph.b)
		elseif s.adjust and row.kind == "b" then
			MOD.set_morph(mph.a, cycle_scene(names, mph.b, dir))
		elseif s.adjust and row.kind == "seqdiv" then
			MOD.seq_set_div(cycle_in(MOD.DIVS, MOD.seq().div, dir))
		else
			s.sel = math.max(1, math.min(s.sel + dir, #rr))
		end
	elseif action == "activate" then
		if s.armed and row.kind == "scene" then -- confirm a pending delete
			MOD.scene_remove(row.name)
			save()
			s.armed = false
			ctx.toast("Deleted " .. row.name, "warn")
			return true
		end
		if row.kind == "a" or row.kind == "b" or row.kind == "pos" or row.kind == "seqdiv" then
			s.adjust = not s.adjust
			if not s.adjust then
				save()
			end
		elseif row.kind == "seq" then
			local on = MOD.seq_toggle()
			save()
			ctx.toast(on and "Scene sequencer ON (tempo-synced)" or "Scene sequencer OFF", "info")
		elseif row.kind == "driver" then
			MOD.begin_assign_morph()
			s.learning_driver = true
			ctx.toast("Morph driver: twist a CC", "info")
		elseif row.kind == "perf" then
			MOD.set_perf(MOD.is_perf("morph") and nil or "morph")
			save()
			ctx.toast(MOD.is_perf("morph") and "Perf: gamepad/encoder sweeps the morph" or "Perf cleared", "info")
		elseif row.kind == "scene" then
			MOD.scene_capture(row.name) -- re-capture the current rack into this scene
			save()
			ctx.toast(row.name .. " updated", "ok")
		elseif row.kind == "capture" then
			MOD.scene_capture("Scene " .. (MOD.scene_count() + 1))
			save()
			ctx.toast("Scene captured", "ok")
		end
	elseif action == "wet" and row.kind == "scene" then -- accelerator: arm/disarm delete
		s.armed = not s.armed
	elseif action == "back" then
		if s.armed then -- cancel a pending delete
			s.armed = false
		elseif row.kind == "scene" then -- arm delete (keyboard-reachable; activate confirms)
			s.armed = true
		elseif s.adjust then
			s.adjust = false
			save()
		else
			return false -- leave the screen (tab also always switches screens)
		end
	end
	return true
end

-- ── draw ─────────────────────────────────────────────────────────────────────
function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local MOD = ctx.modulation
	U.text(20, U.HEADER_Y, "SCENES", C.turq, 220)
	if not MOD then
		U.text_c(W / 2, H / 2, "scenes unavailable", C.dim, 170)
		U.footer(W, H, "unavailable")
		return
	end
	local s = stt(ctx)

	if s.learning_driver and not MOD.is_assigning_morph() then
		if ctx.save_bindings then
			ctx.save_bindings()
		end
		ctx.toast("Morph driver assigned", "ok")
		s.learning_driver = nil
	end

	U.text_r(W - 20, U.HEADER_Y, "snapshot + crossfade the rack", C.dim, 150)
	U.line(20, 74, W - 20, 74, C.border, 140)
	local mph = MOD.morph()
	local y0 = U.CONTENT_TOP + 6
	local rowH = 24
	local rr = rows(MOD)
	s.sel = math.max(1, math.min(s.sel or 1, #rr))

	for i, row in ipairs(rr) do
		local sel = i == s.sel
		local y = y0 + (i - 1) * rowH
		local adj = sel
			and s.adjust
			and (row.kind == "a" or row.kind == "b" or row.kind == "pos" or row.kind == "seqdiv")
		local armed = sel and s.armed and row.kind == "scene"
		if sel then
			U.rect(
				20,
				y,
				W - 40,
				rowH - 4,
				armed and C.red or (adj and C.violet or C.turq),
				armed and 55 or (adj and 50 or 32)
			)
			U.tline(20, y, 20, y + rowH - 4, 3, armed and C.red or C.turq, 255)
		end
		if row.kind == "a" then
			U.text(36, y + 4, "Morph A", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(W - 36, y + 4, mph.a or "(none)", sel and C.white or C.green, sel and 235 or 175)
		elseif row.kind == "b" then
			U.text(36, y + 4, "Morph B", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(W - 36, y + 4, mph.b or "(none)", sel and C.white or C.green, sel and 235 or 175)
		elseif row.kind == "pos" then
			U.text(36, y + 4, "Position", sel and C.white or C.dim, sel and 235 or 170)
			U.rect(W - 180, y + 7, 140, 6, C.border, 90)
			U.rect(W - 180, y + 7, math.floor(140 * (mph.pos or 0)), 6, C.violet, 210)
		elseif row.kind == "driver" then
			local d = mph.driver
			local tag = s.learning_driver and "LEARN..."
				or (d and ((d.source == "foot" and "FS" or "CC") .. tostring(d.code)) or "none")
			U.text(36, y + 4, "Driver", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(W - 36, y + 4, tag, sel and C.white or C.green, sel and 235 or 175)
		elseif row.kind == "perf" then
			U.text(36, y + 4, "Perf (gamepad)", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(
				W - 36,
				y + 4,
				MOD.is_perf("morph") and "ON" or "OFF",
				sel and C.white or C.green,
				sel and 235 or 175
			)
		elseif row.kind == "seq" then
			U.text(36, y + 4, "Sequencer", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(
				W - 36,
				y + 4,
				MOD.seq().on and "PLAYING" or "OFF",
				MOD.seq().on and C.turq or C.dim,
				sel and 235 or 175
			)
		elseif row.kind == "seqdiv" then
			U.text(36, y + 4, "Seq Rate", sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(W - 36, y + 4, MOD.seq().div .. " / scene", sel and C.white or C.green, sel and 235 or 175)
		elseif row.kind == "scene" then
			local mark = (mph.a == row.name and "A" or "") .. (mph.b == row.name and "B" or "")
			U.text(36, y + 4, U.ellipsize(row.name, math.floor(W * 0.5)), sel and C.white or C.dim, sel and 235 or 170)
			U.text_r(W - 36, y + 4, mark ~= "" and ("[" .. mark .. "]") or "scene", mark ~= "" and C.turq or C.dim, 175)
		elseif row.kind == "capture" then
			U.text(36, y + 4, "[ + capture scene ]", sel and C.turq or C.dim, sel and 235 or 150)
		end
	end
	local cur = rr[s.sel]
	local hint
	if s.armed and cur and cur.kind == "scene" then
		hint = "DELETE " .. cur.name .. " ?   sel: confirm   back: cancel"
	elseif cur and cur.kind == "scene" then
		hint = "turn: row   sel: re-capture   back: delete   tab: screen"
	else
		hint = "turn: row/value   sel: adjust/capture   back: out   tab: screen"
	end
	U.footer(W, H, hint)
end

return M
