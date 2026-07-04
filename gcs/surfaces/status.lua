-- SPDX-License-Identifier: MPL-2.0
-- status.lua — battery / GPS / link / mode, and the event log.
local S = { name = "STATUS" }

function S.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "STATUS", th.accent, 2)
  local x, y, w = 24, 104, math.floor(W * 0.46)

  -- battery bar
  U.panel(x, y, w, 70, th.panel, 255, th.accent)
  U.text(x + 14, y + 10, "BATTERY", th.dim, 1)
  local bcol = (d.battery or 0) < 30 and th.alert or th.ok
  U.bar(x + 14, y + 36, w - 28, 20, (d.battery or 0) / 100, th.ring, bcol)
  U.textr(x + w - 14, y + 10, string.format("%.0f%%", d.battery or 0), bcol, 1)

  -- rows
  local rows = {
    { "Flight mode", tostring(d.mode or "?") },
    { "Armed", d.armed and "ARMED" or "disarmed" },
    { "GPS sats", tostring(d.sats or 0) },
    { "Link RSSI", string.format("%.0f%%", d.rssi or 0) },
    { "Ground speed", string.format("%.1f m/s", d.speed or 0) },
    { "Altitude", string.format("%.0f m", d.alt or 0) },
    { "Source", tostring(d.source or "?") },
  }
  local ry, lh = y + 90, 26
  U.panel(x, ry, w, #rows * lh + 20, th.panel, 255, th.accent2)
  for i, r in ipairs(rows) do
    local yy = ry + 12 + (i - 1) * lh
    U.text(x + 14, yy, r[1], th.dim, 1)
    U.textr(x + w - 14, yy, r[2], th.text, 1)
  end

  -- event log
  local lx = x + w + 16
  local lw = W - lx - 24
  U.panel(lx, y, lw, H - y - 48, th.panel, 255, th.accent2)
  U.text(lx + 14, y + 10, "EVENT LOG", th.dim, 1)
  local ev, n = ctx.events, #ctx.events
  for i = 1, math.min(12, n) do U.text(lx + 14, y + 34 + (i - 1) * 20, ev[n - i + 1] or "", th.text, 1) end
end

return S
