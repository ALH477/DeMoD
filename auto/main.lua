-- SPDX-License-Identifier: MPL-2.0
-- DeMoD Auto — a FOSS car head-unit + vehicle-companion shell, built on the
-- DeMoD companion-shell SDK (shell/). This file is thin: it supplies the
-- automotive theme, the OBD-II telemetry provider, and the surfaces, then hands
-- off to shell.run(). Drivable from a rotary controller / wheel buttons /
-- keyboard / gamepad / touch. Copyright (c) 2026 DeMoD LLC. MPL-2.0; see LICENSE.

local AUTO  = os.getenv("DEMOD_AUTO_DIR") or (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local SHELL = os.getenv("DEMOD_SHELL_DIR") or (AUTO:gsub("auto/?$", "") .. "shell/")
local function aload(f) return dofile(AUTO .. f) end

local shell   = dofile(SHELL .. "shell.lua")
local THEMES  = aload("theme.lua")
local TEL     = aload("vehicle/telemetry.lua")

local surfaces = {
  aload("surfaces/dashboard.lua"),
  aload("surfaces/media.lua"),
  aload("surfaces/companion.lua"),
  aload("surfaces/settings.lua"),
}

shell.run{
  title = "DeMoD Auto",
  palettes = THEMES,
  config = {
    path = os.getenv("DEMOD_AUTO_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/auto.lua"),
    keys = { "theme", "speed_units", "temp_units", "provider", "obd_dev" },
    defaults = {
      theme = "night", speed_units = "km/h", temp_units = "C",
      provider = "auto", obd_dev = os.getenv("DEMOD_OBD_DEV") or "/dev/ttyUSB0",
    },
  },
  provider = function(cfg) return TEL.new(cfg) end,
  surfaces = surfaces,
  status = function(c)
    return (c.data.source or "") .. (dm.dcf and ("   mesh: " .. c.dcf.status) or "")
  end,
  on_start = function(c)
    -- spawn the OBD reader when the data source wants it (harmless if no adapter)
    if c.cfg.provider ~= "sim" and c.cfg.obd_dev ~= "" then
      dm.exec(string.format("DEMOD_OBD_DEV=%q python3 %q >/dev/null 2>&1",
        c.cfg.obd_dev, AUTO .. "vehicle/obd2-reader.py"))
      c.log("OBD reader: " .. c.cfg.obd_dev)
    end
  end,
}
