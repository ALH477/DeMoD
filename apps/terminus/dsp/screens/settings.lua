-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/screens/settings.lua — backend info, transport/BPM/gain, and presets.
  Presets are backend-driven (dsp.presets / preset_save / preset_load).
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = { name = "SETTINGS", short = "SET" }

local function st(ctx)
	ctx.S.set = ctx.S.set or { sel = 1 }
	return ctx.S.set
end

-- rows are { label, get(ctx)->string, act(ctx, dir) }
local function rows(ctx)
	local d = ctx.dsp
	-- row[6] = adjustable value (turn to adjust in edit mode); rows without it fire on activate.
	local is_stub = (d.backend_name and d.backend_name() or "stub") == "stub"
	return {
		{
			"BACKEND",
			function()
				return (d.backend_name and d.backend_name() or "unknown"):upper()
			end,
			function() end,
			true, -- read-only (row[4])
			"audio engine (read-only)", -- description (row[5])
		},
		{
			"TRANSPORT",
			function()
				if not is_stub then
					return "AUTO"
				end
				return ctx.S._playing and "PLAYING" or "STOPPED"
			end,
			function()
				-- Only the stub honours UI transport; the orchestrator owns its own.
				if not is_stub then
					if ctx.toast then
						ctx.toast("Transport is managed by the orchestrator", "info")
					end
					return
				end
				ctx.S._playing = not ctx.S._playing
				d.transport(ctx.S._playing)
			end,
			not is_stub, -- read-only off the stub backend (was a dead toggle)
			not is_stub and "transport managed by the orchestrator" or nil,
		},
		{
			"BPM",
			function()
				return string.format("%.0f", ctx.S._bpm or 120)
			end,
			function(c, dir)
				ctx.S._bpm = math.max(40, math.min(240, (ctx.S._bpm or 120) + dir * 1))
				d.set_bpm(ctx.S._bpm)
			end,
			false,
			nil,
			true, -- adjustable
		},
		{
			"MASTER GAIN",
			function()
				return string.format("%.2f", ctx.S._gain or 0.8)
			end,
			function(c, dir)
				ctx.S._gain = math.max(0, math.min(1.5, (ctx.S._gain or 0.8) + dir * 0.02))
				d.set_gain(ctx.S._gain)
			end,
			false,
			nil,
			true, -- adjustable
		},
		{
			"PRESET",
			function()
				local p = d.presets()
				return p[ctx.S._preset or 1] or "-"
			end,
			function(c, dir)
				local p = d.presets()
				if #p == 0 then
					return
				end
				ctx.S._preset = (((ctx.S._preset or 1) - 1 + dir) % #p) + 1
			end,
			false,
			nil,
			true, -- adjustable
		},
		{
			"SAVE PRESET",
			function()
				return ">"
			end,
			function()
				if ctx.keyboard then
					ctx.keyboard("PRESET NAME", function(name)
						-- validate: alnum + _ - only (no path separators / traversal)
						if not (name and name:match("^[A-Za-z0-9_-]+$")) then
							if ctx.toast then
								ctx.toast("Invalid name (A-Z 0-9 _ - only)", "err")
							end
							return
						end
						local ok = ctx.dsp.preset_save(name)
						if ctx.toast then
							ctx.toast(ok and ("Saved " .. name) or "Save failed", ok and "ok" or "err")
						end
					end)
				end
			end,
		},
		{
			"LOAD PRESET",
			function()
				return ">"
			end,
			function()
				local p = ctx.dsp.presets()
				local n = p[ctx.S._preset or 1]
				if n then
					local ok = ctx.dsp.preset_load(n)
					if ctx.toast then
						ctx.toast(ok and ("Loaded " .. n) or ("Load failed: " .. n), ok and "ok" or "err")
					end
				end
			end,
		},
		{
			"MIDI SYNTH",
			function()
				return (ctx.CFG and ctx.CFG.midi_enabled) and "ON" or "OFF"
			end,
			-- drives notes (detected pitch / USB MIDI) into a loaded SYNTH slot
			function()
				local cfg = ctx.CFG or {}
				ctx.CFG = cfg
				local on = not cfg.midi_enabled
				cfg.midi_enabled = on
				cfg.midi_secondary = on -- route detection-driven notes
				if ctx.toast then
					ctx.toast(on and "MIDI synth ON - load a SYNTH slot" or "MIDI synth OFF", on and "ok" or "info")
				end
			end,
			false,
			"plays detected pitch / MIDI into a loaded SYNTH slot",
		},
		{
			"PANIC (NOTES OFF)",
			function()
				return ">"
			end,
			-- silence any stuck synth note (gate left on) across every slot
			function()
				if d.all_notes_off then
					for i = 1, (d.slot_count and d.slot_count() or 0) do
						d.all_notes_off(i)
					end
					if ctx.toast then
						ctx.toast("All notes off", "ok")
					end
				end
			end,
			false,
			"silence any stuck synth notes",
		},
		{
			"HELP / CONTROLS",
			function()
				return ">"
			end,
			function()
				if ctx.help then
					ctx.help()
				end
			end,
			false,
			"how to navigate DSP Studio",
		},
	}
end

function M.nav(ctx, action)
	local s = st(ctx)
	local r = rows(ctx)
	local row = r[s.sel]
	-- Edit sub-mode: turning adjusts the value ±, sel/back exits (mirrors fx_chain WET).
	-- This is what gives value rows (BPM/GAIN/PRESET) a *decrement* — turning back used
	-- to only move the selection, so values could never go down.
	if s.editing then
		if action == "next" then
			row[3](ctx, 1)
		elseif action == "prev" then
			row[3](ctx, -1)
		elseif action == "activate" or action == "back" then
			s.editing = false
		end
		return true -- swallow back too, so it exits edit rather than the screen
	end
	if action == "next" then
		s.sel = (s.sel % #r) + 1
		return true
	elseif action == "prev" then
		s.sel = ((s.sel - 2) % #r) + 1
		return true
	elseif action == "activate" then
		if row[6] then
			s.editing = true -- enter value edit (turn to adjust)
		else
			row[3](ctx, 1) -- toggle / fire action row
		end
		return true
	elseif action == "adjust_dec" then -- honour a host that emits it directly
		row[3](ctx, -1)
		return true
	end
	return false
end

function M.draw(ctx, W, H)
	local U, C = ctx.U, ctx.C
	local s = st(ctx)
	local r = rows(ctx)
	U.header(W, "SETTINGS")
	local y0 = U.CONTENT_TOP
	local rowH = math.max(26, math.min(38, (H - y0 - 52) / #r))
	for i, row in ipairs(r) do
		local y = y0 + (i - 1) * rowH
		local sel = (i == s.sel)
		local readonly = row[4]
		local editing = s.editing and sel
		if sel then
			U.gradient_v(20, y, W - 40, rowH - 6, C.panel_hi, C.panel)
			U.tline(20, y, 20, y + rowH - 6, 3, editing and C.violet or (readonly and C.border or C.turq), 255)
		end
		U.text(36, y + (rowH - 6) / 2 - 8, row[1], sel and C.white or C.dim, sel and 255 or 180)
		-- read-only rows render their value dim (no accent) so they don't look editable;
		-- the row being edited brackets its value and accents it so the mode is obvious.
		local vcol = readonly and C.dim or (editing and C.violet or (sel and C.turq or C.dim))
		local vtxt = tostring(row[2](ctx))
		if editing then
			vtxt = "[ " .. vtxt .. " ]"
		end
		U.text_r(W - 44, y + (rowH - 6) / 2 - 8, vtxt, vcol, editing and 255 or 220)
	end
	-- footer: selected row's description + the nav hint (mode-aware)
	local cur = r[s.sel]
	local desc = cur and cur[5]
	local hint = s.editing and "turn: adjust   sel/back: done"
		or (cur and cur[6] and "turn: select   sel: edit" or "turn: select   sel: change")
	U.footer(W, H, (desc and (desc .. "    ") or "") .. hint)
end

return M
