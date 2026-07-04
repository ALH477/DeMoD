-- SPDX-License-Identifier: MPL-2.0
-- dash/provider.lua — a generic telemetry source: poll a DCF mesh (the codec-16
-- meters block via dm.dcf) when connected, else a pure-Lua simulator. read()
-- returns {ok, source, vals[], scope[], master?, bpm?}.
local M = {}

function M.new(cfg)
  local self = { t = 0, mode = "sim", vals = {}, scope = {} }
  local host = os.getenv("DEMOD_DCF_HOST")
  if dm.dcf and host then
    if dm.dcf.open(host, tonumber(os.getenv("DEMOD_DCF_PORT") or "47000")) then self.opened = true end
  end

  function self:update(dt)
    self.t = self.t + dt
    if dm.dcf and self.opened then
      dm.dcf.ping()
      local m = dm.dcf.poll()
      if m then self.meters = m; self.mode = "dcf"; return end
      self.mode = "dcf-wait"
    end
    if self.mode ~= "dcf" then
      self.mode = self.opened and "dcf-wait" or "sim"
      self.vals = {}
      for i = 1, 6 do self.vals[i] = 0.5 + 0.45 * math.sin(self.t * 0.7 + i * 0.9) end
      self.scope = {}
      for i = 1, 128 do
        self.scope[i] = math.sin(self.t * 3 + i * 0.2) * (0.4 + 0.3 * math.sin(self.t * 0.3))
      end
    end
  end

  function self:status() return self.mode end

  function self:read()
    if self.mode == "dcf" and self.meters then
      local m = self.meters
      local vals = {}
      for i = 1, (m.slot_count or 6) do vals[i] = (m.levels_l and m.levels_l[i]) or 0 end
      return { ok = true, source = "DCF mesh", vals = vals,
               scope = (m.scope and m.scope.L) or {}, master = m.master, bpm = m.bpm }
    end
    return { ok = (self.mode == "sim"), source = (self.mode == "sim") and "Simulator" or "DCF (waiting)",
             vals = self.vals, scope = self.scope }
  end

  return self
end

return M
