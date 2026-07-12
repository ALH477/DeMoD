-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  control_surface.lua — the shared, bidirectional param <-> MIDI control surface.

  Embedded in TERMINUS and loaded by BOTH shells (home.lua and dsp/dsp_studio.lua,
  separate framebuffer-handoff processes, one instance each). It is the evolution of
  the old dsp/bindings.lua param<->control registry (which is now a thin re-export
  shim, so the BINDINGS + PARAMS screens keep working unchanged).

  It does three things, any subset of which is useful on its own:
    1. PARAM CONTROL (always on, the "works by itself" case): map any source
       (a MIDI CC, a footswitch FOOT_n, or the gamepad/encoder "performance" param)
       to an effect/synth parameter and drive it. Identical to the previous bindings.lua.
    2. PARAM -> MIDI OUT: give a target a MIDI-out destination ({ch,kind,num}); when the
       param moves (from ANY source, including the encoder/perf or the UI) the surface
       emits a CC/note out, turning TERMINUS into a MIDI controller for external gear.
    3. MIDI IN -> PARAM: inbound CC already drives the param (1); the echo guard keeps
       an inbound-driven move from bouncing straight back out as MIDI.

  A master LATCH (set_enabled / toggle_enabled, mapped to a settings button) gates the
  MIDI side: when OFF the surface is exactly the old param-only registry. A global MODE
  (both | params | midi) with an optional per-binding override picks the direction:
    both   - in drives param, param moves emit out (full bridge)
    params - in drives param, no emit                (input-only)
    midi   - param moves emit out, inbound ignored   (output-only / broadcast)

  Persistence (flat string maps, so settings.lua's existing string->string persister
  saves them with no serializer change):
      param_bindings  = { ["slot1.p0"] = "cc:74:abs", ["slot2.p1"] = "foot:3:toggle:midi" }
      cs_out_bindings = { ["slot1.p0"] = "cc:1:74" }   -- kind:ch:num
      perf_target     = "slot1.p0"
  The optional 4th field of a param_bindings value is the per-binding mode override;
  legacy 3-field strings and the old midi_cc_bindings map migrate in transparently.

  Pure / dm-free (like the old bindings.lua) so it stays busted-testable: MIDI emission
  goes through an injected emit_fn (attach_midi), normally midi.send.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

local dsp_set, dsp_get -- attached host param I/O (the wrapped set_param, so binding
-- moves are still captured by automation recording)
local emit_midi -- injected MIDI sender: emit_midi(status, d1, d2); usually midi.send

local targets = {} -- ordered: { {id,label,slot,index,min,max,step}, ... }
local by_id = {} -- id -> target
-- binds: id -> { source="cc"|"foot", code=<string>, mode="abs"|"toggle"|"step",
--                override=nil|"both"|"params"|"midi",  -- per-binding mode override
--                out=nil|{ch=1..16,kind="cc"|"note",num=0..127},  -- MIDI-out dest
--                _last_emit=nil|0..127 }  -- last value we sent (echo dedup)
-- An entry may be "out-only" (source=nil) when a param has a MIDI-out dest but no input.
local binds = {}
local rev = {} -- "source:code" -> id (reverse lookup for feed)
local capturing = nil -- id awaiting the next control event (input assign), or nil
local capturing_out = nil -- id awaiting the next CC (MIDI-out learn), or nil
local perf_id = nil -- the performance param (gamepad/encoder), or nil

local enabled = true -- master latch for the MIDI side (param control works regardless)
local g_mode = "both" -- "both" | "params" | "midi"
local origin = nil -- "midi" while a feed-driven write is in flight (echo guard)

local VALID_MODE = { both = true, params = true, midi = true }

local function default_mode(source)
	return source == "cc" and "abs" or "toggle"
