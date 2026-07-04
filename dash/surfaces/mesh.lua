-- SPDX-License-Identifier: MPL-2.0
-- mesh.lua — the DCF mesh link status + a node list + the event log.
local M = { name = "MESH" }

function M.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  U.text(24, 58, "DCF MESH", th.accent, 2)
  local st = ctx.dcf.available and ctx.dcf.status or "not built (DCF=0)"
  local stc = st == "connected" and th.ok or (st == "connecting" and th.warn or th.dim)
  U.text(24, 94, "link:", th.dim, 1)
  U.text(24 + dm.draw.text_width("link:") + 10, 94, st, stc, 1)
  U.textr(W - 24, 94, "source: " .. (d.source or "?"), d.ok and th.ok or th.warn, 1)

  -- node list (from the source; sim shows this node only)
  local y, lh = 130, 26
  local pw = math.floor(W * 0.46)
  local nodes = { { "this node", d.source or "?", "self" } }
  if d.bpm then nodes[#nodes + 1] = { "clock", tostring(d.bpm) .. " bpm", "sync" } end
  U.panel(24, y, pw, #nodes * lh + 30, th.panel, 255, th.accent)
  U.text(38, y + 8, "NODES", th.dim, 1)
  for i, nd in ipairs(nodes) do
    local ry = y + 30 + (i - 1) * lh
    U.text(38, ry, nd[1], th.text, 1)
    U.textr(24 + pw - 14, ry, nd[2] .. "  [" .. nd[3] .. "]", th.dim, 1)
  end

  -- event log
  local lx = 24 + pw + 16
  local lw = W - lx - 24
  U.panel(lx, y, lw, #nodes * lh + 30, th.panel, 255, th.accent2)
  U.text(lx + 14, y + 8, "EVENT LOG", th.dim, 1)
  local ev, n = ctx.events, #ctx.events
  for i = 1, math.min(6, n) do U.text(lx + 14, y + 30 + (i - 1) * 20, ev[n - i + 1] or "", th.text, 1) end
end

return M
