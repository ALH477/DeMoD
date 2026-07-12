-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/backend/stub.lua — in-memory reference implementation of the `dsp` contract.

  Used on a desktop with no orchestrator and no local audio engine: it lets the
  whole GUI run and be developed/tested. The orchestrator and local backends
  implement this exact same table shape.

    dsp.backend_name()                 -> string
    dsp.slot_count()                   -> int
    dsp.slot(i)   -> { loaded, name, bypassed, wet, dsp_path, nparams } | nil
    dsp.params(i) -> { {index,label,min,max,init,step,value,unit}, ... }
    dsp.get_param(slot, idx) / dsp.set_param(slot, idx, value)
    dsp.set_bypass(slot, on) / dsp.set_wet(slot, w)
    dsp.set_slot_gain/get_slot_gain, dsp.set_slot_pan/get_slot_pan,
    dsp.set_slot_mute/get_slot_mute, dsp.set_slot_solo/get_slot_solo, dsp.master_strip()
                                       -- per-slot mixer controls (negative pseudo-params;
                                       -- see dsp/mixer_params.lua) — bindable/automatable
    dsp.load_slot(slot, path) / dsp.unload_slot(slot) / dsp.swap_slots(a,b)
    dsp.load_patch(slot, spec)         -- load a Faust synth/fx patch into a slot
                                       -- spec = { name, path, kind, params={{label,min,max,init,step,unit}..} }
    dsp.scope()   -> {L={..},R={..},n=..} | nil
    dsp.meters()  -> { pitch_hz, midi_note, bpm, beat, cpu, xruns, bypass_mask }
    dsp.transport(playing:bool) / dsp.set_bpm(b) / dsp.set_gain(g)
    dsp.note_on(slot, note, vel) / dsp.note_off(slot, note) / dsp.all_notes_off(slot)
                                       -- play a synth slot (real MIDI ops on the
                                       -- orchestrator; gate/freq fallback elsewhere)
    dsp.presets() -> { names }
    dsp.preset_save(name) / dsp.preset_load(name)
    dsp.poll(dt)  -> refresh cached state (called once per frame)

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local SLOT_COUNT = 12

local function P(index, label, min, max, init, step, unit)
	return {
		index = index,
		label = label,
		min = min,
		max = max,
		init = init,
		step = step,
		value = init,
		unit = unit or "",
	}
end

