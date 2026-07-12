-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  midi/learn.lua — CC → target binding registry with a learn flow (pure, dm-free).

  The MIDI analogue of the gamepad remap (settings.lua GP_BUTTONS/apply_gamepad):
  the app registers named targets (each with an apply(value01) function); the user
  picks one and twists a knob; the next CC that arrives is bound to it. Thereafter
  every matching CC drives target.apply(value/127). Bindings serialize to a plain
  table so settings.lua can persist them.

  Bindings are keyed by CC number and match any channel by default (controllers are
  usually single-channel); a per-channel key is supported for stricter setups.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

local targets = {} -- ordered: { {id=, label=, apply=fn}, ... }
local target_by_id = {}
local bindings = {} -- key "cc" or "ch:cc" → target_id
local capturing = nil -- target_id awaiting the next CC, or nil

-- Register a learnable target. `apply` receives a normalized 0..1 value.
function M.register_target(id, label, apply)
	if target_by_id[id] then
		target_by_id[id].label = label or target_by_id[id].label
		target_by_id[id].apply = apply or target_by_id[id].apply
		return
	end
	local t = { id = id, label = label or id, apply = apply }
	targets[#targets + 1] = t
	target_by_id[id] = t
end

function M.targets()
	return targets
end

-- Arm learn: the next incoming CC binds to this target. Pass nil to cancel.
function M.begin_learn(target_id)
	capturing = target_id
end
function M.is_learning()
	return capturing ~= nil
end
function M.learning_target()
	return capturing
end

local function key_for(ch, cc, channel_aware)
	if channel_aware then
		return tostring(ch) .. ":" .. tostring(cc)
	end
	return tostring(cc)
end

-- Router hands every CC here. Returns "learned"/"applied"/nil.
--   ev = { ch=1..16, cc=0..127, value=0..127, valuef=0..1 }
function M.handle_cc(ev)
	if capturing then
		bindings[key_for(ev.ch, ev.cc, false)] = capturing
		local id = capturing
		capturing = nil
		return "learned", id
	end
	local id = bindings[key_for(ev.ch, ev.cc, true)] or bindings[key_for(ev.ch, ev.cc, false)]
	if id then
		local t = target_by_id[id]
		if t and t.apply then
			t.apply(ev.valuef, ev)
			return "applied", id
		end
	end
	return nil
end

-- The CC currently bound to a target (for display), or nil.
function M.binding_for(target_id)
	for k, id in pairs(bindings) do
		if id == target_id then
			return k
		end
	end
	return nil
end

function M.clear(target_id)
	for k, id in pairs(bindings) do
		if id == target_id then
			bindings[k] = nil
		end
	end
end

-- Serialization for settings.lua persistence.
function M.get_bindings()
	local out = {}
	for k, v in pairs(bindings) do
		out[k] = v
	end
	return out
end
function M.set_bindings(tbl)
	bindings = {}
	if type(tbl) == "table" then
		for k, v in pairs(tbl) do
			bindings[tostring(k)] = v
		end
	end
end

return M
