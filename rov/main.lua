-- SPDX-License-Identifier: MPL-2.0
-- DeMoD ROV — an AUV/ROV console on the companion-shell SDK. Surface<->sub link
-- over DCF/JANUS acoustic (upstream HydraMesh) or a sim. Bench/tank/sim first;
-- a proven autopilot (ArduSub) stays in the loop for real dives. MPL-2.0.
local APP   = os.getenv("DEMOD_ROV_DIR") or (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local SHELL = os.getenv("DEMOD_SHELL_DIR") or (APP:gsub("rov/?$", "") .. "shell/")
local function aload(f) return dofile(APP .. f) end

local shell = dofile(SHELL .. "shell.lua")
shell.run{
  title = "DeMoD ROV",
  palettes = aload("theme.lua"),
  config = {
    path = os.getenv("DEMOD_ROV_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/rov.lua"),
    keys = { "theme" }, defaults = { theme = "night" },
  },
  provider = function(cfg) return aload("provider.lua").new(cfg) end,
  surfaces = { aload("surfaces/dive.lua"), aload("surfaces/sonar.lua"), aload("surfaces/link.lua") },
  status = function(c) return (c.data.source or "") .. string.format("   %.1fm", c.data.depth or 0) end,
}
