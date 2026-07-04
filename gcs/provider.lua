-- SPDX-License-Identifier: MPL-2.0
-- gcs/provider.lua — flight telemetry: a MAVLink bridge (seam) writing a KV file
-- ($DEMOD_GCS_STATE), else a pure-Lua flight simulator. A real bridge would parse
-- MAVLink from a PX4/ArduPilot FC (serial/UDP) and write the same fields — the
-- FC flies; DeMoD is the companion/GCS. read() returns attitude + nav + status.
local M = {}
local STATE = os.getenv("DEMOD_GCS_STATE") or "/tmp/demod-gcs.kv"

local function read_kv(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close()
  local t = {}
  for k, v in (s or ""):gmatch("(%w+)=([%-%d%.]+)") do t[k] = tonumber(v) end
  return t
end

function M.new(cfg)
  local self = { t = 0, mode = "sim" }
  function self:update(dt)
    self.t = self.t + dt
    local kv = read_kv(STATE)
    if kv and kv.ts and (os.time() - kv.ts) <= 2 then self.kv = kv; self.mode = "mavlink"
    else self.mode = "sim" end
  end
  function self:status() return self.mode end
  function self:read()
    if self.mode == "mavlink" and self.kv then
      local k = self.kv
      return { ok = true, source = "MAVLink", roll = k.roll or 0, pitch = k.pitch or 0,
               yaw = k.yaw or 0, alt = k.alt or 0, speed = k.speed or 0, battery = k.battery or 0,
               sats = k.sats or 0, rssi = k.rssi or 0, armed = (k.armed == 1), mode = "FC",
               x = k.x or 0.5, y = k.y or 0.5 }
    end
    local t = self.t
    return { ok = true, source = "Simulator",
      roll = 15 * math.sin(t * 0.6), pitch = 6 * math.sin(t * 0.4), yaw = (t * 12) % 360,
      alt = 120 + 30 * math.sin(t * 0.3), speed = 14 + 3 * math.sin(t * 0.5),
      battery = math.max(20, 100 - t * 0.4), sats = 11, rssi = 82, armed = true, mode = "AUTO",
      x = 0.5 + 0.3 * math.cos(t * 0.2), y = 0.5 + 0.3 * math.sin(t * 0.2) }
  end
  return self
end

return M
