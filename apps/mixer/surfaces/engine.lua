-- SPDX-License-Identifier: MPL-2.0
-- engine.lua — what the mixer is connected to and how it is doing: the link,
-- health (alive, CPU, xruns), the sixteen slots with their bypass, the tempo.
-- Health and the slot list need replies, so they exist for a local engine only;
-- a remote one (DCF) answers accepted/refused and nothing else, and this page
-- says so instead of showing zeros.
return function(deps)
  local input = deps.input
  local S = { name = "ENGINE" }
  local press, was_down = nil, false

  function S.layout(W, H)
    local L = { slots = {} }
    local x0, y0 = 16, 92
    local colw = math.floor((W - 48) / 2)
    local rows = 8
    local rh = math.max(22, math.floor((H - 40 - y0 - 70) / rows))
    for i = 1, 16 do
      local c, r = (i - 1) // rows, (i - 1) % rows
      L.slots[i] = { x = x0 + c * (colw + 16), y = y0 + r * rh, w = colw, h = rh - 4 }
    end
    local by = H - 40 - 52
    L.bpm_dn = { x = 16, y = by, w = 56, h = 40 }
    L.bpm_up = { x = 196, y = by, w = 56, h = 40 }
    return L
  end

  local function inside(r, x, y)
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
  end

  function S.update(dt, ctx)
    local be, L = ctx.provider, S.layout(ctx.W, ctx.H)
    local x, y, down = input.read()
    if down and not was_down then
      press = nil
      for i = 1, 16 do
        if inside(L.slots[i], x, y) then
          press = { kind = "bypass", slot = i, r = L.slots[i] }
        end
      end
      if inside(L.bpm_dn, x, y) then
        press = { kind = "bpm", d = -1, r = L.bpm_dn }
      end
      if inside(L.bpm_up, x, y) then
        press = { kind = "bpm", d = 1, r = L.bpm_up }
      end
    elseif not down and was_down and press then
      if inside(press.r, x, y) then
        if press.kind == "bypass" then
          local on = (be.bypass >> (press.slot - 1)) & 1 == 0
          be:op({ op = "bypass_fx", slot = press.slot - 1, on = on })
        else
          be:op({ op = "set_bpm", bpm = math.max(20, be.shadow.bpm + press.d) })
        end
      end
      press = nil
    end
    was_down = down
  end

  function S.draw(ctx)
    local th, U, be, W = ctx.th, ctx.U, ctx.provider, ctx.W
    local L = S.layout(ctx.W, ctx.H)
    U.text(16, 54, be:label(), be.kind == "sim" and th.alert or th.accent, 1)
    if be.err and be.kind ~= "sim" then
      U.text(16, 70, be.err, th.warn, 1)
    end
    local h = be.health
    if be.kind == "local" and h then
      U.textr(
        W - 16,
        54,
        string.format(
          "%s  cpu %.0f%%  xruns %d",
          h.alive and "ALIVE" or "NOT RUNNING",
          (h.cpu_load or 0) * 100,
          h.xruns or 0
        ),
        h.alive and th.ok or th.alert,
        1
      )
    elseif be.kind == "remote" then
      U.textr(W - 16, 54, "remote: meters and ops only", th.dim, 1)
    end
    for i = 1, 16 do
      local r = L.slots[i]
      local byp = (be.bypass >> (i - 1)) & 1 == 1
      U.rect(r.x, r.y, r.w, r.h, th.panel, 255)
      local name = be.names[i] or ((be.loaded[i] == false) and "(empty)" or ("slot " .. i))
      U.text(
        r.x + 8,
        r.y + math.floor(r.h / 2) - 4,
        string.format("%2d  %s", i, name),
        be.loaded[i] == false and th.dim or th.text,
        1
      )
      U.textr(
        r.x + r.w - 8,
        r.y + math.floor(r.h / 2) - 4,
        byp and "BYPASS" or "on",
        byp and th.warn or th.ok,
        1
      )
    end
    U.rect(L.bpm_dn.x, L.bpm_dn.y, L.bpm_dn.w, L.bpm_dn.h, th.panel2, 255)
    U.textc(L.bpm_dn.x + L.bpm_dn.w / 2, L.bpm_dn.y + 16, "-", th.text, 2)
    U.textc(134, L.bpm_dn.y + 12, string.format("%.0f BPM", be.shadow.bpm), th.text, 2)
    U.rect(L.bpm_up.x, L.bpm_up.y, L.bpm_up.w, L.bpm_up.h, th.panel2, 255)
    U.textc(L.bpm_up.x + L.bpm_up.w / 2, L.bpm_up.y + 16, "+", th.text, 2)
    U.textr(
      W - 16,
      L.bpm_dn.y + 14,
      string.format("ops sent %d  refused %d", be.sent, be.refused),
      be.refused > 0 and th.warn or th.dim,
      1
    )
  end

  return S
end
