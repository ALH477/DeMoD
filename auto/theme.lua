-- SPDX-License-Identifier: MPL-2.0
-- theme.lua — DeMoD Auto's own neutral automotive palettes (day/night).
-- Deliberately NOT the reserved DeMoD/TERMINUS phosphor identity (no
-- turquoise-on-black + violet + CRT/Sierpinski combination): a generic
-- amber/blue automotive look, so this stays clean MPL-2.0.
-- Colors are {r,g,b}.
return {
  night = {
    bg      = {  8, 10, 14 },
    panel   = { 20, 24, 32 },
    panel2  = { 30, 35, 46 },
    text    = { 232, 235, 240 },
    dim     = { 120, 128, 140 },
    accent  = {  45, 156, 219 },   -- automotive blue (#2D9CDB)
    accent2 = { 255, 176,  32 },   -- amber (#FFB020)
    ok      = {  80, 190, 110 },
    warn    = { 255, 176,  32 },
    alert   = { 224,  80,  80 },
    ring    = {  44,  50,  62 },   -- unfilled gauge track
    needle  = { 240, 244, 250 },
  },
  day = {
    bg      = { 236, 238, 242 },
    panel   = { 255, 255, 255 },
    panel2  = { 224, 228, 234 },
    text    = {  24,  28,  36 },
    dim     = { 110, 116, 128 },
    accent  = {  20, 120, 190 },
    accent2 = { 196, 120,   0 },
    ok      = {  40, 150,  80 },
    warn    = { 200, 130,   0 },
    alert   = { 200,  50,  50 },
    ring    = { 205, 210, 218 },
    needle  = {  30,  36,  46 },
  },
}
