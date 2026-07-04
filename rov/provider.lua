-- SPDX-License-Identifier: MPL-2.0
-- rov/provider.lua — AUV/ROV telemetry: a DCF-over-JANUS (or wired) bridge
-- writing a KV file ($DEMOD_ROV_STATE), else a pure-Lua dive simulator. Bench/
-- tank/sim first; a proven autopilot (ArduSub) stays in the loop for real dives.
local M = {}
local STATE = os.getenv("DEMOD_ROV_STATE") or "/tmp/demod-rov.kv"

local function read_kv(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close()
  local t = {}
  for k, v in (s or ""):gmatch("(%w+)=([%-%d%.]+)") do t[k] = tonumber(v) end
  return t
end

function M.new(cfg)
  local self = { t = 0, mode = "sim", sonar = {} }
  function self:update(dt)
    self.t = self.t + dt
    local kv = read_kv(STATE)
    if kv and kv.ts and (os.time() - kv.ts) <= 2 then self.kv = kv; self.mode = "janus"
    else self.mode = "sim" end
    -- sonar/altitude trace evolves either way (from kv.alt or a sim seabed)
    local base = (self.kv and self.kv.altitude) or (8 + 4 * math.sin(self.t * 0.2))
    local s = self.sonar
    s[#s + 1] = base + 1.5 * math.sin(self.t * 4)
    if #s > 160 then table.remove(s, 1) end
  end
  function self:status() return self.mode end
  function self:read()
    if self.mode == "janus" and self.kv then
      local k = self.kv
      return { ok = true, source = "DCF/JANUS", depth = k.depth or 0, heading = k.heading or 0,
               pitch = k.pitch or 0, roll = k.roll or 0, temp = k.temp or 0, altitude = k.altitude or 0,
               thrusters = { k.t1 or 0, k.t2 or 0, k.t3 or 0, k.t4 or 0 }, sonar = self.sonar }
    end
    local t = self.t
    return { ok = true, source = "Simulator",
      depth = 12 + 6 * math.sin(t * 0.15), heading = (t * 8) % 360,
      pitch = 5 * math.sin(t * 0.5), roll = 4 * math.sin(t * 0.4),
      temp = 14 - 0.1 * (12 + 6 * math.sin(t * 0.15)), altitude = 8 + 4 * math.sin(t * 0.2),
      thrusters = { 0.5 + 0.4 * math.sin(t), 0.5 + 0.4 * math.sin(t + 1.6),
                    0.5 + 0.4 * math.sin(t + 3.1), 0.5 + 0.4 * math.sin(t + 4.7) },
      sonar = self.sonar }
  end
  return self
end

return M
