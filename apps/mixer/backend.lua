-- SPDX-License-Identifier: MPL-2.0
-- backend.lua — one contract over the three places the engine can be.
--
--   local   the orchestrator's control socket on this machine (dm.ctl_request,
--           $DEMOD_CONTROL_SOCK) and demod-rt's meters segment (dm.meters_read):
--           ops get replies, health and the slot list are available.
--   remote  an engine elsewhere — the Oligarchy DSP VM, another box — through
--           demod-remote-bridge over dm.dcf (needs the DCF build). Ops go out as
--           DCF-Text and the bridge streams the same meters back, so the strips
--           read the same keys; replies carry only accepted/refused, so health
--           and the slot list are not available.
--   sim     nothing reachable. The strips still move (from the UI's own shadow)
--           and say SIMULATOR in the status bar, so a kiosk that boots before
--           its engine is honest about it. A sim backend keeps retrying local.
--
-- DEMOD_MIXER_ENGINE=local | remote:HOST[:PORT] | sim chooses; unset means
-- local if it answers a ping, else sim. state() always returns 16 slots in the
-- dm.params_read() shape (gain, pan, levels_l, levels_r, mute_mask, solo_mask).
local B = {}
local SLOTS = 16

local function bit(mask, i)
  return (mask >> i) & 1 == 1
end

function B.new(json, env)
  env = env or os.getenv
  local self = {
    kind = "sim",
    source = "simulator",
    err = nil,
    t = 0,
    seq = 0,
    shadow = { gain = {}, pan = {}, mute = 0, solo = 0, master = 1.0, bpm = 120.0 },
    meters = nil,
    names = {},
    bypass = 0,
    loaded = {},
    health = nil,
    retry = 0,
    ping_t = 0,
    sent = 0,
    refused = 0,
  }
  for i = 1, SLOTS do
    self.shadow.gain[i] = 1.0
    self.shadow.pan[i] = 0.0
  end

  local function next_id()
    self.seq = self.seq + 1
    return "mx" .. self.seq
  end

  local function local_req(t)
    if not dm.ctl_request then
      return false, nil, "this demod-ui has no dm.ctl_request"
    end
    t.v = 1
    t.id = t.id or next_id()
    local ok, reply = dm.ctl_request(json.encode(t))
    local r = (reply and reply ~= "") and json.decode(reply) or nil
    if ok and r and r.ok == false then
      ok = false
    end
    local why = (r and r.err)
      or ((reply == nil or reply == "") and not ok and "engine unreachable")
      or nil
    return ok, r and r.data, why
  end

  local function try_local()
    local ok = local_req({ op = "ping" })
    if ok then
      self.kind, self.source, self.err =
        "local", (env("DEMOD_CONTROL_SOCK") or "/run/demod/control.sock"), nil
    end
    return ok
  end

  local choice = env("DEMOD_MIXER_ENGINE") or ""
  if choice:sub(1, 7) == "remote:" then
    local host, port = choice:sub(8):match("^([^:]+):?(%d*)$")
    port = tonumber(port) or 47000
    if not dm.dcf then
      self.err = "remote needs the DCF build of demod-ui"
    elseif host and dm.dcf.open(host, port) then
      self.kind, self.source = "remote", host .. ":" .. port
    else
      self.err = "cannot open " .. tostring(host) .. ":" .. port
    end
  elseif choice ~= "sim" then
    if not try_local() and choice == "local" then
      self.err = "no engine at the control socket"
    end
  end

  -- An op from the UI. The shadow is updated first so the strip follows the
  -- finger; the engine's readback takes over once it reports.
  function self:op(t)
    local s = t.slot and (t.slot + 1)
    if t.op == "set_slot_gain" then
      self.shadow.gain[s] = t.gain
    elseif t.op == "set_slot_pan" then
      self.shadow.pan[s] = t.pan
    elseif t.op == "set_slot_mute" then
      self.shadow.mute = t.on and (self.shadow.mute | (1 << t.slot))
        or (self.shadow.mute & ~(1 << t.slot))
    elseif t.op == "set_slot_solo" then
      self.shadow.solo = t.on and (self.shadow.solo | (1 << t.slot))
        or (self.shadow.solo & ~(1 << t.slot))
    elseif t.op == "set_gain" then
      self.shadow.master = t.gain
    elseif t.op == "set_bpm" then
      self.shadow.bpm = t.bpm
    elseif t.op == "bypass_fx" then
      self.bypass = t.on and (self.bypass | (1 << t.slot)) or (self.bypass & ~(1 << t.slot))
    end
    self.sent = self.sent + 1
    if self.kind == "local" then
      local ok, _, why = local_req(t)
      if not ok then
        self.refused = self.refused + 1
        self.err = why
      end
      return ok
    elseif self.kind == "remote" then
      t.v = 1
      t.id = t.id or next_id()
      return dm.dcf.send(json.encode(t))
    end
    return true
  end

  function self:update(dt)
    self.t = self.t + dt
    if self.kind == "local" then
      local m = (dm.meters_read and dm.meters_read()) or (dm.params_read and dm.params_read())
      if m and m.gain then
        self.meters = m
      end
      self.ping_t = self.ping_t - dt
      if self.ping_t <= 0 then
        self.ping_t = 1.0
        local ok, h, why = local_req({ op = "get_health" })
        self.health = ok and h or nil
        if not ok then
          self.err = why or "engine stopped answering"
        else
          self.err = nil
        end
        local sok, sl = local_req({ op = "list_slots" })
        if sok and sl and sl.slots then
          for _, e in ipairs(sl.slots) do
            local i = e.slot + 1
            self.loaded[i] = e.loaded == true
            self.names[i] = (type(e.path) == "string")
                and e.path:match("([^/]+)$"):gsub("%.so$", "")
              or nil
          end
          self.bypass = sl.bypass_mask or self.bypass
        end
      end
    elseif self.kind == "remote" then
      self.ping_t = self.ping_t - dt
      if self.ping_t <= 0 then
        self.ping_t = 2.0
        dm.dcf.ping()
      end -- blocking: keep it rare
      local m = dm.dcf.poll()
      if m then
        self.meters = m
      end
      while true do
        local ev = dm.dcf.poll_event()
        if not ev then
          break
        end
        if ev.kind == "op_reply" and not ev.ok then
          self.refused = self.refused + 1
          self.err = "engine refused an op (" .. tostring(ev.reason or ev.status) .. ")"
        end
      end
    else
      self.retry = self.retry - dt
      if self.retry <= 0 and (env("DEMOD_MIXER_ENGINE") or "") ~= "sim" then
        self.retry = 3.0
        try_local()
      end
    end
  end

  -- The strips' view: the engine's readback where it has one, the shadow for
  -- anything `held` (being dragged right now) and for whatever it lacks.
  function self:state(held)
    held = held or {}
    local m, sh = self.meters, self.shadow
    local st = {
      gain = {},
      pan = {},
      l = {},
      r = {},
      mute = sh.mute,
      solo = sh.solo,
      master = sh.master,
      bpm = sh.bpm,
    }
    if m and m.mute_mask then
      st.mute, st.solo = m.mute_mask, m.solo_mask
    end
    for i = 1, SLOTS do
      local g = (m and m.gain and m.gain[i]) or sh.gain[i]
      local p = (m and m.pan and m.pan[i]) or sh.pan[i]
      if held["gain" .. i] then
        g = sh.gain[i]
      end
      if held["pan" .. i] then
        p = sh.pan[i]
      end
      st.gain[i], st.pan[i] = g, p
      if m and m.levels_l then
        st.l[i], st.r[i] = m.levels_l[i] or 0, (m.levels_r and m.levels_r[i]) or 0
      elseif self.kind == "sim" then
        local on = not bit(st.mute, i - 1) and (st.solo == 0 or bit(st.solo, i - 1))
        local v = on and math.min(1, g * (0.45 + 0.25 * math.sin(self.t * (1.3 + i * 0.17) + i)))
          or 0
        st.l[i] = v * (1 - math.max(0, p))
        st.r[i] = v * (1 + math.min(0, p))
      else
        st.l[i], st.r[i] = 0, 0
      end
    end
    return st
  end

  function self:label()
    if self.kind == "local" then
      return "ENGINE " .. self.source
    end
    if self.kind == "remote" then
      return "REMOTE " .. self.source
    end
    return "SIMULATOR - no engine" .. (self.err and (": " .. self.err) or "")
  end

  return self
end

return B
