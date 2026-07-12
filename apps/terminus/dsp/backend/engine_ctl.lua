-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/backend/engine_ctl.lua — a minimal demod-rt control-socket client.

  The orchestrator backend (orchestrator.lua) keeps its own inline copy of this
  protocol for the full DSP Studio UI; THIS module is the small standalone client
  Home (home.lua) uses to load a patch into the background engine WITHOUT spinning up
  the whole rack GUI. Same JSON-lines envelope ({"v":1,"id":..,"op":..,<args>}) over
  the dm.ctl escape hatch, same resolve_fx_path (abs .so path passthrough; stock alias).
  No-ops gracefully (returns false) when dm.ctl is absent (desktop dev / no socket).

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = {}

function M.available()
	return (dm and dm.ctl) and true or false
end

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

local seq = 0
local warned = {}
local function ctl(op, args)
	if not (dm and dm.ctl) then
		return false
	end
	seq = seq + 1
	local s = '{"v":1,"id":' .. jstr("home-" .. seq) .. ',"op":' .. jstr(op)
	for _, kv in ipairs(args or {}) do
		s = s .. "," .. jstr(kv[1]) .. ":" .. jval(kv[2])
	end
	local ok = dm.ctl(s .. "}")
	if ok == false and not warned[op] then
		warned[op] = true
		io.stderr:write("[engine_ctl] control op '" .. op .. "' failed (further warnings suppressed)\n")
	end
	return ok
end
M.ctl = ctl

-- Resolve a name/path to an engine-loadable plugin: an existing absolute .so (a patch's
-- own artifact) passes through; a bare stem maps into DEMOD_LIBRARY_DIR/demod_<stem>.so.
local STOCK_ALIAS = { compress = "compressor", synth = "synth_fm" }
local LIBDIR = os.getenv("DEMOD_LIBRARY_DIR")
function M.resolve_fx_path(p)
	if not p or p == "" then
		return ""
	end
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

-- slots are 1-based here (UI convention); the wire is 0-based.
function M.load_fx(slot, path)
	return ctl("load_fx", { { "slot", slot - 1 }, { "path", M.resolve_fx_path(path) } })
end
function M.unload_fx(slot)
	return ctl("unload_fx", { { "slot", slot - 1 } })
end
function M.bypass_fx(slot, on)
	return ctl("bypass_fx", { { "slot", slot - 1 }, { "on", on and true or false } })
end
function M.set_param(slot, idx, value)
	return ctl("set_param", { { "slot", slot - 1 }, { "idx", idx }, { "value", value } })
end

return M
