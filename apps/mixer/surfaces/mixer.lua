-- SPDX-License-Identifier: MPL-2.0
-- mixer.lua — the channel strips. Eight per page (slots 1-8, 9-16) plus the
-- master. Touch: drag a fader or a pan bar, tap M / S / the page arrows.
-- Encoder (on_nav): prev/next walk the controls, activate grabs a fader or pan
-- (then prev/next move it, 1 dB or 0.05 a detent) or toggles M / S.
--
-- Everything is driven from update() through input.read(), not from the
-- shell's invisible-button overlay: that overlay only reports taps, and a
-- fader needs press-drag-release. So no zones are declared for the strips.
return function(deps)
  local T, input = deps.taper, deps.input
  local S = { name = "MIXER" }
  local PER_PAGE, SLOTS = 8, 16
  local page = 0 -- 0: slots 1-8, 1: 9-16
  local drag = nil -- { kind="gain"|"pan"|"master", slot=i }
  local press = nil -- tap candidate { kind, slot, x, y }
  local held, hold_t = {}, {} -- shadow wins while held (and briefly after)
  local last_sent = {}
  local was_down = false
  local focus, adjusting = 1, false -- encoder: index into fields()
  local now = 0

  -- Geometry, a pure function of the screen size (the gesture tests use it too).
  function S.layout(W, H)
    local L = { strips = {} }
    local top, bottom = 48, H - 40
    L.header = { x = 8, y = top, w = W - 16, h = 28 }
    L.prev = { x = W - 160, y = top, w = 70, h = 28 }
    L.next = { x = W - 82, y = top, w = 70, h = 28 }
    local sy = top + 36
    local sh = bottom - sy
    local mw = math.max(90, math.floor(W * 0.11))
    local gap = 6
    local sw = math.floor((W - 16 - mw - gap * PER_PAGE) / PER_PAGE)
    local fy, fh = sy + 92, sh - 92 - 26
    for k = 1, PER_PAGE do
      local x = 8 + (k - 1) * (sw + gap)
      local half = math.floor((sw - 12) / 2)
      L.strips[k] = {
        x = x,
        w = sw,
        y = sy,
        h = sh,
        mute = { x = x + 4, y = sy + 22, w = half, h = 30 },
        solo = { x = x + 8 + half, y = sy + 22, w = half, h = 30 },
        pan = { x = x + 4, y = sy + 60, w = sw - 8, h = 22 },
        track = { x = x + math.floor(sw / 2) - 22, y = fy, w = 12, h = fh },
        meter = { x = x + math.floor(sw / 2) + 4, y = fy, w = 14, h = fh },
        grab = { x = x, y = fy - 12, w = sw, h = fh + 24 }, -- generous touch target
        db_y = sy + sh - 20,
      }
    end
    local mx = W - mw - 8
    L.master = {
      x = mx,
      w = mw,
      y = sy,
      h = sh,
      track = { x = mx + math.floor(mw / 2) - 22, y = fy, w = 12, h = fh },
      meter = { x = mx + math.floor(mw / 2) + 4, y = fy, w = 14, h = fh },
      grab = { x = mx, y = fy - 12, w = mw, h = fh + 24 },
      db_y = sy + sh - 20,
    }
    return L
  end

  local function inside(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
  end
  local function slot_of(k)
    return page * PER_PAGE + k
  end

  -- Encoder fields on the current page: per strip fader, pan, mute, solo; then master.
  local function fields()
    local f = {}
    for k = 1, PER_PAGE do
      for _, kind in ipairs({ "gain", "pan", "mute", "solo" }) do
        f[#f + 1] = { kind = kind, k = k }
      end
    end
    f[#f + 1] = { kind = "master" }
    return f
  end

  local function send(be, kind, slot, value, force)
    local key = kind .. (slot or "")
    held[key] = true
    hold_t[key] = now + 0.6
    if not force and last_sent[key] and now - last_sent[key].t < 0.033 then
      return
    end
    if last_sent[key] and last_sent[key].v == value and not force then
      return
    end
    last_sent[key] = { t = now, v = value }
    if kind == "gain" then
      be:op({ op = "set_slot_gain", slot = slot - 1, gain = value })
    elseif kind == "pan" then
      be:op({ op = "set_slot_pan", slot = slot - 1, pan = value })
    elseif kind == "master" then
      be:op({ op = "set_gain", gain = value })
    end
  end

  local function value_at(kind, r, x, y)
    if kind == "pan" then
      local p = ((x - r.x) / r.w) * 2 - 1
      -- detents a finger can find: centre, and both ends
      if math.abs(p) < 0.04 then
        p = 0
      elseif p > 0.95 then
        p = 1
      elseif p < -0.95 then
        p = -1
      end
      return math.max(-1, math.min(1, math.floor(p * 100 + 0.5) / 100))
    end
    local pos = 1 - (y - r.y) / r.h
    return T.pos_to_gain(math.max(0, math.min(1, pos)))
  end

  local function toggle(be, st, kind, slot)
    local mask = (kind == "mute") and st.mute or st.solo
    local on = (mask >> (slot - 1)) & 1 == 0
    be:op({ op = (kind == "mute") and "set_slot_mute" or "set_slot_solo", slot = slot - 1, on = on })
  end

  function S.update(dt, ctx)
    now = now + dt
    for k, t in pairs(hold_t) do
      if now > t and not (drag and (drag.kind .. (drag.slot or "")) == k) then
        held[k] = nil
        hold_t[k] = nil
      end
    end
    local be = ctx.provider
    local L = S.layout(ctx.W, ctx.H)
    local x, y, down = input.read()
    if down and not was_down then
      -- press: a fader or pan starts a drag; M / S / page arrows are taps
      for k = 1, PER_PAGE do
        local s = L.strips[k]
        if inside(s.pan, x, y) then
          drag = { kind = "pan", slot = slot_of(k), r = s.pan }
        elseif inside(s.grab, x, y) then
          drag = { kind = "gain", slot = slot_of(k), r = s.track }
        elseif inside(s.mute, x, y) then
          press = { kind = "mute", slot = slot_of(k), r = s.mute }
        elseif inside(s.solo, x, y) then
          press = { kind = "solo", slot = slot_of(k), r = s.solo }
        end
      end
      if inside(L.master.grab, x, y) then
        drag = { kind = "master", r = L.master.track }
      end
      if inside(L.prev, x, y) then
        press = { kind = "prev", r = L.prev }
      end
      if inside(L.next, x, y) then
        press = { kind = "next", r = L.next }
      end
    end
    if drag and down then
      send(be, drag.kind, drag.slot, value_at(drag.kind, drag.r, x, y), false)
    elseif drag and not down then
      send(be, drag.kind, drag.slot, value_at(drag.kind, drag.r, x, y), true) -- the final value, always
      drag = nil
    end
    if press and not down and was_down then
      if inside(press.r, x, y) then
        if press.kind == "prev" then
          page = (page + 1) % 2 -- two pages: either arrow flips
        elseif press.kind == "next" then
          page = (page + 1) % 2
        else
          toggle(be, be:state(held), press.kind, press.slot)
        end
      end
      press = nil
    end
    was_down = down
  end

  function S.nav(action, ctx)
    local be, f = ctx.provider, fields()
    local cur = f[focus]
    local st = be:state(held)
    if adjusting and (action == "prev" or action == "next") then
      local d = (action == "next") and 1 or -1
      if cur.kind == "gain" then
        local s = slot_of(cur.k)
        send(be, "gain", s, T.step_db(st.gain[s], d), true)
      elseif cur.kind == "pan" then
        local s = slot_of(cur.k)
        send(be, "pan", s, math.max(-1, math.min(1, st.pan[s] + 0.05 * d)), true)
      elseif cur.kind == "master" then
        send(be, "master", nil, T.step_db(st.master, d), true)
      end
      return true
    end
    if action == "next" or action == "prev" then
      focus = focus + ((action == "next") and 1 or -1)
      if focus > #f then
        focus = 1
        page = (page + 1) % 2
      end
      if focus < 1 then
        focus = #f
        page = (page + 1) % 2
      end
      return true
    end
    if action == "activate" then
      if cur.kind == "mute" or cur.kind == "solo" then
        toggle(be, st, cur.kind, slot_of(cur.k))
      else
        adjusting = not adjusting
      end
      return true
    end
    return false
  end

  -- ── drawing ────────────────────────────────────────────────────────────
  local function meter(U, th, r, l, rr)
    local half = math.floor(r.w / 2) - 1
    U.rect(r.x, r.y, r.w, r.h, th.ring, 255)
    for j, v in ipairs({ l, rr }) do
      local hgt = math.floor(r.h * math.max(0, math.min(1, v)))
      local col = v > 0.95 and th.alert or (v > 0.7 and th.warn or th.ok)
      U.rect(r.x + (j - 1) * (half + 2), r.y + r.h - hgt, half, hgt, col, 255)
    end
  end

  local function fader(U, th, r, g, active)
    U.rect(r.x, r.y, r.w, r.h, th.ring, 255)
    local uy = r.y + math.floor(r.h * (1 - T.UNITY))
    U.rect(r.x - 6, uy, r.w + 12, 1, th.dim, 255) -- 0 dB mark
    local cy = r.y + math.floor(r.h * (1 - T.gain_to_pos(g)))
    U.rect(r.x - 10, cy - 7, r.w + 20, 14, active and th.accent or th.text, 255)
    U.rect(r.x - 10, cy - 1, r.w + 20, 2, th.bg, 255)
  end

  local function button(U, th, r, label, on, oncol)
    U.rect(r.x, r.y, r.w, r.h, on and oncol or th.panel2, 255)
    U.textc(r.x + r.w / 2, r.y + math.floor(r.h / 2) - 4, label, on and th.bg or th.text, 1)
  end

  local function outline(U, th, r)
    U.rect(r.x - 2, r.y - 2, r.w + 4, 2, th.accent, 255)
    U.rect(r.x - 2, r.y + r.h, r.w + 4, 2, th.accent, 255)
    U.rect(r.x - 2, r.y, 2, r.h, th.accent, 255)
    U.rect(r.x + r.w, r.y, 2, r.h, th.accent, 255)
  end

  function S.draw(ctx)
    local th, U, be = ctx.th, ctx.U, ctx.provider
    local L = S.layout(ctx.W, ctx.H)
    local st = be:state(held)
    local f = fields()
    local cur = f[focus]
    U.text(
      L.header.x,
      L.header.y + 8,
      string.format("CHANNELS %d-%d", page * 8 + 1, page * 8 + 8),
      th.accent,
      1
    )
    button(U, th, L.prev, "<", false)
    button(U, th, L.next, ">", false)
    for k = 1, PER_PAGE do
      local s, i = L.strips[k], slot_of(k)
      local muted = (st.mute >> (i - 1)) & 1 == 1
      local solo = (st.solo >> (i - 1)) & 1 == 1
      U.panel(s.x, s.y, s.w, s.h, th.panel, 255, (drag and drag.slot == i) and th.accent or nil)
      local name = be.names[i] or ("CH " .. i)
      if #name > 9 then
        name = name:sub(1, 9)
      end
      U.textc(s.x + s.w / 2, s.y + 6, name, be.loaded[i] == false and th.dim or th.text, 1)
      button(U, th, s.mute, "M", muted, th.alert)
      button(U, th, s.solo, "S", solo, th.warn)
      U.rect(s.pan.x, s.pan.y, s.pan.w, s.pan.h, th.ring, 255)
      U.rect(s.pan.x + math.floor(s.pan.w / 2), s.pan.y, 1, s.pan.h, th.dim, 255)
      local px = s.pan.x + math.floor((st.pan[i] + 1) / 2 * (s.pan.w - 6))
      U.rect(px, s.pan.y + 2, 6, s.pan.h - 4, th.accent2, 255)
      fader(U, th, s.track, st.gain[i], drag and drag.slot == i and drag.kind == "gain")
      meter(U, th, s.meter, st.l[i], st.r[i])
      U.textc(s.x + s.w / 2, s.db_y, T.db_text(st.gain[i]), th.dim, 1)
      if cur and cur.k == k then
        local r = (cur.kind == "gain") and s.track or s[cur.kind]
        outline(U, th, r)
        if adjusting then
          U.textc(s.x + s.w / 2, s.y + s.h - 36, "ADJ", th.accent, 1)
        end
      end
    end
    local m = L.master
    U.panel(m.x, m.y, m.w, m.h, th.panel2, 255, th.accent)
    U.textc(m.x + m.w / 2, m.y + 6, "MASTER", th.accent, 1)
    fader(U, th, m.track, st.master, drag and drag.kind == "master")
    local peak = 0
    for i = 1, SLOTS do
      peak = math.max(peak, st.l[i], st.r[i])
    end
    meter(U, th, m.meter, peak, peak)
    U.textc(m.x + m.w / 2, m.db_y, T.db_text(st.master), th.dim, 1)
    if cur and cur.kind == "master" then
      outline(U, th, m.track)
    end
  end

  -- For the e2e test: what the strips show right now (slot -> gain, pan, mute, solo).
  function S.readback(be)
    return be:state(held)
  end

  return S
end
