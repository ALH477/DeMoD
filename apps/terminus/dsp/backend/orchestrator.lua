-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/backend/orchestrator.lua — drive the demod5 orchestrator (on the guitar).

  Writes go to the control socket via the C bindings (dm.ctl_*). Live meters
  (pitch / bpm / beat / bypass mask) come from the param bus (dm.params_read()).

  Per-parameter *values* are kept as a local shadow: the param bus exposes a
  flat fx_params[16] window, not a per-slot×per-idx map, and the control socket
  has no get_param yet — so the UI is the source of truth for slider positions
  (seeded from fx_descriptors inits) and mirrors them down with set_param.
  Follow-ups (orchestrator side): get_fx_info / load_fx / a per-slot scope ring.

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

-- POSIX shell single-quote (preset dir derives from $DEMOD_PRESET_DIR/$HOME). SECURITY.md F-7.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function new(base)
	local D = dofile(base .. "/fx_descriptors.lua")
	local MP = dofile(base .. "/mixer_params.lua")
	-- pseudo-param index → control-socket op + numeric arg name (mute/solo use "on")
	local MIX_OP = {
		[MP.GAIN] = "set_slot_gain",
		[MP.PAN] = "set_slot_pan",
		[MP.MUTE] = "set_slot_mute",
		[MP.SOLO] = "set_slot_solo",
	}
	local MIX_ARG = { [MP.GAIN] = "gain", [MP.PAN] = "pan" }

	-- Resolve an effect name/path to the engine-loadable plugin. Stock effects are
	-- compiled into DEMOD_LIBRARY_DIR as `demod_<name>.so` (mirroring the demod5
	-- dsp/effects/demod_*.dsp sources), so a bare descriptor name like "OVERDRIVE"
	-- or "compress.dsp" maps to demod_overdrive.so / demod_compressor.so — NOT the
	-- old lowercased "overdrive.so", which never existed and made every default-FX
	-- load_fx silently fail (engine booted with 0 plugins). A few descriptor stems
	-- differ from their file (COMPRESS→compressor, the generic SYNTH→synth_fm) so
	-- alias those. Marketplace patches carry an absolute .so path → pass it through.
	local STOCK_ALIAS = { compress = "compressor", synth = "synth_fm" }
	local LIBDIR = os.getenv("DEMOD_LIBRARY_DIR")
	local function resolve_fx_path(p)
		if not p or p == "" then
			return ""
		end
		-- A real path to an existing .so (a patch's own compiled artifact) is used
		-- verbatim — don't collapse it into the stock library by basename.
		if p:find("/", 1, true) then
			local f = io.open(p, "rb")
			if f then
				f:close()
				return p
			end
		end
		local stem = p:gsub("^.*/", ""):gsub("%.%w+$", ""):lower()
		stem = STOCK_ALIAS[stem] or stem
		if not stem:find("^demod_") then
			stem = "demod_" .. stem
		end
		if LIBDIR and #LIBDIR > 0 then
			return LIBDIR .. "/" .. stem .. ".so"
		end
		return stem .. ".so"
	end

	-- build slots from the default device layout
	local slots = {}
	for i, name in ipairs(D.default_layout) do
		local desc = D.effects[name] or {}
		local params = {}
		local wet0 = 1.0
		for j, pd in ipairs(desc) do
			params[j] = {
				index = j - 1,
				label = pd.label,
				min = pd.min,
				max = pd.max,
				init = pd.init,
				step = pd.step,
				value = pd.init,
				unit = pd.unit,
			}
			-- seed the slot wet/dry from the effect's MIX-style param init
			local L = (pd.label or ""):upper()
			if L:find("MIX") or L:find("WET") or L:find("BLEND") then
				wet0 = pd.init
			end
		end
		slots[i] = {
			loaded = true,
			name = name,
			kind = "fx",
			bypassed = false,
			wet = wet0,
			dsp_path = name:lower() .. ".dsp",
			params = params,
		}
	end
	-- Stock effects occupy slots 1..STOCK; pad the rack with empty slots so marketplace
	-- patches can STACK alongside the tone (slots STOCK+1..). DEMOD_FX_SLOTS sets the total
	-- and MUST NOT exceed what demod-rt accepts for load_fx. See docs/ENGINE_CONTRACTS.md.
	local STOCK = #slots
	local TOTAL = math.max(STOCK, tonumber(os.getenv("DEMOD_FX_SLOTS") or "") or 12)
	for i = STOCK + 1, TOTAL do
		slots[i] = { loaded = false, name = "", kind = "fx", bypassed = true, wet = 1.0, dsp_path = "", params = {} }
	end
	local SLOT_COUNT = math.max(TOTAL, 1)
	for i = 1, SLOT_COUNT do
		MP.init_slot(slots[i]) -- seed per-slot gain/pan/mute/solo shadow
	end

	local self = {
		slots = slots,
		bpm = 120,
		beat = 0,
		pitch_hz = 0,
		midi_note = -1,
		cpu = 0,
		xruns = 0,
		bypass_mask = 0,
		_presets = nil,
		scope = nil, -- waveform ring (set by poll if demod-rt provides one) — see docs/ENGINE_CONTRACTS.md
		levels = {}, -- per-slot output RMS (set by poll if provided)
		levels_l = {}, -- per-slot L/R peak (set by poll if the engine publishes them)
		levels_r = {},
		master_pan = 0.0,
		_mix_last = {}, -- last-emitted mixer value per "slot:idx" (change-dedup, anti-flood)
	}

	-- The demod-orchestrator (Haskell) control socket speaks JSON-lines with a
	-- versioned envelope: {"v":1,"id":..,"op":..,<args>}. It accepts op|verb only
	-- (NOT "cmd"). The C helpers dm.ctl_* emit the legacy {"cmd":..} shape that the
	-- orchestrator rejects ("missing op"), so we build the correct envelope here
	-- and send it through the raw dm.ctl escape hatch.
	local seq = 0
	local function jstr(s)
		return '"'
			.. tostring(s):gsub('[%z\1-\31\\"]', function(c)
				if c == '"' then
					return '\\"'
				elseif c == "\\" then
					return "\\\\"
				elseif c == "\n" then
					return "\\n"
				else
					return string.format("\\u%04x", string.byte(c))
				end
			end)
			.. '"'
	end
	local function jval(v)
		if type(v) == "string" then
			return jstr(v)
		elseif type(v) == "boolean" then
			return tostring(v)
		elseif type(v) == "number" then
			return string.format("%.6g", v)
		else
			return "null"
		end
	end
	local warned = {}
	local function ctl(op, args)
		if not dm.ctl then
			return false
		end
		seq = seq + 1
		local s = '{"v":1,"id":' .. jstr("ui-" .. seq) .. ',"op":' .. jstr(op)
		for _, kv in ipairs(args or {}) do
			s = s .. "," .. jstr(kv[1]) .. ":" .. jval(kv[2])
		end
		local ok = dm.ctl(s .. "}")
		if ok == false and not warned[op] then -- surface (once per op) instead of silent drop
			warned[op] = true
			io.stderr:write("[dsp] control op '" .. op .. "' failed (further warnings suppressed)\n")
		end
		return ok
	end

	local dsp = {}
	function dsp.backend_name()
		return "orchestrator"
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
	-- emit a mixer control op, deduped: continuous (gain/pan) only when moved >= 1/512,
	-- toggles (mute/solo) only on change, so a swept fader can't flood the control socket.
	local function emit_mix(slot, idx, stored)
		local key = slot .. ":" .. idx
		local spec, op = MP.SPEC[idx], MIX_OP[idx]
		if spec.kind == "bool" then
			local on = stored >= 0.5 and 1 or 0
			if self._mix_last[key] ~= on then
				self._mix_last[key] = on
				ctl(op, { { "slot", slot - 1 }, { "on", on == 1 } })
			end
		else
			local last = self._mix_last[key]
			if not last or math.abs(stored - last) >= (1 / 512) then
				self._mix_last[key] = stored
				ctl(op, { { "slot", slot - 1 }, { MIX_ARG[idx], stored } })
			end
		end
	end
	function dsp.set_param(slot, idx, value)
		local s = self.slots[slot]
		if MP.is_mix(idx) then -- mixer pseudo-param: write shadow + emit the mixer op
			if not s then
				return
			end
			emit_mix(slot, idx, MP.apply(s, idx, value))
			return
		end
		local p = s and s.params[idx + 1]
		if not p then
			return
		end
		p.value = math.max(p.min, math.min(p.max, value))
		ctl("set_param", { { "slot", slot - 1 }, { "idx", idx }, { "value", p.value } }) -- device slots 0-based
	end
	function dsp.set_bypass(slot, on)
		local s = self.slots[slot]
		if not s then
			return
		end
		s.bypassed = on and true or false
		ctl("bypass_fx", { { "slot", slot - 1 }, { "on", s.bypassed } })
	end
	function dsp.set_wet(slot, w)
		-- no dedicated wet op; map to the effect's MIX/WET/BLEND param if it has one
		local s = self.slots[slot]
		if not s then
			return
		end
		s.wet = math.max(0, math.min(1, w))
		for _, p in ipairs(s.params) do
			local L = (p.label or ""):upper()
			if L:find("MIX") or L:find("WET") or L:find("BLEND") then
				dsp.set_param(slot, p.index, s.wet)
				return
			end
		end
	end

	-- per-slot mixer controls — sugar over set_param with the reserved pseudo-param
	-- indices, so moves go through the wrapped capture path + emit the engine op.
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
		ctl("load_fx", { { "slot", slot - 1 }, { "path", resolve_fx_path(path) } })
	end
	function dsp.unload_slot(slot)
		ctl("unload_fx", { { "slot", slot - 1 } })
		-- clear the shadow too (poll only reconciles the bypass mask, not loaded/name),
		-- so CLEAR on a patch slot empties it in the UI immediately.
		local s = self.slots[slot]
		if s then
			s.loaded = false
			s.name = ""
			s.bypassed = true
			s.dsp_path = ""
			s.params = {}
			s.presets = nil
			s.is_patch = nil
			s.patch_id = nil
		end
	end
	function dsp.swap_slots(a, b)
		if not (self.slots[a] and self.slots[b]) then
			return
		end
		self.slots[a], self.slots[b] = self.slots[b], self.slots[a]
		-- re-issue both positions so the engine's chain order matches the shadow
		-- (no dedicated swap op on the control socket; ctl no-ops without dm.ctl)
		for _, i in ipairs({ a, b }) do
			local sx = self.slots[i]
			dsp.load_slot(i, sx.dsp_path)
			for _, p in ipairs(sx.params) do
				ctl("set_param", { { "slot", i - 1 }, { "idx", p.index }, { "value", p.value } })
			end
			dsp.set_wet(i, sx.wet)
		end
	end

	-- load a patch (a Faust synth/fx) into a slot: tell demod-rt to dlopen its
	-- compiled .so (load_fx) AND mirror name/params into the shadow so the UI
	-- shows it running immediately. This is "patch as native plugin in the engine".
	-- populate a slot's UI shadow from a patch spec (NO engine call). Shared by load_patch
	-- (which then issues the engine load) and adopt_patch (which only reflects a patch
	-- another process already loaded). A patch carries patch_id; stock effects (also via
	-- load_patch) don't, so the chain/routing/manager can flag "a patch runs here".
	local function set_patch_shadow(slot, spec)
		local s = self.slots[slot]
		if not s then
			return
		end
		s.loaded = true
		s.bypassed = spec.bypassed and true or false
		s.wet = 1.0
		s.kind = spec.kind or "fx"
		s.name = (spec.name or "PATCH"):upper()
		s.dsp_path = spec.path or ""
		local params = {}
		for j, pd in ipairs(spec.params or {}) do
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
		s.presets = spec.presets -- factory presets carried from the descriptor (optional)
		s.is_patch = spec.patch_id ~= nil
		s.patch_id = spec.patch_id
	end

	-- load a patch (Faust synth/fx) into a slot: dlopen its compiled .so in demod-rt
	-- (load_fx) AND mirror it into the shadow so the UI shows it running immediately.
	function dsp.load_patch(slot, spec)
		set_patch_shadow(slot, spec)
		if self.slots[slot] then
			self.slots[slot].bypassed = false -- a fresh load is active
		end
		ctl("load_fx", { { "slot", slot - 1 }, { "path", resolve_fx_path(spec.path or spec.name) } })
		return true
	end

	-- reflect a patch ANOTHER process already loaded (shadow only — no load_fx, which
	-- would needlessly restart demod-rt). DSP Studio's manifest reconcile uses this to
	-- show patches Home loaded into the background engine.
	function dsp.adopt_patch(slot, spec)
		set_patch_shadow(slot, spec)
		return true
	end

	function dsp.scope()
		return self.scope -- nil until demod-rt provides a scope ring (viz falls back to PITCH)
	end

	function dsp.meters()
		return {
			pitch_hz = self.pitch_hz,
			midi_note = self.midi_note,
			bpm = self.bpm,
			beat = self.beat,
			cpu = self.cpu,
			xruns = self.xruns,
			bypass_mask = self.bypass_mask,
			levels = self.levels, -- per-slot output RMS (empty until the engine provides it)
			levels_l = self.levels_l, -- per-slot L/R peak (empty until the engine provides it)
			levels_r = self.levels_r,
		}
	end

	function dsp.transport(playing) end -- transport lives in the orchestrator
	function dsp.set_bpm(b)
		self.bpm = b
		ctl("set_bpm", { { "bpm", b } })
	end
	function dsp.set_gain(g)
		self.gain = g
		ctl("set_gain", { { "gain", g } })
	end

	-- Instrument note control. The orchestrator speaks a real polyphonic MIDI API
	-- (synth.note_on/note_off/all_notes_off), so the UI gets proper per-note
	-- envelopes + velocity instead of poking gate/freq. See docs/ENGINE_CONTRACTS.md.
	function dsp.note_on(slot, note, vel)
		ctl("synth.note_on", { { "slot", slot - 1 }, { "note", note }, { "velocity", vel or 100 } })
	end
	function dsp.note_off(slot, note)
		ctl("synth.note_off", { { "slot", slot - 1 }, { "note", note } })
	end
	function dsp.all_notes_off(slot)
		ctl("synth.all_notes_off", { { "slot", slot - 1 } })
	end

	-- presets: snapshot/apply the shadow param state to JSON under $HOME or /var/lib/demod
	local function preset_dir()
		local d = os.getenv("DEMOD_PRESET_DIR")
		if d and #d > 0 then
			return d
		end
		local h = os.getenv("HOME") or "/var/lib/demod"
		return h .. "/.local/share/demod/presets"
	end
	function dsp.presets()
		if self._presets then
			return self._presets
		end
		local list, dir = {}, preset_dir()
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
		self._presets = list
		return list
	end
	function dsp.preset_save(name)
		local dir = preset_dir()
		os.execute("mkdir -p " .. shq(dir) .. " 2>/dev/null")
		local f = io.open(dir .. "/" .. name .. ".json", "w")
		if not f then
			return false
		end
		f:write("{\n")
		for i, s in ipairs(self.slots) do
			-- strip quotes/backslashes/control chars from the (possibly patch-supplied)
			-- name so it can't produce malformed JSON. The name is display-only on load.
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
		self._presets = nil -- force relist
		return true
	end
	function dsp.preset_load(name)
		-- parse our own save format and apply param values + bypass to the engine
		local f = io.open(preset_dir() .. "/" .. name .. ".json", "r")
		if not f then
			return false
		end
		local content = f:read("*a")
		f:close()
		if not content then
			return false
		end
		for slot_str, body in content:gmatch('"slot(%d+)":%s*({[^}]+})') do
			local si = tonumber(slot_str)
			local s = self.slots[si]
			if s then
				local vals = body:match('"params":%s*%[([^%]]*)%]')
				if vals then
					local idx = 1
					for v in vals:gmatch("(-?%d[%d%.eE+-]*)") do
						local p = s.params[idx]
						if p then
							dsp.set_param(si, p.index, tonumber(v) or p.value)
						end
						idx = idx + 1
					end
				end
				dsp.set_bypass(si, body:match('"bypassed":%s*(%a+)') == "true")
				-- mixer fields (optional: older presets omit them → leave the shadow as-is)
				local g = body:match('"gain":%s*(-?[%d%.eE+]+)')
				if g then
					dsp.set_slot_gain(si, tonumber(g))
				end
				local pn = body:match('"pan":%s*(-?[%d%.eE+]+)')
				if pn then
					dsp.set_slot_pan(si, tonumber(pn))
				end
				local mu = body:match('"mute":%s*(%a+)')
				if mu then
					dsp.set_slot_mute(si, mu == "true")
				end
				local so = body:match('"solo":%s*(%a+)')
				if so then
					dsp.set_slot_solo(si, so == "true")
				end
			end
		end
		return true
	end

	function dsp.poll(dt)
		if not dm.params_read then
			return
		end
		local s = dm.params_read()
		if not s then
			return
		end
		self.pitch_hz = s.pitch_hz or self.pitch_hz
		self.midi_note = s.midi_note or self.midi_note
		self.bpm = (s.bpm and s.bpm > 0) and s.bpm or self.bpm
		self.bypass_mask = s.bypass_mask or 0
		if s.beat_count then
			self.beat = s.beat_count % 4
		end
		-- live feedback (optional engine fields; nil today → viz uses the PITCH
		-- fallback and the level meters stay empty). See docs/ENGINE_CONTRACTS.md.
		self.scope = s.scope -- { L = {..}, R = {..}, n = N } | nil
		if s.levels then
			self.levels = s.levels -- per-slot output RMS, 0..1
		end
		-- mixer readback (all optional; absent on an engine without the mixer ops → the
		-- shadow stays authoritative and the screen falls back to UI-derived L/R).
		if s.levels_l then
			self.levels_l = s.levels_l
		end
		if s.levels_r then
			self.levels_r = s.levels_r
		end
		if s.gain then
			for i = 1, SLOT_COUNT do
				if s.gain[i] then
					self.slots[i].gain = s.gain[i]
				end
			end
		end
		if s.pan then
			for i = 1, SLOT_COUNT do
				if s.pan[i] then
					self.slots[i].pan = s.pan[i]
				end
			end
		end
		if s.mute_mask then
			for i = 1, SLOT_COUNT do
				self.slots[i].mute = (s.mute_mask & (1 << (i - 1))) ~= 0
			end
		end
		if s.solo_mask then
			for i = 1, SLOT_COUNT do
				self.slots[i].solo = (s.solo_mask & (1 << (i - 1))) ~= 0
			end
		end
		-- Reconcile the bypass shadow from demod-rt's authoritative bypass mask.
		-- Semantics (verified against the live param bus): a SET bit => that slot is
		-- BYPASSED (the engine skips it); 0 => the slot is active. The normal
		-- all-active state is therefore mask 0. The previous code read this as an
		-- ACTIVE mask and inverted it (bypassed = not bit), so the all-active 0
		-- marked EVERY slot bypassed and effects could never be enabled in the UI.
		for i = 1, SLOT_COUNT do
			self.slots[i].bypassed = (self.bypass_mask & (1 << (i - 1))) ~= 0
		end
	end

	-- Push the default chain to the engine. The shadow built above only describes
	-- the UI; the engine boots with EMPTY slots, so without this audio passes
	-- through clean (the "effects show ON but nothing is audible" bug). Load each
	-- plugin, then push its init params + wet so it processes audio immediately.
	-- No-op when dm.ctl is unavailable (e.g. running under a non-orchestrator host).
	--
	-- Skipped when DEMOD_DSP_CHAIN_LOADED is set: the desktop launcher preloads the
	-- chain at boot (dsp/preload.lua) so effects are on before the UI opens; this
	-- avoids reloading it (a brief RT glitch) when DSP Studio then launches.
	-- No inter-load spacing needed: each load_fx restarts demod-rt, but dm.ctl now
	-- blocks for the orchestrator's reply (demod-ui ipc: control socket waits for
	-- reply, rev 8ce5724+), so these loads serialize and the burst can't race the
	-- restarts. (On an older host where dm.ctl is fire-and-forget, the loads would
	-- race and only one slot would survive — bump the demod-ui pin if you see that.)
	if not os.getenv("DEMOD_DSP_CHAIN_LOADED") then
		for i = 1, STOCK do -- only the stock chain; the padded slots stay empty for patches
			local sl = slots[i]
			dsp.load_slot(i, sl.dsp_path)
			for _, prm in ipairs(sl.params) do
				ctl("set_param", { { "slot", i - 1 }, { "idx", prm.index }, { "value", prm.value } })
			end
			dsp.set_wet(i, sl.wet)
		end
	end

	return dsp
end

return { new = new }
