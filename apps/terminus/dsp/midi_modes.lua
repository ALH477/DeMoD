-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/midi_modes.lua — Multi-mode MIDI Player with independent settings.

  Modes:
    - direct     : External USB MIDI controller input
    - mirrored   : 1:1 echo of detected notes
    - secondary  : Polyphonic secondary player (default)

  All three can be active simultaneously. Uses shared voice allocator with
  least-latency allocation.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local input = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") .. "midi_input.lua")

local M = {}
M.input = input -- exposed so the host can push external "direct" events into our queue

local voices = {} -- shared voice pool
local next_voice_id = 1
local max_voices = 8

local function alloc_voice(note, vel, source)
	-- Least latency allocation: first free or steal oldest
	for i, v in ipairs(voices) do
		if not v.active then
			v.note = note
			v.vel = vel
			v.source = source
			v.active = true
			return v
		end
	end

	if #voices < max_voices then
		local v = { id = next_voice_id, note = note, vel = vel, source = source, active = true }
		next_voice_id = next_voice_id + 1
		table.insert(voices, v)
		return v
	end

	-- steal oldest
	table.sort(voices, function(a, b)
		return (a.t or 0) < (b.t or 0)
	end)
	local victim = voices[1]
	victim.note = note
	victim.vel = vel
	victim.source = source
	victim.active = true
	return victim
end

-- the first loaded instrument (synth-kind) slot — MIDI drives synths, not FX
local function first_synth_slot(ctx)
	local n = ctx.dsp.slot_count and ctx.dsp.slot_count() or 0
	for i = 1, n do
		local sl = ctx.dsp.slot(i)
		if sl and sl.loaded and sl.kind == "synth" then
			return i
		end
	end
	return nil
end

function M.process_events(ctx, events)
	local slot = first_synth_slot(ctx)
	if not slot then
		return -- nothing to play: no instrument loaded
	end
	for _, ev in ipairs(events) do
		if ev.type == "note_on" then
			local v = alloc_voice(ev.note, ev.vel or 0.8, ev.src)
			if v then
				v.slot = slot
				-- common Faust synth param layout: 0=gate, 1=freq, 2=level
				ctx.dsp.set_param(slot, 0, 1)
				ctx.dsp.set_param(slot, 1, 440 * 2 ^ ((ev.note - 69) / 12))
				ctx.dsp.set_param(slot, 2, v.vel)
				v.t = ctx.S and ctx.S.t or 0
			end
		elseif ev.type == "note_off" then
			for _, v in ipairs(voices) do
				if v.note == ev.note and v.active then
					ctx.dsp.set_param(v.slot or slot, 0, 0)
					v.active = false
				end
			end
		end
	end
end

function M.update(ctx)
	local cfg = ctx.CFG or {}
	if not cfg.midi_enabled then
		return
	end

	-- Feed detection events from meters
	local m = ctx.dsp.meters and ctx.dsp.meters() or {}
	if m.midi_note and m.midi_note >= 0 then
		input.push_event("detection", {
			type = "note_on",
			note = m.midi_note,
			vel = (cfg.midi_velocity == "confidence") and (m.pitch_conf or 0.8) or 0.9,
		})
	end

	local evs = input.poll()

	-- Dispatch to active modes
	for _, ev in ipairs(evs) do
		if ev.src == "direct" and cfg.midi_direct then
			M.process_events(ctx, { ev })
		elseif ev.src == "detection" then
			if cfg.midi_mirrored then
				M.process_events(ctx, { ev })
			end
			if cfg.midi_secondary then
				M.process_events(ctx, { ev })
			end
		elseif ev.src == "secondary" then
			-- Duck Dance / file player events: always process if secondary enabled
			if cfg.midi_secondary then
				M.process_events(ctx, { ev })
			end
		end
	end
end

return M
