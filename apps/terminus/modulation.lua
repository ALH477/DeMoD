-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  modulation.lua — the shared modulation layer on top of control_surface.lua.

  Loaded by both shells (sibling of control_surface.lua / midi/). Pure / dm-free, so it
  stays busted-testable. It NEVER touches MIDI or dsp directly — it calls back into the
  control surface through the injected handle (cs.apply_to_target / cs.value01 / cs.shape /
  cs.pack_shape / cs.parse_shape), so every value it produces rides the same write()
  chokepoint (param + echo-safe MIDI-out).

  Phase 2 — MACROS: one control fans out to many params, each target with its own shaping
  (range/curve/invert). A macro may be driven by a physical CC (its own reverse map, so it
  never collides with the surface's one-to-one binds) or set directly from the MACROS screen.

  (Phases 3/4 — LFO/env/step modulation sources and scene morphing — extend this module.)

  Persistence (flat string maps; ride settings.lua's string->string persister unchanged):
      cs_macros       = { ["macro1"] = "Filter:cc:21" }   -- label:driver-source:driver-code
      cs_macro_routes = { ["macro1"] = "slot1.p0=exp/inv/lo0/hi80;slot2.p1=lin" }

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

local cs -- the control_surface handle (apply_to_target / value01 / shape / pack_shape / parse_shape)

local macros = {} -- id -> { id, label, value01, driver={source,code}|nil, routes={ {target,sh}, ... } }
local order = {} -- ordered macro ids (stable display order)
local macro_rev = {} -- "source:code" -> macro id (driver reverse lookup)

function M.attach(control_surface)
	cs = control_surface
	-- a manual (non-mod) write to a modulated target rebases its LFO center (see Phase 3).
	if cs and cs.set_rebase then
		cs.set_rebase(function(id, v01)
			for _, r in ipairs(M._routes()) do
				if r.target == id then
					r.base = v01
				end
			end
		end)
	end
end

local function rebuild_macro_rev()
	macro_rev = {}
	for id, mac in pairs(macros) do
		if mac.driver then
			macro_rev[mac.driver.source .. ":" .. tostring(mac.driver.code)] = id
		end
	end
end

-- ── macro registry ───────────────────────────────────────────────────────────
function M.macros() -- ordered list
	local out = {}
	for _, id in ipairs(order) do
		out[#out + 1] = macros[id]
	end
	return out
end
function M.macro(id)
	return macros[id]
end
function M.macro_count()
	return #order
end

-- allocate the next free "macroN" id
function M.next_macro_id()
	local n = 1
	while macros["macro" .. n] do
		n = n + 1
	end
	return "macro" .. n
end

function M.macro_new(id, label)
	id = id or M.next_macro_id()
	if not macros[id] then
		macros[id] = { id = id, label = label or id, value01 = 0, routes = {} }
		order[#order + 1] = id
	end
	return macros[id]
end
function M.macro_remove(id)
	if not macros[id] then
		return
	end
	macros[id] = nil
	for i, v in ipairs(order) do
		if v == id then
			table.remove(order, i)
			break
		end
	end
	rebuild_macro_rev()
end
function M.macro_set_label(id, label)
	local mac = macros[id]
	if mac then
		mac.label = tostring(label or mac.id):gsub(":", " ") -- colon is the persistence separator
	end
end

-- driver: an optional physical control that sweeps the macro knob
function M.macro_set_driver(id, source, code)
	local mac = macros[id]
	if not mac then
		return
	end
	-- one control drives one macro: drop any other macro already on this (source,code)
	local key = source .. ":" .. tostring(code)
	local prev = macro_rev[key]
	if prev and prev ~= id and macros[prev] then
		macros[prev].driver = nil
	end
	mac.driver = { source = source, code = code }
	rebuild_macro_rev()
end
function M.macro_clear_driver(id)
	local mac = macros[id]
	if mac then
		mac.driver = nil
		rebuild_macro_rev()
	end
end

-- ── routes (one->many) ───────────────────────────────────────────────────────
function M.macro_add_route(id, target_id, sh)
	local mac = macros[id]
	if not mac then
		return
	end
	for _, r in ipairs(mac.routes) do
		if r.target == target_id then -- already routed: just refresh shaping
			r.sh = sh
			return r
		end
	end
	local r = { target = target_id, sh = sh }
	mac.routes[#mac.routes + 1] = r
	return r
end
function M.macro_remove_route(id, idx)
	local mac = macros[id]
	if mac and mac.routes[idx] then
		table.remove(mac.routes, idx)
	end
end
function M.macro_routes(id)
	local mac = macros[id]
	return mac and mac.routes or {}
end

-- ── apply (the fan-out) ──────────────────────────────────────────────────────
-- Drive the macro: each route shapes the macro value into its own range/curve and writes
-- through the control surface (param + echo-safe MIDI-out per target).
function M.macro_set(id, v01)
	local mac = macros[id]
	if not (mac and cs) then
		return
	end
	v01 = v01 < 0 and 0 or (v01 > 1 and 1 or v01)
	mac.value01 = v01
	for _, r in ipairs(mac.routes) do
		cs.apply_to_target(r.target, cs.shape(v01, r.sh))
	end
end
function M.macro_value(id)
	local mac = macros[id]
	return mac and mac.value01 or 0
end

-- driver learn: arm "the next CC becomes this macro's driver"
local capturing_driver = nil
function M.begin_assign_driver(id)
	capturing_driver = id
end
function M.is_assigning_driver()
	return capturing_driver ~= nil
end
function M.cancel_assign_driver()
	capturing_driver = nil
end

-- Called by the shells' on_cc / footswitch ladder alongside cs.feed. A CC sweeps the macro
-- continuously; a footswitch (discrete) toggles it between 0 and 1. Returns true if consumed.
function M.feed(source, code, value)
	if capturing_driver then
		if source == "cc" or source == "foot" then
			local id = capturing_driver
			capturing_driver = nil
			M.macro_set_driver(id, source, code)
			return true
		end
		return true -- swallow other events while arming the driver
	end
	local id = macro_rev[source .. ":" .. tostring(code)]
	if not id then
		return false
	end
	if source == "foot" then
		M.macro_set(id, (M.macro_value(id) >= 0.5) and 0 or 1) -- discrete: toggle
		return true
	elseif value ~= nil then
		M.macro_set(id, value)
		return true
	end
	return false
end

-- ── persistence ──────────────────────────────────────────────────────────────
-- route shaping reuses the control-surface shape grammar, minus the "sh=" prefix.
local function pack_route_shape(sh)
	if not (cs and cs.pack_shape) then
		return "lin"
	end
	local p = cs.pack_shape(sh, nil)
	return p and (p:gsub("^sh=", "")) or "lin"
end
local function parse_route_shape(pkt)
	if not (cs and cs.parse_shape) or not pkt or pkt == "lin" then
		return nil
	end
	local sh = cs.parse_shape("sh=" .. pkt)
	return sh
end

function M.export_macros()
	local out = {}
	for id, mac in pairs(macros) do
		local d = mac.driver
		out[id] = (mac.label or id):gsub(":", " ")
			.. ":"
			.. (d and d.source or "")
			.. ":"
			.. (d and tostring(d.code) or "")
	end
	return out
end
function M.export_macro_routes()
	local out = {}
	for id, mac in pairs(macros) do
		if #mac.routes > 0 then
			local parts = {}
			for _, r in ipairs(mac.routes) do
				parts[#parts + 1] = r.target .. "=" .. pack_route_shape(r.sh)
			end
			out[id] = table.concat(parts, ";")
		end
	end
	return out
end

function M.import_macros(macros_flat, routes_flat)
	macros, order, macro_rev = {}, {}, {}
	if type(macros_flat) == "table" then
		for id, spec in pairs(macros_flat) do
			if type(spec) == "string" then
				local label, src, code = spec:match("^(.-):([^:]*):([^:]*)$")
				local mac = { id = id, label = (label ~= "" and label) or id, value01 = 0, routes = {} }
				if src ~= "" and code ~= "" then
					mac.driver = { source = src, code = code }
				end
				macros[id] = mac
				order[#order + 1] = id
			end
		end
	end
	if type(routes_flat) == "table" then
		for id, spec in pairs(routes_flat) do
			local mac = macros[id]
			if mac and type(spec) == "string" then
				for pair in (spec .. ";"):gmatch("([^;]+);") do
					local target, pkt = pair:match("^([^=]+)=(.*)$")
					if target then
						mac.routes[#mac.routes + 1] = { target = target, sh = parse_route_shape(pkt) }
					end
				end
			end
		end
	end
	table.sort(order)
	rebuild_macro_rev()
end

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 3 — modulation sources (LFO / envelope-follower / step) + routes.
-- Sources generate a value each frame; routes write base + depth*signal through the
-- control surface (apply_mod = no rebase). LFOs sync to the MIDI clock; the env-follower
-- reads the live meters; everything rides the same write() chokepoint, so a modulated
-- param also emits MIDI out, throttled by the eval rate + the surface's 1/127 dedup.
-- ════════════════════════════════════════════════════════════════════════════

local sources = {} -- sid -> { id, kind="lfo"|"env"|"step", label, ...cfg..., _phase, _val, _shval, _idx }
local src_order = {}
local mod_routes = {} -- list of { src=sid, target=id, depth=0..1, sh, base }
local clock_h, meters_fn
local eval_accum = 0
local EVAL_DT = 1 / 60 -- evaluate the modulation graph at ~60 Hz (bounds CPU + MIDI-out rate)
local HIST_N = 72 -- samples kept per source for the live scrolling scope
local TWO_PI = math.pi * 2
local LFO_SHAPES = { "sine", "tri", "ramp", "square", "sh" }
local DIVS = { "1/1", "1/2", "1/4", "1/8", "1/16", "1/4t", "1/8t" }

function M._routes() -- exposed for the rebase closure in attach()
	return mod_routes
end
local function clamp01(v)
	return v < 0 and 0 or (v > 1 and 1 or v)
end

function M.attach_clock(clock)
	clock_h = clock
	if clock then
		if clock.on_step then
			clock.on_step(function(step)
				M.on_step(step)
			end)
		end
		if clock.on_transport then
			clock.on_transport(function(kind)
				M.on_transport(kind)
			end)
		end
	end
end
function M.attach_meters(fn)
	meters_fn = fn
end
function M.set_eval_rate(hz)
	EVAL_DT = (hz and hz > 0) and (1 / hz) or EVAL_DT
end

-- ── sources CRUD ─────────────────────────────────────────────────────────────
function M.sources()
	local out = {}
	for _, id in ipairs(src_order) do
		out[#out + 1] = sources[id]
	end
	return out
end
function M.source(id)
	return sources[id]
end
-- scrolling scope history (0..1 display samples) for a source; {} until it has run.
function M.history(id)
	local s = sources[id]
	return (s and s._hist) or {}
end
-- short tag for what (if anything) is driving a param target: "LFO", "MAC", "LFO+MAC", nil.
function M.target_info(target)
	local lfo, mac = false, false
	for _, r in ipairs(mod_routes) do
		if r.target == target then
			lfo = true
			break
		end
	end
	for _, id in ipairs(order) do
		for _, r in ipairs(macros[id].routes) do
			if r.target == target then
				mac = true
				break
			end
		end
		if mac then
			break
		end
	end
	if lfo and mac then
		return "LFO+MAC"
	end
	return lfo and "LFO" or (mac and "MAC" or nil)
end
function M.next_source_id(kind)
	local n = 1
	while sources[(kind or "lfo") .. n] do
		n = n + 1
	end
	return (kind or "lfo") .. n
end
function M.source_new(id, kind, cfg)
	kind = kind or "lfo"
	id = id or M.next_source_id(kind)
	local s = { id = id, kind = kind, label = id, _phase = 0, _val = 0 }
	if kind == "lfo" then
		s.shape, s.sync, s.div, s.rate_hz, s.depth, s.bipolar = "sine", true, "1/4", 1.0, 1.0, true
	elseif kind == "env" then
		s.slot, s.attack, s.release, s.gain = 1, 10, 120, 1.0
	elseif kind == "step" then
		s.steps = { 0, 0.5, 1.0, 0.5 }
		s._idx = 1
	end
	for k, v in pairs(cfg or {}) do
		s[k] = v
	end
	if not sources[id] then
		src_order[#src_order + 1] = id
	end
	sources[id] = s
	return s
end
function M.source_remove(id)
	if not sources[id] then
		return
	end
	sources[id] = nil
	for i, v in ipairs(src_order) do
		if v == id then
			table.remove(src_order, i)
			break
		end
	end
	-- drop its routes (and unmark targets no longer modulated)
	for i = #mod_routes, 1, -1 do
		if mod_routes[i].src == id then
			local tgt = mod_routes[i].target
			table.remove(mod_routes, i)
			if cs and cs.mark_modulated and not M.target_modulated(tgt) then
				cs.mark_modulated(tgt, false)
			end
		end
	end
end

-- ── routes CRUD ──────────────────────────────────────────────────────────────
function M.target_modulated(target)
	for _, r in ipairs(mod_routes) do
		if r.target == target then
			return true
		end
	end
	return false
end
function M.routes_of(src)
	local out = {}
	for _, r in ipairs(mod_routes) do
		if r.src == src then
			out[#out + 1] = r
		end
	end
	return out
end
function M.route_add(src, target, depth, sh)
	for _, r in ipairs(mod_routes) do
		if r.src == src and r.target == target then
			r.depth, r.sh = depth or r.depth, sh
			return r
		end
	end
	local r = { src = src, target = target, depth = depth or 1.0, sh = sh, base = cs and cs.value01(target) or 0 }
	mod_routes[#mod_routes + 1] = r
	if cs and cs.mark_modulated then
		cs.mark_modulated(target, true)
	end
	return r
end
function M.route_remove(src, target)
	for i = #mod_routes, 1, -1 do
		if mod_routes[i].src == src and mod_routes[i].target == target then
			table.remove(mod_routes, i)
			if cs and cs.mark_modulated and not M.target_modulated(target) then
				cs.mark_modulated(target, false)
			end
			return
		end
	end
end

-- ── evaluation ───────────────────────────────────────────────────────────────
local function div_beats(div) -- note division -> period in beats (quarter = 1 beat)
	local a, b, t = div:match("^(%d+)/(%d+)(t?)$")
	a, b = tonumber(a) or 1, tonumber(b) or 4
	local beats = 4 * a / b
	if t == "t" then
		beats = beats * 2 / 3 -- triplet
	end
	return beats
end
local function lfo_hz(s)
	if s.sync and clock_h and clock_h.bpm then
		local bpm = clock_h.bpm() or 120
		local beats = div_beats(s.div or "1/4")
		return (bpm / 60) / math.max(0.0001, beats)
	end
	return s.rate_hz or 1.0
end
local function lfo_raw(shape, ph) -- -1..1
	if shape == "sine" then
		return math.sin(TWO_PI * ph)
	elseif shape == "tri" then
		return 4 * math.abs(ph - 0.5) - 1
	elseif shape == "ramp" then
		return 2 * ph - 1
	elseif shape == "square" then
		return ph < 0.5 and 1 or -1
	end
	return 0
end

-- Advance every source by dt and write all routes. Called each frame by both shells.
function M.update(dt)
	eval_accum = eval_accum + (dt or 0)
	if eval_accum < EVAL_DT then
		return
	end
	local d = eval_accum
	eval_accum = 0
	for _, sid in ipairs(src_order) do
		local s = sources[sid]
		if s.kind == "lfo" then
			if s.shape == "sh" then
				s._val = (s._shval or 0) * (s.depth or 1) -- held; refreshed on clock step
			else
				s._phase = (s._phase + d * lfo_hz(s)) % 1
				local raw = lfo_raw(s.shape, s._phase)
				local sig = s.bipolar and raw or (raw + 1) / 2
				s._val = sig * (s.depth or 1) -- source depth is the signal amplitude
			end
		elseif s.kind == "env" then
			local lvl = 0
			if meters_fn then
				local m = meters_fn()
				lvl = (type(m) == "table" and (m[s.slot] or 0)) or 0
			end
			local tgt = clamp01(lvl * (s.gain or 1))
			local ms = (tgt > (s._val or 0)) and (s.attack or 10) or (s.release or 120)
			local coef = 1 - math.exp(-d / math.max(0.001, ms / 1000))
			s._val = (s._val or 0) + (tgt - (s._val or 0)) * coef
		end
		-- step sources hold _val between clock steps (set in on_step)
		-- push the display value into the scrolling scope history (0..1)
		local disp = clamp01(s.bipolar and ((s._val or 0) + 1) / 2 or (s._val or 0))
		local h = s._hist or {}
		h[#h + 1] = disp
		while #h > HIST_N do
			table.remove(h, 1)
		end
		s._hist = h
	end
	if not cs then
		return
	end
	for _, r in ipairs(mod_routes) do
		local s = sources[r.src]
		if s then
			if r.base == nil then
				r.base = cs.value01(r.target)
			end
			local out = clamp01((r.base or 0) + (r.depth or 1) * (s._val or 0))
			cs.apply_mod(r.target, cs.shape(out, r.sh))
		end
	end
	M.seq_tick(d) -- advance the tempo-synced scene sequencer (Phase 4)
end

function M.on_step(_)
	for _, sid in ipairs(src_order) do
		local s = sources[sid]
		if s.kind == "lfo" and s.shape == "sh" then
			local r = math.random() * 2 - 1
			s._shval = s.bipolar and r or (r + 1) / 2
		elseif s.kind == "step" and s.steps and #s.steps > 0 then
			s._idx = (s._idx % #s.steps) + 1
			s._val = s.steps[s._idx]
		end
	end
end
function M.on_transport(kind)
	if kind == "start" then
		for _, sid in ipairs(src_order) do
			local s = sources[sid]
			s._phase = 0
			if s.kind == "step" then
				s._idx = 1
			end
		end
	end
end

-- ── persistence ──────────────────────────────────────────────────────────────
function M.export_sources()
	local out = {}
	for id, s in pairs(sources) do
		if s.kind == "lfo" then
			out[id] = table.concat({
				"lfo",
				s.shape or "sine",
				s.sync and "sync" or "free",
				"div=" .. ((s.div or "1/4"):gsub("/", "-")),
				"hz" .. string.format("%.3g", s.rate_hz or 1),
				"depth" .. math.floor((s.depth or 1) * 100 + 0.5),
				s.bipolar and "bipol" or "uni",
			}, ":")
		elseif s.kind == "env" then
			out[id] = table.concat({
				"env",
				"slot" .. tostring(s.slot or 1),
				"atk" .. math.floor(s.attack or 10),
				"rel" .. math.floor(s.release or 120),
				"gain" .. math.floor((s.gain or 1) * 100 + 0.5),
			}, ":")
		elseif s.kind == "step" then
			local v = {}
			for _, x in ipairs(s.steps or {}) do
				v[#v + 1] = math.floor(x * 100 + 0.5)
			end
			out[id] = "step:" .. table.concat(v, "-")
		end
	end
	return out
end
function M.export_mod_routes()
	local out = {}
	for _, r in ipairs(mod_routes) do
		local pkt = pack_route_shape(r.sh) .. "@depth" .. math.floor((r.depth or 1) * 100 + 0.5)
		out[r.src] = (out[r.src] and (out[r.src] .. ";") or "") .. r.target .. "=" .. pkt
	end
	return out
end
function M.import_sources(src_flat, route_flat)
	sources, src_order, mod_routes = {}, {}, {}
	if type(src_flat) == "table" then
		for id, spec in pairs(src_flat) do
			if type(spec) == "string" then
				local kind = spec:match("^(%a+):")
				if kind == "lfo" then
					local s = M.source_new(id, "lfo", {})
					s.shape = spec:match(":(%a+):") or "sine"
					s.sync = spec:match(":sync:") ~= nil or spec:match(":sync$") ~= nil
					local div = spec:match("div=([%dt%-]+)")
					s.div = div and div:gsub("%-", "/") or "1/4"
					s.rate_hz = tonumber(spec:match("hz([%d%.]+)")) or 1
					s.depth = (tonumber(spec:match("depth(%d+)")) or 100) / 100
					s.bipolar = spec:match("bipol") ~= nil
				elseif kind == "env" then
					local s = M.source_new(id, "env", {})
					s.slot = tonumber(spec:match("slot(%d+)")) or 1
					s.attack = tonumber(spec:match("atk(%d+)")) or 10
					s.release = tonumber(spec:match("rel(%d+)")) or 120
					s.gain = (tonumber(spec:match("gain(%d+)")) or 100) / 100
				elseif kind == "step" then
					local s = M.source_new(id, "step", {})
					local steps = {}
					for v in (spec:match("^step:(.*)$") or ""):gmatch("([^%-]+)") do
						steps[#steps + 1] = (tonumber(v) or 0) / 100
					end
					if #steps > 0 then
						s.steps = steps
					end
				end
			end
		end
	end
	if type(route_flat) == "table" then
		for src, spec in pairs(route_flat) do
			if sources[src] and type(spec) == "string" then
				for pair in (spec .. ";"):gmatch("([^;]+);") do
					local target, body = pair:match("^([^=]+)=(.*)$")
					if target then
						local depth = (tonumber(body:match("@depth(%d+)")) or 100) / 100
						local pkt = body:gsub("@depth%d+", "")
						M.route_add(src, target, depth, parse_route_shape(pkt))
					end
				end
			end
		end
	end
	table.sort(src_order)
end

M.LFO_SHAPES = LFO_SHAPES
M.DIVS = DIVS

-- ════════════════════════════════════════════════════════════════════════════
-- Phase 4 — scene morphing: capture param snapshots (as 0..1 values), then crossfade
-- between two of them with one control. Each interpolated param writes through the
-- surface (apply_to_target -> write), so morphing also emits MIDI out, echo-safe.
-- ════════════════════════════════════════════════════════════════════════════

local scenes = {} -- name -> { target_id -> value01 }
local scene_order = {}
local morph = { a = nil, b = nil, pos = 0, driver = nil } -- driver = {source,code}|nil
local capturing_morph = nil -- "next CC becomes the morph driver" when set

function M.scenes()
	return scene_order
end
function M.scene(name)
	return scenes[name]
end
function M.scene_count()
	return #scene_order
end

-- Snapshot the current value of every registered control-surface target into a scene.
function M.scene_capture(name)
	if not (cs and cs.target_ids and name and name ~= "") then
		return
	end
	local snap = {}
	for _, id in ipairs(cs.target_ids()) do
		snap[id] = cs.value01(id)
	end
	if not scenes[name] then
		scene_order[#scene_order + 1] = name
	end
	scenes[name] = snap
	return snap
end
function M.scene_remove(name)
	if not scenes[name] then
		return
	end
	scenes[name] = nil
	for i, v in ipairs(scene_order) do
		if v == name then
			table.remove(scene_order, i)
			break
		end
	end
	if morph.a == name then
		morph.a = nil
	end
	if morph.b == name then
		morph.b = nil
	end
end

function M.set_morph(a, b)
	morph.a, morph.b = a, b
end
function M.morph()
	return morph
end
-- Crossfade A->B at pos 0..1 and write every shared param through the control surface.
function M.morph_set_pos(pos)
	morph.pos = pos < 0 and 0 or (pos > 1 and 1 or pos)
	local A, B = scenes[morph.a], scenes[morph.b]
	if not (A and B and cs) then
		return
	end
	for id, va in pairs(A) do
		local vb = B[id]
		if vb ~= nil then
			cs.apply_to_target(id, va + (vb - va) * morph.pos)
		end
	end
end

-- morph driver (a CC sweeps the morph position)
function M.morph_set_driver(source, code)
	morph.driver = { source = source, code = code }
end
function M.morph_clear_driver()
	morph.driver = nil
end
function M.begin_assign_morph()
	capturing_morph = true
end
function M.is_assigning_morph()
	return capturing_morph == true
end
function M.cancel_assign_morph()
	capturing_morph = nil
end
-- Called by the shells' on_cc / footswitch ladder (after macro feed). A CC sweeps the morph
-- position; a footswitch toggles between scene A (0) and B (1). Returns true if consumed.
function M.feed_morph(source, code, value)
	if capturing_morph then
		if source == "cc" or source == "foot" then
			capturing_morph = nil
			M.morph_set_driver(source, code)
			return true
		end
		return true
	end
	local d = morph.driver
	if d and d.source == source and tostring(d.code) == tostring(code) then
		if source == "foot" then
			M.morph_set_pos((morph.pos or 0) >= 0.5 and 0 or 1) -- discrete: snap A<->B
			return true
		elseif value ~= nil then
			M.morph_set_pos(value)
			return true
		end
	end
	return false
end

function M.export_scenes()
	local out = {}
	for name, snap in pairs(scenes) do
		local parts = {}
		for id, v in pairs(snap) do
			parts[#parts + 1] = id .. "=" .. math.floor(v * 100 + 0.5)
		end
		out[name] = table.concat(parts, ";")
	end
	return out
end
function M.export_morph()
	local out = {}
	if morph.a and morph.b then
		out.pair = morph.a .. ":" .. morph.b
	end
	if morph.driver then
		out.driver = morph.driver.source .. ":" .. tostring(morph.driver.code)
	end
	return out
end
function M.import_scenes(scenes_flat, morph_flat)
	scenes, scene_order = {}, {}
	morph = { a = nil, b = nil, pos = 0, driver = nil }
	if type(scenes_flat) == "table" then
		for name, spec in pairs(scenes_flat) do
			if type(spec) == "string" then
				local snap = {}
				for pair in (spec .. ";"):gmatch("([^;]+);") do
					local id, v = pair:match("^([^=]+)=(%d+)$")
					if id then
						snap[id] = (tonumber(v) or 0) / 100
					end
				end
				scenes[name] = snap
				scene_order[#scene_order + 1] = name
			end
		end
		table.sort(scene_order)
	end
	if type(morph_flat) == "table" then
		if type(morph_flat.pair) == "string" then
			morph.a, morph.b = morph_flat.pair:match("^([^:]+):([^:]+)$")
		end
		if type(morph_flat.driver) == "string" then
			local sc, cc = morph_flat.driver:match("^([^:]+):([^:]+)$")
			if sc then
				morph.driver = { source = sc, code = cc }
			end
		end
	end
end

-- ── tempo-synced scene sequencer: auto-crossfade through every captured scene in order,
-- one transition per clock division, looping. Drives the morph (a/b/pos) on each tick. ──
local seq = { on = false, div = "1/1", _phase = 0, _idx = 1 }
function M.seq()
	return seq
end
function M.seq_toggle()
	seq.on = not seq.on
	if seq.on then
		seq._phase, seq._idx = 0, 1
	end
	return seq.on
end
function M.seq_set_div(div)
	seq.div = div
end
function M.seq_tick(dt)
	if not (seq.on and cs) then
		return
	end
	local list = scene_order
	local n = #list
	if n < 2 then
		return -- need at least two scenes to crossfade
	end
	seq._idx = ((seq._idx - 1) % n) + 1
	local hz = (clock_h and clock_h.bpm) and ((clock_h.bpm() or 120) / 60) / math.max(0.0001, div_beats(seq.div))
		or (1 / math.max(0.1, div_beats(seq.div)))
	seq._phase = seq._phase + (dt or 0) * hz
	while seq._phase >= 1 do
		seq._phase = seq._phase - 1
		seq._idx = (seq._idx % n) + 1
	end
	M.set_morph(list[seq._idx], list[(seq._idx % n) + 1])
	M.morph_set_pos(seq._phase)
end
function M.export_seq()
	return { enabled = seq.on and "1" or "0", div = seq.div }
end
function M.import_seq(t)
	seq._phase, seq._idx = 0, 1
	if type(t) == "table" then
		seq.on = t.enabled == "1"
		if type(t.div) == "string" and t.div ~= "" then
			seq.div = t.div
		end
	else
		seq.on = false
	end
end

-- ── performance focus (the gamepad "Param Up/Down/Toggle" + encoder grab can sweep a
-- macro or the morph hands-free, parallel to the control-surface perf param) ─────────
local perf_focus = nil -- { kind = "macro"|"morph", id = <macroId> } or nil
function M.set_perf(kind, id)
	if kind == "macro" and macros[id] then
		perf_focus = { kind = "macro", id = id }
	elseif kind == "morph" then
		perf_focus = { kind = "morph" }
	else
		perf_focus = nil
	end
end
function M.clear_perf()
	perf_focus = nil
end
function M.perf()
	return perf_focus
end
-- is this macro / the morph the current perf focus?
function M.is_perf(kind, id)
	if not perf_focus or perf_focus.kind ~= kind then
		return false
	end
	return kind ~= "macro" or perf_focus.id == id
end
function M.perf_apply(dir)
	if not perf_focus then
		return
	end
	local step = (dir or 0) >= 0 and 0.05 or -0.05
	if perf_focus.kind == "macro" then
		M.macro_set(perf_focus.id, clamp01(M.macro_value(perf_focus.id) + step))
	else
		M.morph_set_pos(clamp01((morph.pos or 0) + step))
	end
end
function M.perf_toggle()
	if not perf_focus then
		return
	end
	if perf_focus.kind == "macro" then
		M.macro_set(perf_focus.id, (M.macro_value(perf_focus.id) >= 0.5) and 0 or 1)
	else
		M.morph_set_pos((morph.pos or 0) >= 0.5 and 0 or 1)
	end
end
function M.export_perf()
	if not perf_focus then
		return ""
	end
	return perf_focus.kind == "macro" and ("macro:" .. perf_focus.id) or "morph"
end
function M.import_perf(str)
	perf_focus = nil
	if type(str) == "string" then
		if str == "morph" then
			perf_focus = { kind = "morph" }
		else
			local id = str:match("^macro:(.+)$")
			if id then
				perf_focus = { kind = "macro", id = id }
			end
		end
	end
end

return M
