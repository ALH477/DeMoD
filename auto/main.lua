-- SPDX-License-Identifier: MPL-2.0
-- DeMoD Auto — a FOSS car head-unit + vehicle-companion shell on the DeMoD UI
-- framework. Drivable entirely from the on_nav funnel (rotary controller /
-- steering-wheel buttons / keyboard / gamepad — the pointer is optional):
--   tab / tab_prev  switch surface (DRIVE / COMPANION / SETTINGS)
--   prev / next     move focus within a surface
--   activate        change / select
--   back            jump to DRIVE
--   wet (X)         toggle day / night
-- Copyright (c) 2026 DeMoD LLC. MPL-2.0; see LICENSE.

local HERE = os.getenv("DEMOD_AUTO_DIR")
if not HERE then
  HERE = (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
end
local function load(rel) return dofile(HERE .. rel) end

local U   = load("util.lua")
local TH  = load("theme.lua")
local TEL = load("vehicle/telemetry.lua")
local surfaces = {
  load("surfaces/dashboard.lua"),
  load("surfaces/companion.lua"),
  load("surfaces/settings.lua"),
}
local active = tonumber(os.getenv("DEMOD_AUTO_SURFACE")) or 1   -- deep-link/testing

-- ── config (persisted lua table) ─────────────────────────────────────────
local CFG_PATH = os.getenv("DEMOD_AUTO_CONFIG")
  or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/auto.lua")

local CFG
do
  local ok, t = pcall(dofile, CFG_PATH)
  CFG = (ok and type(t) == "table") and t or {}
end
CFG.theme       = CFG.theme or "night"
CFG.speed_units = CFG.speed_units or "km/h"
CFG.temp_units  = CFG.temp_units or "C"
CFG.provider    = CFG.provider or "auto"
CFG.obd_dev     = CFG.obd_dev or (os.getenv("DEMOD_OBD_DEV") or "/dev/ttyUSB0")

local function save_cfg()
  local dir = CFG_PATH:match("(.*/)")
  if dir then os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") end
  local f = io.open(CFG_PATH, "w")
  if not f then return end
  f:write("return {\n")
  for _, k in ipairs({ "theme", "speed_units", "temp_units", "provider", "obd_dev" }) do
    f:write(string.format("  %s = %q,\n", k, tostring(CFG[k])))
  end
  f:write("}\n")
  f:close()
end

-- ── state ─────────────────────────────────────────────────────────────────
local provider = TEL.new(CFG)          -- reads CFG.provider live
local events = {}
local function log(s) events[#events + 1] = s; if #events > 64 then table.remove(events, 1) end end
log("DeMoD Auto started")

local dcf = { available = (dm.dcf ~= nil), status = "no link" }
if dm.dcf then
  local host = os.getenv("DEMOD_DCF_HOST")
  if host then
    if dm.dcf.open(host, tonumber(os.getenv("DEMOD_DCF_PORT") or "47000")) then
      dcf.opened = true; dcf.status = "connecting"; log("mesh: opening " .. host)
    end
  end
end

local obd_spawned = false
local function maybe_spawn_obd()
  if obd_spawned then return end
  if CFG.provider ~= "sim" and CFG.obd_dev ~= "" then
    obd_spawned = true
    dm.exec(string.format("DEMOD_OBD_DEV=%q python3 %q >/dev/null 2>&1",
      CFG.obd_dev, HERE .. "vehicle/obd2-reader.py"))
    log("OBD reader: " .. CFG.obd_dev)
  end
end
maybe_spawn_obd()

-- ── helpers ─────────────────────────────────────────────────────────────
local function resolved_theme()
  local t = CFG.theme
  if t == "auto" then
    local h = tonumber(os.date("%H")) or 12
    t = (h < 7 or h >= 19) and "night" or "day"
  end
  return TH[t] or TH.night
end

local function ctx()
  return {
    th = resolved_theme(), W = dm.width(), H = dm.height(), U = U,
    veh = provider:read(), prov = provider, cfg = CFG,
    save = function() save_cfg(); maybe_spawn_obd(); log("settings saved") end,
    units = { speed = CFG.speed_units, temp = CFG.temp_units },
    dcf = dcf, events = events, log = log,
  }
end

-- ── framework callbacks ──────────────────────────────────────────────────
function on_update(dt)
  provider:update(dt or 1 / 60)
  if dm.dcf and dcf.opened then
    dm.dcf.ping()
    dcf.status = dm.dcf.status()
    while true do
      local ev = dm.dcf.poll_event()
      if not ev then break end
      log("mesh: " .. ev.kind .. (ev.reason and (" (" .. ev.reason .. ")") or ""))
    end
    dm.dcf.poll()
  end
  dm.redraw()
end

function on_nav(action)
  if action == "tab" then
    active = active % #surfaces + 1
  elseif action == "tab_prev" then
    active = (active - 2) % #surfaces + 1
  elseif action == "back" then
    active = 1
  elseif action == "wet" then
    CFG.theme = (resolved_theme() == TH.night) and "day" or "night"
    save_cfg(); log("theme: " .. CFG.theme)
  else
    local s = surfaces[active]
    if s.nav then s.nav(action, ctx()) end
  end
  dm.redraw()
end

function on_draw()
  local c = ctx()
  local th, W, H = c.th, c.W, c.H
  U.rect(0, 0, W, H, th.bg, 255)

  -- top status bar
  U.rect(0, 0, W, 40, th.panel, 255)
  U.text(16, 13, "DeMoD Auto", th.accent, 1)
  U.textc(W / 2, 13, os.date("%H:%M"), th.text, 1)
  local badge = c.veh.source .. (dm.dcf and ("   mesh: " .. c.dcf.status) or "")
  U.textr(W - 16, 13, badge, c.veh.ok and th.ok or th.warn, 1)

  -- active surface (draws in [40, H-32])
  surfaces[active].draw(c)

  -- bottom tab bar
  local tb = H - 32
  U.rect(0, tb, W, 32, th.panel, 255)
  local n = #surfaces
  local tw = W / n
  for i, s in ipairs(surfaces) do
    local sel = (i == active)
    if sel then U.rect(math.floor((i - 1) * tw), tb, math.floor(tw), 3, th.accent, 255) end
    U.textc((i - 1) * tw + tw / 2, tb + 10, s.name, sel and th.accent or th.dim, 1)
  end
end
