-- SPDX-License-Identifier: MPL-2.0
-- util.lua — small draw helpers over dm.draw.* for DeMoD Auto. Only valid
-- inside on_draw (like all dm.draw calls).
local U = {}

local function rgba(col, a)
  return col[1], col[2], col[3], a or 255
end

function U.rect(x, y, w, h, col, a)
  dm.draw.rect(x, y, w, h, rgba(col, a))
end

-- A soft "panel": fill + a subtle top accent line.
function U.panel(x, y, w, h, col, a, accent)
  dm.draw.rect(x, y, w, h, rgba(col, a))
  if accent then dm.draw.rect(x, y, w, 2, rgba(accent, a)) end
end

-- NB: dm.draw.text takes scale AFTER the color, so the color must be expanded
-- explicitly (a call like text(..., rgba(col), scale) would truncate rgba's
-- multiple returns to one).
function U.text(x, y, s, col, scale, a)
  dm.draw.text(x, y, s, col[1], col[2], col[3], a or 255, scale or 1)
end

function U.textc(cx, y, s, col, scale, a)
  scale = scale or 1
  local w = dm.draw.text_width(s) * scale
  dm.draw.text(math.floor(cx - w / 2), y, s, col[1], col[2], col[3], a or 255, scale)
end

function U.textr(rx, y, s, col, scale, a)
  scale = scale or 1
  local w = dm.draw.text_width(s) * scale
  dm.draw.text(math.floor(rx - w), y, s, col[1], col[2], col[3], a or 255, scale)
end

-- A sweep-gauge arc from angle a0..a1 (radians, screen space: 0 = +x, CW as y
-- grows down), filled to `frac` (0..1). Drawn as thick_line segments since the
-- framebuffer has no arc primitive.
function U.arc(cx, cy, rad, a0, a1, frac, thick, track, fill, a)
  local segs = 48
  local fillseg = math.floor(segs * math.max(0, math.min(1, frac)) + 0.5)
  local px, py
  for i = 0, segs do
    local t = a0 + (a1 - a0) * (i / segs)
    local x = cx + math.cos(t) * rad
    local y = cy + math.sin(t) * rad
    if i > 0 then
      local col = (i <= fillseg) and fill or track
      dm.draw.thick_line(math.floor(px), math.floor(py), math.floor(x), math.floor(y), thick, rgba(col, a))
    end
    px, py = x, y
  end
end

-- A radial needle inside a gauge.
function U.needle(cx, cy, rad, a0, a1, frac, col, a)
  local t = a0 + (a1 - a0) * math.max(0, math.min(1, frac))
  dm.draw.thick_line(cx, cy,
    math.floor(cx + math.cos(t) * rad), math.floor(cy + math.sin(t) * rad), 3, rgba(col, a))
end

function U.clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

return U