end
local function clampi(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end
-- split on a literal single-char separator into a positional list (robust, no patterns).
local function split(s, sep)
	local t, start = {}, 1
	s = tostring(s)
	while true do
		local i = s:find(sep, start, true)
		if not i then
			t[#t + 1] = s:sub(start)
			return t
		end
		t[#t + 1] = s:sub(start, i - 1)
		start = i + 1
	end
end

-- Attach the host's param I/O. set_param should be the automation-wrapped one so that
-- binding-driven moves are captured into takes just like manual edits.
function M.attach(set_param, get_param)
	dsp_set, dsp_get = set_param, get_param
end
-- Attach the MIDI sender used for param -> MIDI-out emission (normally midi.send).
function M.attach_midi(fn)
	emit_midi = fn
end

-- ── master latch + global mode ───────────────────────────────────────────────
function M.set_enabled(on)
	enabled = on and true or false
end
function M.enabled()
	return enabled
end
function M.toggle_enabled()
	enabled = not enabled
	return enabled
end
function M.set_mode(m)
	if VALID_MODE[m] then
		g_mode = m
	end
end
function M.mode()
	return g_mode
end

-- ── targets ────────────────────────────────────────────────────────────────
-- Register (or refresh) a learnable target. Idempotent: re-registering a live slot's
-- params each frame just updates the cached range, so feed always sees fresh metadata.
function M.register_target(id, label, slot, index, min, max, step)
	local t = by_id[id]
	if t then
		t.label = label or t.label
		t.slot, t.index, t.min, t.max, t.step = slot, index, min or 0, max or 1, step or t.step or 0.01
		return t
	end
	t = {
		id = id,
		label = label or id,
		slot = slot,
		index = index,
		min = min or 0,
		max = max or 1,
		step = step or 0.01,
	}
	targets[#targets + 1] = t
	by_id[id] = t
	return t
end

function M.target(id)
	return by_id[id]
end
-- all registered target ids, in registration order (scene capture iterates these)
function M.target_ids()
	local out = {}
	for _, t in ipairs(targets) do
		out[#out + 1] = t.id
	end
	return out
end

-- ── value application (the ONE write chokepoint emits MIDI on the way out) ────
local function emit_for(t, value)
	if not (emit_midi and enabled) then
		return
	end
	local b = binds[t.id]
	if not (b and b.out) then
		return
	end
	local m = b.override or g_mode
	if m == "params" then
		return -- params-only: never emit
	end
	if origin == "midi" then
		return -- echo guard: an inbound-driven move never re-emits
	end
	local span = t.max - t.min
	local v01 = span ~= 0 and (value - t.min) / span or 0
	v01 = v01 < 0 and 0 or (v01 > 1 and 1 or v01)
	local o = b.out
	local ch = (o.ch or 1) - 1
	-- 1/127 dedup: only emit when the quantized value actually changes. This bounds MIDI-out
	-- traffic when a per-frame source (LFO/env) holds or barely moves a mapped param.
	local nv = o.kind == "note" and (v01 >= 0.5 and 127 or 0) or math.floor(v01 * 127 + 0.5)
	if b._last_emit == nv then
		return
	end
	b._last_emit = nv
	if o.kind == "note" then
		emit_midi((nv > 0 and 0x90 or 0x80) | ch, o.num, nv)
	else
		emit_midi(0xB0 | ch, o.num, nv)
	end
end

-- modulation hooks (Phase 3): a modulated target's LFO/etc. rides ON TOP of the user's
-- set value; a manual (non-mod) write rebases that center so "turn the knob and the LFO
-- keeps wobbling around the new value". mod_writing marks the modulation engine's own
-- writes so they don't trigger a spurious rebase.
local mod_targets, mod_rebase, mod_writing = {}, nil, false
function M.set_rebase(fn)
	mod_rebase = fn
end
function M.mark_modulated(id, on)
	mod_targets[id] = on and true or nil
end

local function write(t, value)
	if not (dsp_set and t) then
		return
	end
	dsp_set(t.slot, t.index, value) -- set_param clamps
	emit_for(t, value)
	if mod_rebase and mod_targets[t.id] and not mod_writing then
		local span = t.max - t.min
		mod_rebase(t.id, span ~= 0 and (value - t.min) / span or 0)
	end
end

local function cur01(t)
	local v = (dsp_get and dsp_get(t.slot, t.index)) or t.min
	local span = t.max - t.min
	if span == 0 then
		return 0
	end
	return (v - t.min) / span
end
local function apply_abs(t, v01)
	if not (dsp_set and t) then
		return
	end
	v01 = v01 < 0 and 0 or (v01 > 1 and 1 or v01)
	write(t, t.min + v01 * (t.max - t.min))
end
local function apply_toggle(t)
	if not (dsp_set and t) then
		return
	end
	write(t, cur01(t) >= 0.5 and t.min or t.max)
end
local function apply_nudge(t, dir)
	if not (dsp_set and t) then
		return
	end
	local v = (dsp_get and dsp_get(t.slot, t.index)) or t.min
	local step = (t.step and t.step > 0) and t.step or ((t.max - t.min) / 32)
	write(t, v + dir * step)
end
local function apply_step(t) -- one discrete step up, wrapping past max back to min
	if not (dsp_set and t) then
		return
	end
	local v = (dsp_get and dsp_get(t.slot, t.index)) or t.min
	local step = (t.step and t.step > 0) and t.step or ((t.max - t.min) / 8)
	v = v + step
	if v > t.max + 1e-6 then
		v = t.min
	end
	write(t, v)
end

-- ── value shaping (curve / invert / deadzone / quantize / range remap) ───────
-- sh = { curve="lin"|"exp"|"log"|"s", invert, deadzone=0..1, quantize=0|N, lo=0..1,
--        hi=0..1, pickup=bool }. Pure: maps an input 0..1 through the transform to an
-- output 0..1. Reused by direct bindings (feed), macros, and modulation routes (later).
local CURVES = { lin = true, exp = true, log = true, s = true }
function M.shape(v01, sh)
	v01 = v01 < 0 and 0 or (v01 > 1 and 1 or v01)
	if not sh then
		return v01
	end
	-- deadzone: ignore the bottom band, then rescale the rest back to 0..1
	local dz = sh.deadzone or 0
	if dz > 0 and dz < 1 then
		v01 = v01 <= dz and 0 or (v01 - dz) / (1 - dz)
	end
	local c = sh.curve
	if c == "exp" then
		v01 = v01 * v01
	elseif c == "log" then
		v01 = 1 - (1 - v01) * (1 - v01)
	elseif c == "s" then
		v01 = v01 * v01 * (3 - 2 * v01)
	end
	if sh.invert then
		v01 = 1 - v01
	end
	local q = sh.quantize or 0
	if q > 1 then
		v01 = math.floor(v01 * (q - 1) + 0.5) / (q - 1)
	end
	local lo, hi = sh.lo or 0, sh.hi or 1
	if lo ~= 0 or hi ~= 1 then
		v01 = lo + v01 * (hi - lo)
	end
	return v01 < 0 and 0 or (v01 > 1 and 1 or v01)
end

-- Decode a relative / incremental CC encoder byte to a signed step delta. raw = 0..127.
local function decode_rel(mode, raw)
	raw = raw or 0
	if mode == "rel_signed" then -- sign-magnitude: 0x01..0x3F = +n, 0x41..0x7F = -(n-0x40)
		if raw >= 0x41 then
			return -(raw - 0x40)
		elseif raw >= 1 and raw <= 0x3F then
			return raw
		end
	elseif mode == "rel_twos" then -- two's-complement: 1..63 = +, 65..127 = -
		if raw >= 1 and raw <= 63 then
			return raw
		elseif raw >= 65 and raw <= 127 then
			return raw - 128
		end
	end
	return 0
end

-- ── chokepoint wrappers (the public surface modulation.lua drives) ───────────
-- apply_to_target/value01/send_back let macros, LFO routes and scenes ride the same
-- write() chokepoint (param + echo-safe MIDI-out) without bypassing it.
function M.apply_to_target(id, v01)
	local t = by_id[id]
	if t then
		apply_abs(t, v01)
	end
end
function M.value01(id)
	local t = by_id[id]
	return t and cur01(t) or 0
end
-- Like apply_to_target but flagged as a modulation-engine write, so it does NOT rebase
-- the LFO center (used for LFO/env/step source routes; macros/manual use apply_to_target).
function M.apply_mod(id, v01)
	local t = by_id[id]
	if t then
		mod_writing = true
		apply_abs(t, v01)
		mod_writing = false
	end
end
-- Emit the target's current value once (controller feedback: motor faders / LED rings).
function M.send_back(id)
	local t = by_id[id]
	if t then
		emit_for(t, (dsp_get and dsp_get(t.slot, t.index)) or t.min)
	end
end

-- ── binding registry ────────────────────────────────────────────────────────
local function rk(source, code)
	return tostring(source) .. ":" .. tostring(code)
end
local function rebuild_rev()
	rev = {}
	for id, b in pairs(binds) do
		if b.source then -- out-only entries (no source) carry no reverse key
			rev[rk(b.source, b.code)] = id
		end
	end
end

function M.bind(id, source, code, mode)
	-- one control drives one param: drop any other target already on this (source,code)
	local prev = rev[rk(source, code)]
	if prev and prev ~= id then
		-- keep any out spec on the displaced binding by demoting it to out-only
		local pb = binds[prev]
		if pb and pb.out then
			pb.source, pb.code, pb.mode = nil, nil, nil
		else
			binds[prev] = nil
		end
	end
	local b = binds[id] or {}
	b.source, b.code, b.mode = tostring(source), tostring(code), mode or default_mode(source)
	b.tk = nil -- re-arm soft-takeover for the freshly (re)bound control
	binds[id] = b
	rebuild_rev()
end

function M.binding(id)
	return binds[id]
end
function M.clear(id)
	local b = binds[id]
	if b and b.out then -- keep the MIDI-out dest; only drop the input binding
		b.source, b.code, b.mode, b.override = nil, nil, nil, nil
	else
		binds[id] = nil
	end
	rebuild_rev()
end
function M.clear_all()
	binds = {}
	rebuild_rev()
end

-- Cycle a discrete binding between toggle <-> step (no-op for continuous CC bindings).
function M.cycle_mode(id)
	local b = binds[id]
	if not b or b.source == "cc" then
		return
	end
	b.mode = (b.mode == "toggle") and "step" or "toggle"
end

-- Cycle the per-binding mode override: (follow global) -> both -> params -> midi -> ...
function M.cycle_override(id)
	local b = binds[id]
	if not b then
		return
	end
	if not b.override then
		b.override = "both"
	elseif b.override == "both" then
		b.override = "params"
	elseif b.override == "params" then
		b.override = "midi"
	else
		b.override = nil
	end
end
function M.override(id)
	local b = binds[id]
	return b and b.override
end

-- ── per-binding shaping + relative-encoder mode (Phase 1) ────────────────────
function M.set_shape(id, sh)
	local b = binds[id]
	if not b then
		return
	end
	b.sh = sh
	b.tk = nil -- re-arm soft-takeover under the new settings
end
function M.shape_of(id)
	local b = binds[id]
	return b and b.sh
end
function M.set_enc(id, enc)
	local b = binds[id]
	if b then
		b.enc = enc
	end
end
function M.enc_of(id)
	local b = binds[id]
	return b and b.enc
end

-- ── MIDI-out destination per target ──────────────────────────────────────────
function M.set_out(id, out)
	local b = binds[id] or {}
	b.out = out
	b._last_emit = nil
	binds[id] = b
end
function M.out(id)
	local b = binds[id]
	return b and b.out
end
function M.clear_out(id)
	local b = binds[id]
	if not b then
		return
	end
	b.out, b._last_emit = nil, nil
	if not b.source then -- nothing left on this entry
		binds[id] = nil
	end
end
-- short display tag for an out dest, e.g. "->CC74" / "->N60", or nil.
function M.out_tag(id)
	local o = M.out(id)
	if not o then
		return nil
	end
	return (o.kind == "note" and "->N" or "->CC") .. tostring(o.num)
end

-- ── assign flows ─────────────────────────────────────────────────────────────
function M.begin_assign(id)
	capturing = id
end
function M.is_assigning()
	return capturing ~= nil
end
function M.assigning()
	return capturing
end
function M.cancel_assign()
	capturing = nil
end
-- arm "learn the MIDI-out destination from the next inbound CC" for this target.
function M.begin_assign_out(id)
	capturing_out = id
end
function M.is_assigning_out()
	return capturing_out ~= nil
end
function M.assigning_out()
	return capturing_out
end
function M.cancel_assign_out()
	capturing_out = nil
end

-- The host funnels every per-param control event here.
--   source = "cc" | "foot";  code = cc number / footswitch index (any scalar)
--   value  = 0..1 for continuous sources (CC); nil for discrete (foot)
--   ch     = optional inbound channel (1..16), used only by the MIDI-out learn
--   raw    = optional raw data byte (0..127), used by relative-encoder decode
-- Returns "bound" | "bound_out" | "applied" | "echo" | "hold" | nil.
function M.feed(source, code, value, ch, raw)
	-- MIDI-out learn: capture the next CC's number as this target's out dest.
	if capturing_out then
		if source == "cc" then
			local id = capturing_out
			capturing_out = nil
			M.set_out(id, { ch = ch or 1, kind = "cc", num = tonumber(code) or 0 })
			return "bound_out", id
		end
		return nil -- swallow non-CC while arming out-learn
	end
	-- input assign: bind the next control to the armed param.
	if capturing then
		local id = capturing
		capturing = nil
		M.bind(id, source, code, default_mode(source))
		return "bound", id
	end
	local id = rev[rk(source, code)]
	if not id then
		return nil
	end
	local t, b = by_id[id], binds[id]
	if not (t and b) then
		return nil
	end
	if enabled then
		local m = b.override or g_mode
		if m == "midi" then
			return nil -- output-only: inbound does not drive the param
		end
		-- soft-takeover (pickup): for continuous abs bindings with pickup on, HOLD until the
		-- inbound value crosses the param's current value, so an out-of-sync knob can't jump it.
		-- Runs BEFORE the echo dedup so a held value never consumes echo state.
		if value ~= nil and not b.enc and b.mode == "abs" and b.sh and b.sh.pickup then
			b.tk = b.tk or { picked = false }
			if not b.tk.picked then
				local cur = cur01(t)
				if math.abs(value - cur) <= (1 / 127) then
					b.tk.picked = true
				else
					local prev = b.tk.last
					b.tk.last = value
					if prev ~= nil and (prev - cur) * (value - cur) <= 0 then
						b.tk.picked = true
					else
						return "hold", id
					end
				end
			end
		end
		-- echo dedup: swallow an inbound value identical to the one we just emitted.
		if value ~= nil and b.out then
			local q = clampi(math.floor(value * 127 + 0.5), 0, 127)
			if b._last_emit == q then
				b._last_emit = nil
				return "echo", id
			end
		end
	end
	origin = "midi" -- echo guard on: the resulting write must not re-emit MIDI
	if b.enc and value ~= nil then -- relative / incremental CC encoder: signed delta
		local d = decode_rel(b.enc, raw or math.floor(value * 127 + 0.5))
		if d ~= 0 then
			apply_nudge(t, d)
		end
	elseif b.mode == "abs" and value ~= nil then
		apply_abs(t, M.shape(value, b.sh)) -- shape the inbound value before applying
	elseif b.mode == "step" then
		apply_step(t)
	else -- toggle
		apply_toggle(t)
	end
	origin = nil
	return "applied", id
end

-- ── performance param (gamepad / encoder, driven by mapped actions) ──────────
function M.set_perf(id)
	perf_id = id
end
function M.perf()
	return perf_id
end
function M.perf_apply(dir)
	local t = perf_id and by_id[perf_id]
	if t then
		apply_nudge(t, (dir or 0) >= 0 and 1 or -1)
	end
end
function M.perf_toggle()
	local t = perf_id and by_id[perf_id]
	if t then
		apply_toggle(t)
	end
end

-- ── display ──────────────────────────────────────────────────────────────────
local function src_tag(b)
	if b.source == "cc" then
		return "CC" .. b.code
	elseif b.source == "foot" then
		return "FS" .. b.code
	end
	return tostring(b.source) .. b.code
end
-- Short tag for a target row: its bound control, with a '*' if it's also the perf param,
-- or "PERF" when it's the perf param with no per-control binding; nil when unbound.
function M.tag(id)
	local b = binds[id]
	if b and b.source then
		return src_tag(b) .. (perf_id == id and "*" or "")
	end
	return perf_id == id and "PERF" or nil
end

-- ── persistence (flat string maps; see header) ──────────────────────────────
-- Pack a binding's shaping + encoder mode into the optional 5th field of param_bindings
-- ("sh=exp/inv/dz10/q8/lo0/hi80/pu/encS"); nil when there is nothing to record.
local function pack_shape(sh, enc)
	local parts = {}
	if sh then
		if sh.curve and sh.curve ~= "lin" then
			parts[#parts + 1] = sh.curve
		end
		if sh.invert then
			parts[#parts + 1] = "inv"
		end
		if (sh.deadzone or 0) > 0 then
			parts[#parts + 1] = "dz" .. math.floor(sh.deadzone * 100 + 0.5)
		end
		if (sh.quantize or 0) > 1 then
			parts[#parts + 1] = "q" .. math.floor(sh.quantize)
		end
		if (sh.lo or 0) ~= 0 then
			parts[#parts + 1] = "lo" .. math.floor(sh.lo * 100 + 0.5)
		end
		if (sh.hi or 1) ~= 1 then
			parts[#parts + 1] = "hi" .. math.floor(sh.hi * 100 + 0.5)
		end
		if sh.pickup then
			parts[#parts + 1] = "pu"
		end
	end
	if enc == "rel_signed" then
		parts[#parts + 1] = "encS"
	elseif enc == "rel_twos" then
		parts[#parts + 1] = "encT"
	end
	if #parts == 0 then
		return nil
	end
	return "sh=" .. table.concat(parts, "/")
end
local function parse_shape(field) -- "sh=..." -> sh table, enc string (or nils)
	local body = field and field:match("^sh=(.*)$")
	if not body then
		return nil, nil
	end
	local sh, enc = {}, nil
	for tok in (body .. "/"):gmatch("([^/]+)/") do -- "+" skips empty tokens
		if CURVES[tok] then
			sh.curve = tok
		elseif tok == "inv" then
			sh.invert = true
		elseif tok == "pu" then
			sh.pickup = true
		elseif tok == "encS" then
			enc = "rel_signed"
		elseif tok == "encT" then
			enc = "rel_twos"
		else
			local k, n = tok:match("^(%a+)(%d+)$")
			if k == "dz" then
				sh.deadzone = tonumber(n) / 100
			elseif k == "q" then
				sh.quantize = tonumber(n)
			elseif k == "lo" then
				sh.lo = tonumber(n) / 100
			elseif k == "hi" then
				sh.hi = tonumber(n) / 100
			end
		end
	end
	if not (sh.curve or sh.invert or sh.deadzone or sh.quantize or sh.lo or sh.hi or sh.pickup) then
		sh = nil
	end
	return sh, enc
end
-- Public aliases so modulation.lua (macros / routes) reuses the exact shaping grammar.
M.pack_shape = pack_shape
M.parse_shape = parse_shape

function M.export()
	local out = {}
	for id, b in pairs(binds) do
		if b.source then -- out-only entries are serialized by export_out()
			local s = b.source .. ":" .. b.code .. ":" .. b.mode
			local shp = pack_shape(b.sh, b.enc)
			if b.override or shp then
				s = s .. ":" .. (b.override or "") -- empty 4th field keeps the 5th positional
			end
			if shp then
				s = s .. ":" .. shp
			end
			out[id] = s
		end
	end
	return out
end
function M.export_out()
	local out = {}
	for id, b in pairs(binds) do
		if b.out then
			out[id] = b.out.kind .. ":" .. tostring(b.out.ch or 1) .. ":" .. tostring(b.out.num or 0)
		end
	end
	return out
end
function M.import(flat, perf_str, legacy_cc, out_flat, opts)
	binds = {}
	if type(legacy_cc) == "table" then -- migrate old CC-learn bindings ({cc -> id})
		for cc, id in pairs(legacy_cc) do
			if type(id) == "string" then
				binds[id] = { source = "cc", code = tostring(cc), mode = "abs" }
			end
		end
	end
	if type(flat) == "table" then -- authoritative param_bindings ({id -> "src:code:mode[:override]"})
		for id, spec in pairs(flat) do
			if type(spec) == "string" then
				local f = split(spec, ":")
				if f[1] and f[1] ~= "" and f[2] and f[2] ~= "" then
					local ov = (f[4] and f[4] ~= "" and VALID_MODE[f[4]]) and f[4] or nil
					local sh, enc = parse_shape(f[5]) -- optional 5th field; nil-safe
					binds[id] = {
						source = f[1],
						code = f[2],
						mode = f[3] ~= "" and f[3] or default_mode(f[1]),
						override = ov,
						sh = sh,
						enc = enc,
					}
				end
			end
		end
	end
	if type(out_flat) == "table" then -- MIDI-out dests ({id -> "kind:ch:num"})
		for id, spec in pairs(out_flat) do
			if type(spec) == "string" then
				local f = split(spec, ":")
				if f[1] and f[1] ~= "" and f[3] then
					local b = binds[id] or {}
					b.out = {
						kind = (f[1] == "note" and "note" or "cc"),
						ch = tonumber(f[2]) or 1,
						num = tonumber(f[3]) or 0,
					}
					binds[id] = b
				end
			end
		end
	end
	perf_id = (type(perf_str) == "string" and perf_str ~= "") and perf_str or nil
	if type(opts) == "table" then
		if opts.enabled ~= nil then
			enabled = opts.enabled and true or false
		end
		if opts.mode and VALID_MODE[opts.mode] then
			g_mode = opts.mode
		end
	end
	rebuild_rev()
end

return M
