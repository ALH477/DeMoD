-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/mixer_params.lua — per-slot mixer controls as negative-indexed pseudo-params.

  The mixer adds gain / pan / mute / solo to every slot. Rather than a parallel
  control path, these are addressed through the existing dsp.set_param/get_param
  contract using RESERVED NEGATIVE INDICES (real plugin params are 0..n-1, so the
  two never collide). The payoff: control_surface.register_target, automation
  capture, scenes, and macros all key on (slot, index) — so mixer faders become
  bindable / automatable / scene-capturable / macro-routable for free.

  Pure Lua, no `dm` dependency: shared by all three backends (the set_param branch)
  and the MIXER screen (the dB / pan-law helpers + the binding-target registrar).

  Honest serial-vs-parallel semantics live in the SCREEN + the engine, not here:
  this module is just the storage + math. mute on a serial FX insert is aliased to
  bypass by mixer.lua; solo is restricted to parallel (synth + master) strips.

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = {}

-- reserved pseudo-param indices (negative so they never hit s.params[idx+1])
M.GAIN = -101 -- linear amp, 0..1.5 (display as dB)
M.PAN = -102 -- -1 (L) .. 0 (C) .. +1 (R)
M.MUTE = -103 -- 0/1 toggle (>=0.5 = muted)
M.SOLO = -104 -- 0/1 toggle (>=0.5 = soloed)

-- per-index metadata: field name on the slot, range, step, default, unit
M.SPEC = {
	[M.GAIN] = { field = "gain", min = 0, max = 1.5, step = 0.02, default = 1.0, unit = "x", kind = "num" },
	[M.PAN] = { field = "pan", min = -1, max = 1, step = 0.02, default = 0.0, unit = "", kind = "num" },
	[M.MUTE] = { field = "mute", min = 0, max = 1, step = 1, default = false, unit = "", kind = "bool" },
	[M.SOLO] = { field = "solo", min = 0, max = 1, step = 1, default = false, unit = "", kind = "bool" },
}

-- the four controls in screen/registration order
M.ORDER = { M.GAIN, M.PAN, M.MUTE, M.SOLO }
M.SUFFIX = { [M.GAIN] = "gain", [M.PAN] = "pan", [M.MUTE] = "mute", [M.SOLO] = "solo" }

function M.is_mix(idx)
	return M.SPEC[idx] ~= nil
end

-- seed the four fields on a slot table (idempotent; only fills missing ones)
function M.init_slot(s)
	if not s then
		return
	end
	if s.gain == nil then
		s.gain = 1.0
	end
	if s.pan == nil then
		s.pan = 0.0
	end
	if s.mute == nil then
		s.mute = false
	end
	if s.solo == nil then
		s.solo = false
	end
end

-- write a pseudo-param onto a slot, clamping to range. Returns the stored value as a
-- NUMBER (so set_param's shadow stays uniform): bool fields store true/false but echo 1/0.
function M.apply(s, idx, value)
	local spec = M.SPEC[idx]
	if not (s and spec) then
		return nil
	end
	if spec.kind == "bool" then
		local on = (tonumber(value) or 0) >= 0.5
		s[spec.field] = on
		return on and 1 or 0
	end
	local v = math.max(spec.min, math.min(spec.max, tonumber(value) or spec.default))
	s[spec.field] = v
	return v
end

-- read a pseudo-param from a slot as a NUMBER (bool fields → 1/0), defaulting if unset
function M.read(s, idx)
	local spec = M.SPEC[idx]
	if not spec then
		return 0
	end
	local v = s and s[spec.field]
	if v == nil then
		v = spec.default
	end
	if spec.kind == "bool" then
		return v and 1 or 0
	end
	return v
end

-- ── audio-math helpers (used by the screen) ──────────────────────────────
function M.amp_to_db(g)
	g = tonumber(g) or 0
	if g <= 1e-4 then
		return -math.huge -- the screen renders this as "-INF"
	end
	return 20 * math.log(g, 10)
end

function M.db_to_amp(db)
	return 10 ^ ((tonumber(db) or 0) / 20)
end

-- constant-power pan law: pan -1..1 → (l, r) gains for a mono level. Equal-power at
-- centre (≈0.707 each), hard-L at -1, hard-R at +1. Used for the M0 UI-derived L/R
-- meter display before the engine publishes true per-channel peaks.
function M.pan_law(level, pan)
	level = tonumber(level) or 0
	local theta = ((tonumber(pan) or 0) + 1) * (math.pi / 4)
	return level * math.cos(theta), level * math.sin(theta)
end

-- canonical binding-target id for a slot's mixer control, matching the slotN.pM scheme
function M.canon_id(slot, idx)
	return "slot" .. slot .. "." .. (M.SUFFIX[idx] or "mix")
end

-- register the four mixer controls of every loaded slot as binding targets, so the
-- BINDINGS / MACROS / SCENES screens pick them up with no per-screen change. Mirrors
-- ctx.refresh_binding_targets()'s per-param loop. `dsp` + `bindings` are the live tables.
function M.register(dsp, bindings)
	if not (dsp and bindings and bindings.register_target) then
		return
	end
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if sl and sl.loaded then
			local nm = sl.name or "slot"
			for _, idx in ipairs(M.ORDER) do
				local spec = M.SPEC[idx]
				bindings.register_target(
					M.canon_id(i, idx),
					nm .. " " .. M.SUFFIX[idx],
					i,
					idx,
					spec.min,
					spec.max,
					spec.step
				)
			end
		end
	end
end

return M
