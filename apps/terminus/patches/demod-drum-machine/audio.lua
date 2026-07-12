-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/audio.lua — the drum-trigger bridge.

  Resolves the best available output once, at open(), into one of three modes:

    "kit"    a real demod-drums slot is loaded on the DSP backend → fire a voice
             by pulsing its one-shot *Gate param (set_param(slot,gate,1) then ,0
             the next tick). This is the genuine 808/909 kit.
    "note"   no kit, but the gamekit K.sound bridge is live → play the voice's
             General-MIDI drum note through whatever synth is loaded.
    "silent" no audio path at all (e.g. headless) → fire() is a no-op, visuals
             still run.

  The DSP backend is reached the same relative way gamekit reaches midi_input:
  <patch>/../../dsp, with $DEMOD_UI_ROOT as a fallback. Everything is pcall'd so
  a missing/broken backend degrades to note/silent rather than crashing the UI.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor = math.floor

local A = {}

local function file_exists(p)
	local f = io.open(p, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- find a loaded synth slot that looks like demod-drums; returns slot index|nil
local function find_kit_slot(dsp, voices)
	local ok, n = pcall(dsp.slot_count)
	if not ok or not n then
		return nil
	end
	for i = 1, n do
		local sok, sl = pcall(dsp.slot, i)
		if sok and sl and sl.loaded and (sl.kind == "synth" or sl.kind == nil) then
			local nm = tostring(sl.name or ""):upper()
			local np = sl.nparams
			if not np then
				local pok, params = pcall(dsp.params, i)
				np = (pok and params) and #params or 0
			end
			if nm:find(voices.kit_name_match) and np >= voices.kit_min_params then
				return i
			end
		end
	end
	return nil
end

-- lazily load the shared sampler kit (StreamDB library + one-shot player) the
-- first time a sample is bound or the library is listed — so the drum machine
-- doesn't open the samples db unless sampler mode is actually used.
local function ensure_sampler(self, here)
	if self._sampler_loaded then
		return
	end
	self._sampler_loaded = true
	local ok1, s = pcall(dofile, here .. "../sampler/sampledb.lua")
	local ok2, p = pcall(dofile, here .. "../sampler/player.lua")
	if ok1 and ok2 and s and p then
		self._sdb, self._player = s, p
		pcall(s.init)
		pcall(p.init)
		self.sampler_ok = (s.ok and p.has) or false
	end
end

-- open(K, voices, here) -> handle { mode, label, fire, tick, bind, lib_list, ... }
function A.open(K, voices, here)
	local self = { mode = "silent", label = "VISUAL", _pending = {}, samples = {}, sample_paths = {}, sampler_ok = false }

	-- 1) try the DSP backend for a real kit
	local dsp_dir = here .. "../../dsp"
	local root = os.getenv("DEMOD_UI_ROOT")
	if root and #root > 0 and not file_exists(dsp_dir .. "/backend/select.lua") then
		dsp_dir = root .. "/dsp"
	end
	if file_exists(dsp_dir .. "/backend/select.lua") then
		local ok, sel = pcall(dofile, dsp_dir .. "/backend/select.lua")
		if ok and type(sel) == "table" and sel.select then
			local bok, dsp = pcall(sel.select, dsp_dir)
			if bok and dsp then
				local slot = find_kit_slot(dsp, voices)
				if slot then
					self.dsp = dsp
					self.slot = slot
					self.mode = "kit"
					self.label = "KIT"
				end
			end
		end
	end

	-- 2) fall back to the gamekit note bridge
	if self.mode == "silent" then
		local snd = K.sound("drum-machine")
		if snd and snd.has then
			self.snd = snd
			self.mode = "note"
			self.label = "NOTE"
		end
	end

	-- bind a library sample to a voice (id=nil clears); pre-extracts the wav
	function self.bind(v, id)
		ensure_sampler(self, here)
		self.samples[v] = id
		self.sample_paths[v] = nil
		if id and self._sdb and self._sdb.ok then
			self.sample_paths[v] = self._sdb.extract(id)
		end
	end

	-- the sample library (for a picker); loads the kit on first call
	function self.lib_list()
		ensure_sampler(self, here)
		if self._sdb and self._sdb.ok then
			return self._sdb.list()
		end
		return {}
	end

	function self.bound_count()
		local n = 0
		for _ in pairs(self.samples) do
			n = n + 1
		end
		return n
	end

	-- fire voice v (1-based index into voices.list) at velocity 0..1
	function self.fire(v, vel)
		local voice = voices.list[v]
		if not voice then
			return
		end
		-- sampler layer wins when this voice is bound to a library sample
		if self.samples[v] and self._player and self._player.has then
			local path = self.sample_paths[v]
			if not path and self._sdb then
				path = self._sdb.extract(self.samples[v])
				self.sample_paths[v] = path
			end
			if path then
				self._player.trig(path, vel or 1.0)
				return
			end
		end
		if self.mode == "kit" then
			pcall(self.dsp.set_param, self.slot, voice.gate, 1)
			-- schedule the gate back to 0 on the next tick (rising-edge trigger)
			self._pending[#self._pending + 1] = { kind = "gate", arg = voice.gate, t = 0 }
		elseif self.mode == "note" then
			self.snd.on(voice.note, vel or 1.0)
			self._pending[#self._pending + 1] = { kind = "note", arg = voice.note, t = 0 }
		end
	end

	-- service scheduled gate-offs / note-offs (call once per frame)
	function self.tick(dt)
		if #self._pending == 0 then
			return
		end
		local keep = {}
		for _, e in ipairs(self._pending) do
			e.t = e.t + (dt or 0)
			-- a one-frame rising edge is enough; release after ~12ms
			if e.t >= 0.012 then
				if e.kind == "gate" and self.dsp then
					pcall(self.dsp.set_param, self.slot, e.arg, 0)
				elseif e.kind == "note" and self.snd then
					self.snd.off(e.arg)
				end
			else
				keep[#keep + 1] = e
			end
		end
		self._pending = keep
	end

	return self
end

return A
