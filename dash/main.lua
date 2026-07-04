-- SPDX-License-Identifier: MPL-2.0
-- DeMoD Dash — a generic DCF-mesh telemetry dashboard on the companion-shell SDK.
-- Connect to a mesh (DEMOD_DCF_HOST/_PORT) or run the simulator. MPL-2.0.
local APP   = os.getenv("DEMOD_DASH_DIR") or (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local SHELL = os.getenv("DEMOD_SHELL_DIR") or (APP:gsub("dash/?$", "") .. "shell/")
local function aload(f) return dofile(APP .. f) end

local shell = dofile(SHELL .. "shell.lua")
shell.run{
  title = "DeMoD Dash",
  palettes = aload("theme.lua"),
  config = {
    path = os.getenv("DEMOD_DASH_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/dash.lua"),
    keys = { "theme" }, defaults = { theme = "night" },
  },
  provider = function(cfg) return aload("provider.lua").new(cfg) end,
  surfaces = { aload("surfaces/live.lua"), aload("surfaces/scope.lua"), aload("surfaces/mesh.lua") },
  status = function(c) return c.data.source or "" end,
}
