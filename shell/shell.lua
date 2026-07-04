-- SPDX-License-Identifier: MPL-2.0
-- shell.lua — the DeMoD companion-shell SDK runtime. A surface-based head-unit /
-- console shell: an app supplies surfaces + a telemetry provider + a palette +
-- config keys, and shell.run() installs the framework globals and drives it.
--
--   local shell = dofile(os.getenv("DEMOD_SHELL_DIR").."shell.lua")
--   shell.run{
--     title="DeMoD Auto", palettes=THEMES, provider=P,
--     config={ path=..., keys={...}, defaults={...} },
--     surfaces={ s1, s2, ... },       -- each: {name, draw(ctx), nav?(a,ctx), zones?(ctx), update?(dt,ctx)}
--     status=function(ctx) return "right-side text" end,
--     on_start=function(ctx) end, on_save=function(cfg,log) end, on_wet=function(cfg,log) end,
--   }
--
-- ctx = { th, W, H, U(draw), cfg, save, provider, data=provider:read(), dcf, events, log, active }
-- Controls: tab/tab_prev switch surface, back->#1, wet toggle day/night (or on_wet),
-- everything else -> the active surface's nav(). Copyright (c) 2026 DeMoD LLC. MPL-2.0.

local SHELL_DIR = os.getenv("DEMOD_SHELL_DIR")
if not SHELL_DIR then SHELL_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./" end
local function sload(f) return dofile(SHELL_DIR .. f) end
local U       = sload("draw.lua")
local resolve = sload("theme.lua")
local touch   = sload("touch.lua")

local M = { U = U }

local function load_cfg(c)
  local cfg = {}
  local ok, t = pcall(dofile, c.path)
  if ok and type(t) == "table" then cfg = t end
  for k, v in pairs(c.defaults or {}) do if cfg[k] == nil then cfg[k] = v end end
  return cfg
end

local function save_cfg(c, cfg)
  local dir = c.path:match("(.*/)")
  if dir then os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") end
  local f = io.open(c.path, "w")
  if not f then return end
  f:write("return {\n")
  for _, k in ipairs(c.keys) do f:write(string.format("  %s = %q,\n", k, tostring(cfg[k]))) end
  f:write("}\n")
  f:close()
end

