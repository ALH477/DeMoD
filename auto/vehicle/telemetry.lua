-- SPDX-License-Identifier: MPL-2.0
-- telemetry.lua — the vehicle telemetry provider for DeMoD Auto.
-- One interface, three backends:
--   simulator : a pure-Lua synthetic drive cycle (the always-available fallback)
--   obd2      : reads the $DEMOD_VEHICLE_STATE file written by obd2-reader.py
--   dcf       : (seam) telemetry over dm.dcf — not wired in v1
-- read() returns {ok, source, speed, rpm, coolant, fuel, volts, throttle, gear}.
local M = {}

local STATE = os.getenv("DEMOD_VEHICLE_STATE") or "/tmp/demod-vehicle.kv"

local function read_kv(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  if not s or s == "" then return nil end
  local t = {}
  for k, v in s:gmatch("(%w+)=([%-%d%.]+)") do t[k] = tonumber(v) end
  return t
end

function M.new(cfg)
  cfg = cfg or {}
  local self = {
    t = 0, mode = "sim",
    sim = { speed = 0, rpm = 800, coolant = 40, fuel = 72, volts = 13.8, throttle = 0, gear = "P" },
  }

  function self:update(dt)
    self.t = self.t + dt
    local want = cfg.provider or "auto"          -- "auto" | "obd2" | "sim"
    if want ~= "sim" then
      local kv = read_kv(STATE)
      local fresh = kv and kv.ts and (os.time() - kv.ts) <= 2
      if fresh then self.mode = "obd2"; self.obd = kv; return end
      if want == "obd2" then self.mode = "obd2-nolink"; return end
    end
    -- simulator: a gentle accelerate / cruise / decelerate loop
    self.mode = "sim"
    local s = self.sim
    local target = 42 + 38 * math.sin(self.t * 0.08)
    if target < 0 then target = 0 end
    s.speed = s.speed + (target - s.speed) * math.min(1, dt * 0.6)
    s.rpm = 800 + s.speed * 34 + 260 * math.max(0, math.sin(self.t * 0.5))
    s.coolant = math.min(92, 40 + self.t * 3)
    s.fuel = math.max(6, 72 - self.t * 0.03)
    s.throttle = math.max(0, math.min(100, (target - s.speed) * 8 + 8))
    s.volts = 13.8 + 0.2 * math.sin(self.t * 0.3)
    s.gear = s.speed < 2 and "P" or (s.speed < 20 and "1" or (s.speed < 40 and "2"
             or (s.speed < 65 and "3" or "4")))
  end

  function self:status() return self.mode end

  function self:read()
    if self.mode == "obd2" and self.obd then
      local o = self.obd
      return { ok = true, source = "OBD-II", speed = o.speed or 0, rpm = o.rpm or 0,
               coolant = o.coolant or 0, fuel = o.fuel or 0, volts = o.volts or 0,
               throttle = o.throttle or 0, gear = "D" }
    end
    if self.mode == "obd2-nolink" then
      return { ok = false, source = "OBD-II (no link)", speed = 0, rpm = 0, coolant = 0,
               fuel = 0, volts = 0, throttle = 0, gear = "--" }
    end
    local s = self.sim
    return { ok = true, source = "Simulator", speed = s.speed, rpm = s.rpm, coolant = s.coolant,
             fuel = s.fuel, volts = s.volts, throttle = s.throttle, gear = s.gear }
  end

  return self
end

return M
