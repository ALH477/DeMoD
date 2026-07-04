-- SPDX-License-Identifier: MPL-2.0
-- dive.lua — depth + heading + attitude + thruster outputs.
local D = { name = "DIVE" }

function D.draw(ctx)
  local th, U, W, H, d = ctx.th, ctx.U, ctx.W, ctx.H, ctx.data
  -- depth (big, left) with a vertical gauge
  local dmax = 50
  U.text(24, 58, "DEPTH", th.dim, 1)
  U.textc(150, 100, string.format("%.1f", d.depth or 0), th.text, 6)
  U.textc(150, 172, "meters", th.dim, 1)
  local gx, gy, gh = 300, 90, H - 200
  U.rect(gx, gy, 26, gh, th.ring, 255)
  local fy = math.floor(gh * U.clamp((d.depth or 0) / dmax, 0, 1))
  U.rect(gx, gy, 26, fy, th.accent, 255)
  U.text(gx - 4, gy + gh + 10, "0", th.dim, 1)
  U.textr(gx + 26, gy + gh + 10, tostring(dmax) .. "m", th.dim, 1)

  -- heading + attitude (right)
  local rx = math.floor(W * 0.5)
  U.panel(rx, 90, W - rx - 24, 90, th.panel, 255, th.accent)
  U.text(rx + 16, 100, "HEADING", th.dim, 1)
  U.textc(rx + (W - rx - 24) / 2, 124, string.format("%03.0f", d.heading or 0), th.text, 4)
  U.panel(rx, 196, W - rx - 24, 96, th.panel, 255, th.accent2)
  U.text(rx + 16, 206, "ATTITUDE", th.dim, 1)
  U.text(rx + 16, 236, string.format("pitch % .0f", d.pitch or 0), th.text, 2)
  U.text(rx + 16, 262, string.format("roll  % .0f", d.roll or 0), th.text, 2)
  U.textr(W - 40, 236, string.format("%.1f C", d.temp or 0), th.dim, 1)

  -- thruster bars (bottom)
  local tr = d.thrusters or {}
  local n = #tr
  if n > 0 then
    U.text(24, H - 120, "THRUSTERS", th.dim, 1)
    local x, bw = 24, math.floor((W - 48 - (n - 1) * 12) / n)
    for i = 1, n do
      U.panel(x, H - 100, bw, 60, th.panel, 255, nil)
      U.bar(x + 8, H - 74, bw - 16, 16, U.clamp(tr[i], 0, 1), th.ring, th.accent)
      U.textc(x + bw / 2, H - 96, "T" .. i, th.dim, 1)
      x = x + bw + 12
    end
  end
end

return D
