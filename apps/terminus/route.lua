-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  route.lua — UI-side controller for engine-centric audio routing.

  A thin, draw-free wrapper over scripts/demod-route.sh: it reads the routable
  graph around the demod-rt engine (which SOURCE ports feed its input and which
  SINK ports its output feeds) and toggles stereo-pair connections via dm.exec.
  Consumed by the DSP Studio ROUTING screen (dsp/screens/routing.lua).

  When there's no engine / no `dm.exec` (the stub, or a plain dev host), graph()
  returns a small synthetic illustrative graph so the screen is still legible and
  the routing model is understandable, and connect/disconnect become no-ops.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local M = {}

local BASE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."
local BIN = os.getenv("DEMOD_ROUTE_BIN") or (BASE .. "/scripts/demod-route.sh")

-- POSIX shell single-quote (see SECURITY.md F-6/F-7): every port name that
-- reaches the shell is wrapped so a hostile client/port name can't inject.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- Does the host let us shell out at all? (false on the pure stub / headless tests)
function M.available()
	return dm ~= nil and dm.exec ~= nil
end

-- A small, honest-looking fake graph so the screen reads correctly with no rig.
-- `reason` tells the screen WHY it's synthetic: "preview" (stub/no shell),
-- "pwlink" (PipeWire's pw-link is missing), "engine" (rack not running).
local function synthetic(reason)
	return {
		eng = { input = false, output = false },
		cap = (reason ~= "pwlink"),
		synthetic = true,
		reason = reason or "preview",
		sources = {
			{
				label = "Microphone",
				portL = "system:capture_1",
				portR = "system:capture_2",
				connected = true,
				default = true,
			},
			{ label = "Media player", portL = "browser:output_FL", portR = "browser:output_FR", connected = false },
		},
		sinks = {
			{
				label = "Speakers",
				portL = "system:playback_1",
				portR = "system:playback_2",
				connected = true,
				default = true,
			},
			{ label = "Recorder", portL = "recorder:input_1", portR = "recorder:input_2", connected = false },
		},
	}
end

-- Split a `graph` row into tab-separated fields.
local function split_tab(line)
	local f = {}
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do
		f[#f + 1] = field
	end
	return f
end

-- Pure parser for demod-route.sh `graph` output. `lines` is any iterator of row
-- strings (a file:lines() handle, or an array via ipairs). Exposed as M._parse_graph
-- so it can be unit-tested without a rig (see spec/dsp/routing_spec.lua).
function M._parse_graph(lines)
	local g = { eng = { input = false, output = false }, cap = false, sources = {}, sinks = {} }
	for line in lines do
		local f = split_tab(line)
		if f[1] == "CAP" then
			g.cap = (f[2] == "1")
		elseif f[1] == "ENG" then
			g.eng.input = (f[2] == "1")
			g.eng.output = (f[3] == "1")
		elseif f[1] == "SRC" or f[1] == "SNK" then
			local row = {
				label = f[2],
				portL = f[3],
				portR = f[4],
				connected = (f[5] == "1"),
				default = (f[6] == "1"),
			}
			local bucket = (f[1] == "SRC") and g.sources or g.sinks
			bucket[#bucket + 1] = row
		end
	end
	return g
end

-- iterator over an array, so M._parse_graph can take a {string,...} as well as a
-- file handle's :lines() (used by tests and graph()).
local function array_lines(t)
	local i = 0
	return function()
		i = i + 1
		return t[i]
	end
end
M._array_lines = array_lines

-- { sources = {{label,portL,portR,connected,default}}, sinks = {...},
--   eng = {input,output}, cap, synthetic?, reason? }
-- opts.live=false (stub backend) → synthetic immediately (no fork). opts.monitors
-- → also list device monitor ports. Forks pw-link via the helper, so call ON DEMAND
-- (not per frame) and wrap in pcall: a blocking popen read can be EINTR'd when a
-- backgrounded child exits (same caveat as record.lua:recent_takes).
function M.graph(opts)
	opts = opts or {}
	if opts.live == false or not M.available() then
		return synthetic("preview")
	end
	local env = opts.monitors and "DEMOD_ROUTE_MONITORS=1 " or ""
	local g
	local ok = pcall(function()
		local p = io.popen(env .. "bash " .. shq(BIN) .. " graph 2>/dev/null")
		if not p then
			return
		end
		g = M._parse_graph(p:lines())
		p:close()
	end)
	if not ok or not g then
		return synthetic("engine")
	end
	if not g.cap then -- pw-link unavailable on this host
		return synthetic("pwlink")
	end
	if not (g.eng.input or g.eng.output) then -- rack not running
		return synthetic("engine")
	end
	return g
end

-- role: "source" | "sink". Fire-and-forget (the script tolerates already-wired).
function M.connect(role, portL, portR)
	if not M.available() then
		return false
	end
	dm.exec("bash " .. shq(BIN) .. " connect " .. shq(role) .. " " .. shq(portL) .. " " .. shq(portR or portL))
	return true
end

function M.disconnect(role, portL, portR)
	if not M.available() then
		return false
	end
	dm.exec("bash " .. shq(BIN) .. " disconnect " .. shq(role) .. " " .. shq(portL) .. " " .. shq(portR or portL))
	return true
end

return M