function M.run(app)
  local surfaces = app.surfaces
  local active = tonumber(os.getenv("DEMOD_SURFACE")) or 1
  local cfg = load_cfg(app.config)
  -- provider may be an object or a factory(cfg) — the latter sees the loaded cfg
  local provider = (type(app.provider) == "function") and app.provider(cfg) or app.provider

  local events = {}
  local function log(s) events[#events + 1] = s; if #events > 80 then table.remove(events, 1) end end
  local function save() save_cfg(app.config, cfg); if app.on_save then app.on_save(cfg, log) end end
  log((app.title or "shell") .. " started")

  local dcf = { available = (dm.dcf ~= nil), status = "no link" }
  if dm.dcf and os.getenv("DEMOD_DCF_HOST") then
    if dm.dcf.open(os.getenv("DEMOD_DCF_HOST"), tonumber(os.getenv("DEMOD_DCF_PORT") or "47000")) then
      dcf.opened = true; dcf.status = "connecting"; log("mesh: opening")
    end
  end

  local function ctx()
    local data = provider and provider:read() or {}
    -- Motion lockout ("driver mode"): if the app reports a speed and it exceeds
    -- the threshold, restricted (entertainment) surfaces are gated. On by default.
    local speed = app.speed and app.speed(data) or 0
    local locked = (app.speed ~= nil) and (cfg.lockout ~= "off") and (speed > (app.lockout_kmh or 8))
    return {
      th = resolve(cfg.theme, app.palettes), W = dm.width(), H = dm.height(), U = U,
      cfg = cfg, save = save, provider = provider,
      data = data, speed = speed, locked = locked,
      dcf = dcf, events = events, log = log, active = active,
    }
  end

  if app.on_start then app.on_start(ctx()) end

  -- Priority (non-preemptible) surface: when app.priority(ctx) returns an index
  -- (e.g. the rear camera on reverse), the shell forces it and blocks switching.
  local forced, prev = false, nil
  local function set_active(i) if forced then return end; active = ((i - 1) % #surfaces) + 1; dm.redraw() end
  local function dispatch(action)
    if action == "tab" then set_active(active + 1)
    elseif action == "tab_prev" then set_active(active - 1)
    elseif action == "back" then set_active(1)
    elseif action == "wet" then
      if app.on_wet then app.on_wet(cfg, log)
      else cfg.theme = (resolve(cfg.theme, app.palettes) == app.palettes.night) and "day" or "night" end
      save(); log("theme: " .. tostring(cfg.theme))
    else
      local c = ctx()
      local s = surfaces[active]
      if c.locked and s.restricted then return end   -- no operating entertainment in motion
      if s.nav then s.nav(action, c) end
    end
  end

  function on_nav(action) dispatch(action); dm.redraw() end

  function on_update(dt)
    dt = dt or 1 / 60
    if provider then provider:update(dt) end
    if dm.dcf and dcf.opened then
      dm.dcf.ping(); dcf.status = dm.dcf.status()
      while true do local ev = dm.dcf.poll_event(); if not ev then break end; log("mesh: " .. ev.kind) end
      dm.dcf.poll()
    end
    -- priority surface (e.g. rear camera on reverse): force it, remember where
    -- we were, restore on release.
    if app.priority then
      local p = app.priority(ctx())
      if p and not forced then prev = active end
      if p then active = p; forced = true
      elseif forced then active = prev or 1; forced = false end
    end

    local c = ctx()
    if surfaces[active].update then surfaces[active].update(dt, c) end

    -- touch: tab-bar zones (always) + the active surface's declared zones. A
    -- locked restricted surface exposes no interactive zones.
    local zones = {}
    local n, tw, tb = #surfaces, c.W / #surfaces, c.H - 32
    if not forced then
      for i = 1, n do
        zones[#zones + 1] = { x = (i - 1) * tw, y = tb, w = tw, h = 32, on = function() set_active(i) end }
      end
    end
    local s = surfaces[active]
    if s.zones and not (c.locked and s.restricted) then
      for _, z in ipairs(s.zones(c)) do
        local on = z.on
        zones[#zones + 1] = { x = z.x, y = z.y, w = z.w, h = z.h, on = function() on(); dm.redraw() end }
      end
    end
    touch.frame(zones)
    dm.redraw()
  end

  function on_draw()
    local c = ctx()
    local th, W, H = c.th, c.W, c.H
    U.rect(0, 0, W, H, th.bg, 255)
    U.rect(0, 0, W, 40, th.panel, 255)
    U.text(16, 13, app.title or "shell", th.accent, 1)
    U.textc(W / 2, 13, os.date("%H:%M"), th.text, 1)
    if app.status then
      local right = app.status(c)
      if right then U.textr(W - 16, 13, right, th.text, 1) end
    end

    local s = surfaces[active]
    if c.locked and s.restricted then
      -- lockout overlay: the entertainment surface is unavailable in motion
      U.rect(0, 40, W, H - 40, th.panel, 255)
      U.textc(W / 2, math.floor(H / 2) - 44, "PULL OVER TO USE", th.alert, 3)
      U.textc(W / 2, math.floor(H / 2) + 6, s.name .. " is disabled while the vehicle is moving",
        th.dim, 1)
      U.textc(W / 2, math.floor(H / 2) + 28, string.format("(%.0f km/h)", c.speed or 0), th.dim, 1)
    else
      s.draw(c)
    end

    -- a forced priority surface (rear camera on reverse) hides the tab bar so it
    -- cannot be navigated away from.
    if forced then return end

    local tb = H - 32
    U.rect(0, tb, W, 32, th.panel, 255)
    local n, tw = #surfaces, W / #surfaces
    for i, s in ipairs(surfaces) do
      local sel = (i == active)
      if sel then U.rect(math.floor((i - 1) * tw), tb, math.floor(tw), 3, th.accent, 255) end
      U.textc((i - 1) * tw + tw / 2, tb + 10, s.name, sel and th.accent or th.dim, 1)
    end
  end
end

return M
