-- SPDX-License-Identifier: MPL-2.0
-- companion.lua — the vehicle-companion-computer view: telemetry aggregation,
-- the DCF mesh link, and an event log. This is the "computation mode".
local C = { name = "COMPANION" }

function C.draw(ctx)
  local th, U, W, H, v = ctx.th, ctx.U, ctx.W, ctx.H, ctx.veh
  U.text(24, 58, "VEHICLE COMPANION COMPUTER", th.accent, 2)

  -- link line
  local d = ctx.dcf
  local st = d.available and d.status or "not built (DCF=0)"
  local stcol = st == "connected" and th.ok or (st == "connecting" and th.warn or th.dim)
  U.text(24, 94, "DCF mesh:", th.dim, 1)
  U.text(24 + dm.draw.text_width("DCF mesh:") + 10, 94, st, stcol, 1)
  U.textr(W - 24, 94, "telemetry: " .. v.source, v.ok and th.ok or th.warn, 1)

  -- telemetry snapshot (left)
  local rows = {
    { "Source", v.source },
    { "Speed", string.format("%.0f km/h", v.speed) },
    { "RPM", string.format("%.0f", v.rpm) },
    { "Coolant", string.format("%.0f C", v.coolant) },
    { "Fuel", string.format("%.0f %%", v.fuel) },
    { "Battery", string.format("%.1f V", v.volts) },
    { "Throttle", string.format("%.0f %%", v.throttle) },
  }
  local x, y, lh = 24, 124, 26
  local pw = math.floor(W * 0.46)
  local ph = #rows * lh + 22
  U.panel(x, y, pw, ph, th.panel, 255, th.accent)
  U.text(x + 14, y + 8, "TELEMETRY", th.dim, 1)
  for i, r in ipairs(rows) do
    local ry = y + 30 + (i - 1) * lh
    U.text(x + 14, ry, r[1], th.dim, 1)
    U.textr(x + pw - 14, ry, r[2], th.text, 1)
  end

  -- event log (right)
  local lx = x + pw + 16
  local lw = W - lx - 24
  U.panel(lx, y, lw, ph, th.panel, 255, th.accent2)
  U.text(lx + 14, y + 8, "EVENT LOG", th.dim, 1)
  local ev = ctx.events
  local n = #ev
  local shown = math.min(math.floor((ph - 34) / 20), n)
  for i = 1, shown do
    U.text(lx + 14, y + 30 + (i - 1) * 20, ev[n - i + 1] or "", th.text, 1)
  end
end

function C.nav(_, _) return false end

return C
