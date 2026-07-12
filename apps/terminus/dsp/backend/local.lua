-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/backend/local.lua — desktop backend over the embedded demodoom_core engine.

  Selected only when demod-ui is built with LOCAL_DSP=1 (dm.local_available()).
  Real audio, no orchestrator. Slots/params are 0-based in the C ABI; we present
  1-based slots to the GUI to match the orchestrator/stub backends.

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local function new(base)
	local MP = dofile(base .. "/mixer_params.lua")
	dm.local_init(48000, 256)
	local SLOT_COUNT = dm.local_slot_count()
	local master_gain = 1.0

	-- read param descriptors for a slot from the C side into a Lua table
	local function read_params(slot0)
		local _, _, _, _, np = dm.local_slot(slot0)
		local params = {}
		for i = 0, (np or 0) - 1 do
			local label, mn, mx, init, step, val = dm.local_param(slot0, i)
			params[i + 1] = {
				index = i,
				label = label,
				min = mn,
				max = mx,
				init = init,
				step = step,
				value = val,
				unit = (mn == 0 and mx == 1) and "%" or "",
			}
		end
		return params
	end

	-- build/refresh a slot view (1-based)
	local slots = {}
	local function refresh(i)
		local loaded, name, byp, wet = dm.local_slot(i - 1)
		local prev = slots[i]
		slots[i] = {
			loaded = loaded,
			name = (name ~= "" and name or ("SLOT " .. i)),
			kind = (prev and prev.kind) or "fx",
			bypassed = byp,
			wet = wet,
			dsp_path = name,
			params = read_params(i - 1),
			-- preserve the mixer shadow across a refresh (the C ABI doesn't report it)
			gain = (prev and prev.gain) or 1.0,
			pan = (prev and prev.pan) or 0.0,
			mute = (prev and prev.mute) or false,
			solo = (prev and prev.solo) or false,
		}
	end
	for i = 1, SLOT_COUNT do
		refresh(i)
	end

	local dsp = {}
	function dsp.backend_name()
		return "local"
	end
	function dsp.slot_count()
		return SLOT_COUNT
	end
	function dsp.slot(i)
		return slots[i]
	end
	function dsp.params(i)
		return slots[i] and slots[i].params or {}
	end

	function dsp.get_param(slot, idx)
		if MP.is_mix(idx) then -- mixer pseudo-param (gain/pan/mute/solo)
			return MP.read(slots[slot], idx)
		end
		local p = slots[slot] and slots[slot].params[idx + 1]
		return p and p.value or 0
	end
	function dsp.set_param(slot, idx, value)
		if MP.is_mix(idx) then -- write shadow; drive the engine only if the core exposes it
			local stored = MP.apply(slots[slot], idx, value)
			if idx == MP.GAIN and dm.local_set_slot_gain then
				dm.local_set_slot_gain(slot - 1, stored)
			elseif idx == MP.PAN and dm.local_set_slot_pan then
				dm.local_set_slot_pan(slot - 1, stored)
			end
			return
		end
		local p = slots[slot] and slots[slot].params[idx + 1]
		if not p then
			return
		end
		value = math.max(p.min, math.min(p.max, value))
		p.value = value
		dm.local_set_param(slot - 1, idx, value)
	end
	function dsp.set_bypass(slot, on)
		if slots[slot] then
			slots[slot].bypassed = on and true or false
			dm.local_set_bypass(slot - 1, on)
		end
	end
	function dsp.set_wet(slot, w)
		if slots[slot] then
			slots[slot].wet = math.max(0, math.min(1, w))
			dm.local_set_wet(slot - 1, slots[slot].wet)
		end
	end

	-- per-slot mixer controls — shadow-only unless the embedded core exposes setters
	-- (dm.local_set_slot_gain/pan); routed through set_param so moves are captured.
	function dsp.set_slot_gain(slot, g)
		dsp.set_param(slot, MP.GAIN, g)
	end
	function dsp.get_slot_gain(slot)
		return MP.read(slots[slot], MP.GAIN)
	end
	function dsp.set_slot_pan(slot, p)
		dsp.set_param(slot, MP.PAN, p)
	end
	function dsp.get_slot_pan(slot)
		return MP.read(slots[slot], MP.PAN)
	end
	function dsp.set_slot_mute(slot, on)
		dsp.set_param(slot, MP.MUTE, on and 1 or 0)
	end
	function dsp.get_slot_mute(slot)
		return MP.read(slots[slot], MP.MUTE) >= 0.5
	end
	function dsp.set_slot_solo(slot, on)
		dsp.set_param(slot, MP.SOLO, on and 1 or 0)
	end
	function dsp.get_slot_solo(slot)
		return MP.read(slots[slot], MP.SOLO) >= 0.5
	end
	function dsp.master_strip()
		return { gain = master_gain, pan = 0.0 }
	end

	function dsp.load_slot(slot, path)
		dm.local_load_slot(slot - 1, path or "")
		refresh(slot)
	end
	function dsp.unload_slot(slot)
		dm.local_unload_slot(slot - 1)
		refresh(slot)
	end
	-- patch as native plugin: demodoom_core compiles/loads the Faust source/.so
	function dsp.load_patch(slot, spec)
		dm.local_load_slot(slot - 1, spec.path or "")
		refresh(slot)
		if slots[slot] then
			slots[slot].kind = spec.kind or "fx"
			slots[slot].presets = spec.presets -- factory presets carried from the descriptor (optional)
			-- a marketplace patch carries patch_id; stock effects (also via load_patch) don't.
			slots[slot].is_patch = spec.patch_id ~= nil
			slots[slot].patch_id = spec.patch_id
		end
		return true
	end
	-- reflect a patch another process loaded (shadow only — no engine load). Best-effort
	-- on the embedded backend (Home's background load targets the orchestrator/demod-rt).
	function dsp.adopt_patch(slot, spec)
		local s = slots[slot]
		if not s then
			return false
		end
		s.loaded = true
		s.name = spec.name or "PATCH"
		s.kind = spec.kind or "fx"
		s.bypassed = spec.bypassed and true or false
		s.dsp_path = spec.path or s.dsp_path
		s.is_patch = spec.patch_id ~= nil
		s.patch_id = spec.patch_id
		if spec.params and #spec.params > 0 then
			local params = {}
			for j, pd in ipairs(spec.params) do
				params[j] = {
					index = j - 1,
					label = pd.label,
					min = pd.min,
					max = pd.max,
					init = pd.init,
					step = pd.step,
					value = (pd.value ~= nil) and pd.value or pd.init,
					unit = pd.unit,
				}
			end
			s.params = params
		end
		return true
	end
	function dsp.swap_slots(a, b)
		dm.local_swap(a - 1, b - 1)
		refresh(a)
		refresh(b)
	end

	function dsp.scope()
		local L, R, n = dm.local_scope(256)
		if not n or n == 0 then
			return nil
		end
		return { L = L, R = R, n = n }
	end
	function dsp.meters()
		local cpu, xruns = dm.local_meters()
		local mask = 0
		for i = 1, SLOT_COUNT do
			if slots[i].loaded and not slots[i].bypassed then
				mask = mask | (1 << (i - 1))
			end
		end
		return {
			pitch_hz = 0,
			midi_note = -1,
			bpm = 120,
			beat = 0,
			cpu = cpu or 0,
			xruns = xruns or 0,
			bypass_mask = mask,
		}
	end

	function dsp.transport(_) end
	function dsp.set_bpm(_) end
	function dsp.set_gain(g)
		master_gain = g -- shadow only (embedded core has no master gain op today)
	end
	-- note control via the gate/freq/level voice params (this embedded backend has no
	-- separate note API); mirrors scripts/demod-keyboard.py's fallback.
	local function mtof(n)
		return 440.0 * 2 ^ ((n - 69) / 12)
	end
	function dsp.note_on(slot, note, vel)
		dsp.set_param(slot, 1, mtof(note))
		dsp.set_param(slot, 2, (vel or 100) / 127)
		dsp.set_param(slot, 0, 1)
	end
	function dsp.note_off(slot)
		dsp.set_param(slot, 0, 0)
	end
	function dsp.all_notes_off(slot)
		dsp.set_param(slot, 0, 0)
	end
	function dsp.presets()
		return {}
	end
	function dsp.preset_save(_)
		return false
	end
	function dsp.preset_load(_)
		return false
	end
	function dsp.poll(_) end

	return dsp
end

return { new = new }
