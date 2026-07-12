-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/backend/select.lua — pick the DSP backend for this host.

  Order of resolution:
    1. $DEMOD_DSP_BACKEND = "local" | "orchestrator" | "stub"  (explicit override)
    2. /run/demod/control.sock exists                          -> "orchestrator"
    3. dm.local_available() true (demodoom_core linked in)     -> "local"
    4. fallback                                                -> "stub"

  Each backend module exposes new(base) returning the `dsp` contract table.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local function exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function choose()
	local forced = os.getenv("DEMOD_DSP_BACKEND")
	if forced and #forced > 0 then
		return forced:lower()
	end
	-- Honor the framework's control-socket override ($DEMOD_CONTROL_SOCK) so the
	-- orchestrator backend auto-selects on a desktop rig (socket under XDG_RUNTIME_DIR),
	-- not just at the device's fixed /run path.
	local sock = os.getenv("DEMOD_CONTROL_SOCK")
	if not (sock and #sock > 0) then
		sock = "/run/demod/control.sock"
	end
	if exists(sock) then
		return "orchestrator"
	end
	if dm.local_available and dm.local_available() then
		return "local"
	end
	return "stub"
end

-- base = directory of the dsp app (for dofile of sibling backend modules)
local function select(base)
	local name = choose()
	local path = base .. "/backend/" .. name .. ".lua"
	local f = io.open(path, "r")
	if not f then
		io.stderr:write("[dsp] backend '" .. name .. "' not found, using stub\n")
		name, path = "stub", base .. "/backend/stub.lua"
	else
		f:close()
	end
	local mod, dev_err
	local ok, result = pcall(dofile, path)
	if ok and result then
		mod = result
	else
		dev_err = tostring(result)
		io.stderr:write("[dsp] backend '" .. name .. "' module error, using stub: " .. dev_err .. "\n")
		name, path = "stub", base .. "/backend/stub.lua"
		mod = dofile(path)
	end
	local backend
	-- new(base) is a plain function, not a method — pass base as the FIRST arg.
	-- (Passing mod here made base = the module table, so orchestrator/local always
	-- errored on `dofile(base..)` and silently fell back to stub: real engine never
	-- got load_fx/set_param, so audio passed through with no audible effect.)
	ok, backend = pcall(mod.new, base)
	if not ok then
		io.stderr:write("[dsp] backend '" .. name .. "' init error: " .. tostring(backend) .. ", using stub\n")
		name, path = "stub", base .. "/backend/stub.lua"
		mod = dofile(path)
		backend = mod.new(base)
	end
	return backend, name
end

return { select = select }