-- POSIX shell single-quote (preset dir may come from env). SECURITY.md F-7.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- stock effects mirroring demod5 dsp/effects/*.dsp (used until a real backend reports real ones)
local function make_slots()
	local s = {}
	for i = 1, SLOT_COUNT do
		s[i] = { loaded = false, name = "", bypassed = true, wet = 1.0, dsp_path = "", params = {} }
	end
	s[1] = {
		loaded = true,
		name = "OVERDRIVE",
		bypassed = false,
		wet = 1.0,
		dsp_path = "overdrive.dsp",
		params = {
			P(0, "DRIVE", 1, 20, 5, 0.1, "x"),
			P(1, "TONE", 0, 1, 0.5, 0.01, "%"),
			P(2, "OUTPUT", 0, 1, 0.5, 0.01, "%"),
			P(3, "MIX", 0, 1, 1, 0.01, "%"),
		},
	}
	s[2] = {
		loaded = true,
		name = "CHORUS",
		bypassed = false,
		wet = 0.35,
		dsp_path = "chorus.dsp",
		params = {
			P(0, "RATE", 0.1, 8, 1.2, 0.01, "Hz"),
			P(1, "DEPTH", 0, 1, 0.5, 0.01, "%"),
			P(2, "MIX", 0, 1, 0.35, 0.01, "%"),
			P(3, "SPREAD", 0, 1, 0.6, 0.01, "%"),
		},
	}
	s[3] = {
		loaded = true,
		name = "DELAY",
		bypassed = true,
		wet = 0.3,
		dsp_path = "delay.dsp",
		params = {
			P(0, "TIME", 10, 1200, 420, 1, "ms"),
			P(1, "FEEDBACK", 0, 1, 0.4, 0.01, "%"),
			P(2, "MIX", 0, 1, 0.3, 0.01, "%"),
			P(3, "HICUT", 500, 12000, 6000, 10, "Hz"),
		},
	}
	s[4] = {
		loaded = true,
		name = "REVERB",
		bypassed = false,
		wet = 0.25,
		dsp_path = "reverb.dsp",
		params = {
			P(0, "SIZE", 0, 1, 0.55, 0.01, "%"),
			P(1, "DAMP", 0, 1, 0.4, 0.01, "%"),
			P(2, "MIX", 0, 1, 0.25, 0.01, "%"),
			P(3, "PREDELAY", 0, 200, 15, 1, "ms"),
		},
	}
	s[5] = {
		loaded = true,
		name = "COMPRESS",
		bypassed = true,
		wet = 1.0,
		dsp_path = "compress.dsp",
		params = {
			P(0, "THRESH", -48, 0, -18, 0.5, "dB"),
			P(1, "RATIO", 1, 20, 4, 0.1, "x"),
			P(2, "ATTACK", 0.1, 100, 12, 0.1, "ms"),
			P(3, "MAKEUP", 0, 24, 4, 0.1, "dB"),
		},
	}
	for i = 1, SLOT_COUNT do
		s[i].kind = s[i].kind or "fx"
		-- per-slot mixer controls (see dsp/mixer_params.lua)
		s[i].gain = 1.0
		s[i].pan = 0.0
		s[i].mute = false
		s[i].solo = false
	end
	return s
end

local function new(base)
	-- default for callers/tests that construct the stub without the app dir
	local MP = dofile((base or "dsp") .. "/mixer_params.lua")
	local preset_dir = function()
		local d = os.getenv("DEMOD_PRESET_DIR")
		if d and #d > 0 then
			return d
		end
		local h = os.getenv("HOME") or "/tmp"
		return h .. "/.local/share/demod/stub-presets"
	end

	local function load_preset_list()
		local dir = preset_dir()
		local list = {}
		local pipe = io.popen("ls -1 " .. shq(dir) .. " 2>/dev/null")
		if pipe then
			for line in pipe:lines() do
				local n = line:match("^(.+)%.json$")
				if n then
					list[#list + 1] = n
				end
			end
			pipe:close()
		end
		if #list == 0 then
			list = { "INIT", "CRUNCH", "AMBIENT" }
		end
		return list, dir
	end

	local preset_list, pdir = load_preset_list()

	local self = {
		slots = make_slots(),
		bpm = 120,
		beat = 0,
		gain = 0.8,
		playing = true,
		t = 0,
		pitch_hz = 0,
		midi_note = -1,
		_presets = preset_list,
		_preset_dir = pdir,
	}

	local dsp = {}
	function dsp.backend_name()
		return "stub"
	end
	function dsp.slot_count()
		return SLOT_COUNT
	end
	function dsp.slot(i)
		return self.slots[i]
	end
	function dsp.params(i)
		return self.slots[i] and self.slots[i].params or {}
	end

	function dsp.get_param(slot, idx)
		local s = self.slots[slot]
		if MP.is_mix(idx) then -- mixer pseudo-param (gain/pan/mute/solo)
			return MP.read(s, idx)
		end
		local p = s and s.params[idx + 1]
		return p and p.value or 0
	end
	function dsp.set_param(slot, idx, value)
		local s = self.slots[slot]
		if MP.is_mix(idx) then -- mixer pseudo-param: write the slot field, not s.params[]
			MP.apply(s, idx, value)
			return
		end
		local p = s and s.params[idx + 1]
		if p then
			p.value = math.max(p.min, math.min(p.max, value))
		end
	end
	function dsp.set_bypass(slot, on)
		if self.slots[slot] then
			self.slots[slot].bypassed = on and true or false
		end
	end
	function dsp.set_wet(slot, w)
		if self.slots[slot] then
			self.slots[slot].wet = math.max(0, math.min(1, w))
		end
	end

	-- per-slot mixer controls — thin sugar over set_param with the reserved pseudo-param
	-- indices, so every move is automation-captured + bindable (see dsp/mixer_params.lua).
	function dsp.set_slot_gain(slot, g)
		dsp.set_param(slot, MP.GAIN, g)
	end
	function dsp.get_slot_gain(slot)
		return MP.read(self.slots[slot], MP.GAIN)
	end
	function dsp.set_slot_pan(slot, p)
		dsp.set_param(slot, MP.PAN, p)
	end
	function dsp.get_slot_pan(slot)
		return MP.read(self.slots[slot], MP.PAN)
	end
	function dsp.set_slot_mute(slot, on)
		dsp.set_param(slot, MP.MUTE, on and 1 or 0)
	end
	function dsp.get_slot_mute(slot)
		return MP.read(self.slots[slot], MP.MUTE) >= 0.5
	end
	function dsp.set_slot_solo(slot, on)
		dsp.set_param(slot, MP.SOLO, on and 1 or 0)
	end
	function dsp.get_slot_solo(slot)
		return MP.read(self.slots[slot], MP.SOLO) >= 0.5
	end
	function dsp.master_strip()
		return { gain = self.gain or 1.0, pan = self.master_pan or 0.0 }
	end

	function dsp.load_slot(slot, path)
		local s = self.slots[slot]
		if not s then
			return
		end
		s.loaded = true
		s.bypassed = false
		s.dsp_path = path or "user.dsp"
		s.name = (path or "USER"):gsub("%.%w+$", ""):upper()
		if #s.params == 0 then
			s.params = { P(0, "P1", 0, 1, 0.5, 0.01, "%"), P(1, "P2", 0, 1, 0.5, 0.01, "%") }
		end
	end
	function dsp.unload_slot(slot)
		local s = self.slots[slot]
		if not s then
			return
		end
		s.loaded = false
		s.name = ""
		s.bypassed = true
		s.dsp_path = ""
		s.params = {}
		s.presets = nil
		s.is_patch = nil
		s.patch_id = nil
	end
	function dsp.swap_slots(a, b)
		if self.slots[a] and self.slots[b] then
			self.slots[a], self.slots[b] = self.slots[b], self.slots[a]
		end
	end

	-- load a Faust synth/fx patch into a slot (simulated so it's demoable here)
	function dsp.load_patch(slot, spec)
		local s = self.slots[slot]
		if not s then
			return false
		end
		s.loaded = true
		s.bypassed = false
		s.wet = 1.0
		s.kind = spec.kind or "fx"
		s.name = (spec.name or "PATCH"):upper()
		s.dsp_path = spec.path or "patch.so"
		s.params = {}
		for j, pd in ipairs(spec.params or {}) do
			s.params[j] = P(j - 1, pd.label, pd.min, pd.max, pd.init, pd.step, pd.unit)
		end
		if #s.params == 0 then
			s.params = { P(0, "LEVEL", 0, 1, 0.7, 0.01, "%") }
		end
		s.presets = spec.presets -- factory presets carried from the descriptor (optional)
		-- a marketplace patch carries patch_id; stock effects (also via load_patch) don't.
		s.is_patch = spec.patch_id ~= nil
		s.patch_id = spec.patch_id
		return true
	end

	-- reflect a patch another process loaded (shadow only; identical to load on the stub
	-- since there's no real engine). Honours the saved bypass state.
	function dsp.adopt_patch(slot, spec)
		dsp.load_patch(slot, spec)
		if self.slots[slot] and spec.bypassed ~= nil then
			self.slots[slot].bypassed = spec.bypassed and true or false
		end
		return true
	end

	-- richer synthetic waveform for production-feeling visuals
	function dsp.scope()
		local L, R = {}, {}
		local n = 256
		for i = 1, n do
			local x = (i / n) * math.pi * 2
			local t = self.t
			-- fundamental + 2nd/3rd harmonics, light vibrato + tremolo
			local vib = 1 + 0.03 * math.sin(t * 1.7)
			local fund = math.sin(x * 2 * vib + t * 5.2)
			local h2 = 0.35 * math.sin(x * 4 * vib + t * 5.8 + 0.7)
			local h3 = 0.18 * math.sin(x * 6 * vib + t * 6.1 + 1.4)
			local env = 0.45 + 0.12 * math.sin(t * 0.9)
			-- occasional soft noise burst
			local noise = (math.random() < 0.02) and (math.random() - 0.5) * 0.25 or 0
			L[i] = (fund + h2 + h3) * env + noise
			R[i] = (fund + h2 * 0.9 + h3 * 1.1) * env + noise * 0.6 -- slight stereo offset
		end
		return { L = L, R = R, n = n }
	end

	function dsp.meters()
		local mask = 0
		local levels, levels_l, levels_r = {}, {}, {}
		local any_solo = false
		for i = 1, SLOT_COUNT do
			if self.slots[i].solo then
				any_solo = true
				break
			end
		end
		for i = 1, SLOT_COUNT do
			local s = self.slots[i]
			local active = s.loaded and not s.bypassed
			if active then
				mask = mask | (1 << (i - 1))
			end
			-- synthetic per-slot output level so the UI meters are demoable on the stub
			local lv = active and (0.35 + 0.3 * math.abs(math.sin(self.t * 2.2 + i * 0.7))) or 0
			-- mixer gating: mute silences; with any solo engaged, non-soloed strips silence;
			-- post-fader (gain-scaled) so the fader visibly drives the meter on the stub.
			if s.mute or (any_solo and not s.solo) then
				lv = 0
			end
			lv = math.min(1, lv * (s.gain or 1.0))
			levels[i] = lv
			levels_l[i], levels_r[i] = MP.pan_law(lv, s.pan or 0)
		end
		-- realistic CPU walk + occasional xrun spikes
		local base_cpu = 22 + 14 * math.sin(self.t * 0.6) + 6 * math.sin(self.t * 1.9)
		local cpu = math.max(12, math.min(68, base_cpu + (math.random() - 0.5) * 3))
		local xruns = (cpu > 52 and math.random() < 0.12) and math.random(1, 3) or 0
		return {
			pitch_hz = self.pitch_hz,
			midi_note = self.midi_note,
			bpm = self.bpm,
			beat = self.beat,
			cpu = cpu,
			xruns = xruns,
			bypass_mask = mask,
			levels = levels,
			levels_l = levels_l, -- UI-derived (pan-law) L/R for the mixer meter display
			levels_r = levels_r,
		}
	end

	function dsp.transport(playing)
		self.playing = playing and true or false
	end
	function dsp.set_bpm(b)
		self.bpm = b
	end
	function dsp.set_gain(g)
		self.gain = g
	end

	-- note control (synthesized): drive the synth slot's gate/freq/level shadow + the
	-- detected-pitch readout so the UI/viz react, demoing the synth without an engine.
	local function mtof(n)
		return 440.0 * 2 ^ ((n - 69) / 12)
	end
	function dsp.note_on(slot, note, vel)
		local hz = mtof(note)
		dsp.set_param(slot, 0, 1) -- gate
		dsp.set_param(slot, 1, hz) -- freq
		dsp.set_param(slot, 2, (vel or 100) / 127) -- level
		self.pitch_hz = hz
	end
	function dsp.note_off(slot)
		dsp.set_param(slot, 0, 0)
	end
	function dsp.all_notes_off(slot)
		dsp.set_param(slot, 0, 0)
	end

	function dsp.presets()
		return self._presets
	end

	function dsp.preset_save(name)
		local dir = self._preset_dir
		os.execute("mkdir -p " .. shq(dir) .. " 2>/dev/null")
		local f = io.open(dir .. "/" .. name .. ".json", "w")
		if not f then
			return false
		end
		f:write("{\n")
		for i, s in ipairs(self.slots) do
			local nm = tostring(s.name or ""):gsub('[%z\1-\31"\\]', "")
			f:write(
				string.format(
					'  "slot%d": {"name":"%s","bypassed":%s,"gain":%.6g,"pan":%.6g,"mute":%s,"solo":%s,"params":[',
					i,
					nm,
					tostring(s.bypassed),
					s.gain or 1.0,
					s.pan or 0.0,
					tostring(s.mute or false),
					tostring(s.solo or false)
				)
			)
			for j, p in ipairs(s.params) do
				f:write(string.format("%s%.6g", j > 1 and "," or "", p.value))
			end
			f:write("]}" .. (i < #self.slots and "," or "") .. "\n")
		end
		f:write("}\n")
		f:close()
		if not self._presets then
			self._presets = {}
		end
		local exists = false
		for _, n in ipairs(self._presets) do
			if n == name then
				exists = true
				break
			end
		end
		if not exists then
			table.insert(self._presets, name)
		end
		return true
	end

	function dsp.preset_load(name)
		local dir = self._preset_dir
		local f = io.open(dir .. "/" .. name .. ".json", "r")
		if not f then
			return false
		end
		local content = f:read("*a")
		f:close()
		-- very minimal JSON extraction (assumes our own format)
		for slot_str, body in content:gmatch('"slot(%d+)":%s*({[^}]+})') do
			local si = tonumber(slot_str)
			local s = self.slots[si]
			if not s then
				goto continue
			end
			local byp = body:match('"bypassed":%s*(%a+)') == "true"
			s.bypassed = byp
			-- mixer fields (optional: older presets omit them → keep current defaults)
			local g = body:match('"gain":%s*(-?[%d%.eE+]+)')
			if g then
				s.gain = tonumber(g) or s.gain
			end
			local pn = body:match('"pan":%s*(-?[%d%.eE+]+)')
			if pn then
				s.pan = tonumber(pn) or s.pan
			end
			local mu = body:match('"mute":%s*(%a+)')
			if mu then
				s.mute = (mu == "true")
			end
			local so = body:match('"solo":%s*(%a+)')
			if so then
				s.solo = (so == "true")
			end
			local vals = body:match('"params":%s*%[([^%]]+)%]')
			if vals then
				local idx = 1
				for v in vals:gmatch("([%-%d%.]+)") do
					if s.params[idx] then
						s.params[idx].value = tonumber(v) or s.params[idx].value
					end
					idx = idx + 1
				end
			end
			::continue::
		end
		return true
	end

	function dsp.poll(dt)
		self.t = self.t + dt
		if self.playing then
			self.beat = math.floor(self.t * self.bpm / 60) % 4
		end
		-- fake a wandering detected pitch
		self.pitch_hz = 82 * (1 + 0.04 * math.sin(self.t * 0.7))
		self.midi_note = 40
	end

	return dsp
end

return { new = new }
