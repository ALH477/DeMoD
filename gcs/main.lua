-- SPDX-License-Identifier: MPL-2.0
-- DeMoD GCS — a drone ground-control station on the companion-shell SDK. It
-- talks to a real PX4/ArduPilot FC over MAVLink (via a bridge writing the
-- telemetry KV file); the FC flies, DeMoD is the companion/GCS, never the
-- safety-critical loop (see docs/vehicle-feasibility.md). MPL-2.0.
local APP   = os.getenv("DEMOD_GCS_DIR") or (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local SHELL = os.getenv("DEMOD_SHELL_DIR") or (APP:gsub("gcs/?$", "") .. "shell/")
local function aload(f) return dofile(APP .. f) end

local shell = dofile(SHELL .. "shell.lua")
shell.run{
  title = "DeMoD GCS",
  palettes = aload("theme.lua"),
  config = {
    path = os.getenv("DEMOD_GCS_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/gcs.lua"),
    keys = { "theme" }, defaults = { theme = "night" },
  },
  provider = function(cfg) return aload("provider.lua").new(cfg) end,
  surfaces = { aload("surfaces/hud.lua"), aload("surfaces/map.lua"), aload("surfaces/status.lua") },
  status = function(c) return (c.data.source or "") .. (c.data.armed and "  ARMED" or "") end,
}
