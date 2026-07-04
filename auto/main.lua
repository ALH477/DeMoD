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
  aload("surfaces/camera.lua"),
  aload("surfaces/companion.lua"),
  aload("surfaces/settings.lua"),
}
local CAMERA = 3   -- index of the rear-camera surface (forced on reverse)

-- Only capture when a rear camera is EXPLICITLY configured (an integrator wires
-- DEMOD_CAMERA_DEV to the actual reverse camera) or in test mode — never auto-grab
-- whatever /dev/video* happens to exist (data-minimization; no cabin surveillance).
local function camera_configured()
  return os.getenv("DEMOD_CAMERA_TEST") == "1" or (os.getenv("DEMOD_CAMERA_DEV") ~= nil)
end

shell.run{
  title = "DeMoD Auto",
  palettes = THEMES,
  config = {
    path = os.getenv("DEMOD_AUTO_CONFIG") or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/auto.lua"),
    keys = { "theme", "speed_units", "temp_units", "provider", "obd_dev", "lockout" },
    defaults = {
      theme = "night", speed_units = "km/h", temp_units = "C",
      provider = "auto", obd_dev = os.getenv("DEMOD_OBD_DEV") or "/dev/ttyUSB0",
      lockout = "on",   -- motion lockout enabled by default
    },
  },
  provider = function(cfg) return TEL.new(cfg) end,
  surfaces = surfaces,
  -- safety: speed-gated motion lockout (km/h) + a non-preemptible rear camera.
  speed = function(data) return data.speed or 0 end,
  lockout_kmh = 8,
  priority = function(c) if c.data.reverse then return CAMERA end end,
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
    -- keep the rear camera warm if one is explicitly configured (instant on reverse)
    if camera_configured() then
      dm.exec(string.format("bash %q >/dev/null 2>&1", AUTO .. "camera.sh"))
      c.log("rear camera: capture started")
    end
  end,
}
