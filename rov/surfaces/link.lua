-- SPDX-License-Identifier: MPL-2.0
-- link.lua — the surface<->sub DCF mesh / acoustic-link status + event log.
local L = { name = "LINK" }

function L.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "ACOUSTIC / DCF LINK", th.accent, 2)
  local st = ctx.dcf.available and ctx.dcf.status or "not built (DCF=0)"
  local stc = st == "connected" and th.ok or (st == "connecting" and th.warn or th.dim)
  U.text(24, 94, "mesh:", th.dim, 1)
  U.text(24 + dm.draw.text_width("mesh:") + 10, 94, st, stc, 1)
  U.textr(W - 24, 94, "source: " .. (d.source or "?"), d.ok and th.ok or th.warn, 1)

  local rows = {
    { "Transport", (d.source == "DCF/JANUS") and "JANUS (STANAG-4748)" or "simulated" },
    { "Depth", string.format("%.1f m", d.depth or 0) },
    { "Heading", string.format("%03.0f", d.heading or 0) },
    { "Altitude", string.format("%.1f m", d.altitude or 0) },
    { "Water temp", string.format("%.1f C", d.temp or 0) },
  }
  local x, y, w, lh = 24, 124, math.floor(W * 0.5), 26
  U.panel(x, y, w, #rows * lh + 20, th.panel, 255, th.accent)
  for i, r in ipairs(rows) do
    local yy = y + 12 + (i - 1) * lh
    U.text(x + 14, yy, r[1], th.dim, 1)
    U.textr(x + w - 14, yy, r[2], th.text, 1)
  end

  local lx = x + w + 16
  local lw = W - lx - 24
  U.panel(lx, y, lw, #rows * lh + 20, th.panel, 255, th.accent2)
  U.text(lx + 14, y + 8, "EVENT LOG", th.dim, 1)
  local ev, n = ctx.events, #ctx.events
  for i = 1, math.min(6, n) do U.text(lx + 14, y + 30 + (i - 1) * 20, ev[n - i + 1] or "", th.text, 1) end
end

return L
