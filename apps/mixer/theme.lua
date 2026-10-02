-- SPDX-License-Identifier: MPL-2.0
-- theme.lua — graphite with an amber accent, legible on a rack panel in a dark
-- room ("night") and on a bench ("day"). Its own palette, not the reserved
-- DeMoD/TERMINUS phosphor trade dress.
return {
  night = {
    bg = { 14, 15, 18 },
    panel = { 28, 30, 35 },
    panel2 = { 44, 47, 54 },
    text = { 226, 228, 232 },
    dim = { 118, 122, 130 },
    accent = { 232, 168, 64 },
    accent2 = { 120, 176, 206 },
    ok = { 96, 196, 120 },
    warn = { 236, 190, 72 },
    alert = { 226, 84, 84 },
    ring = { 38, 41, 47 },
    needle = { 236, 238, 242 },
  },
  day = {
    bg = { 232, 233, 236 },
    panel = { 252, 252, 253 },
    panel2 = { 214, 217, 222 },
    text = { 22, 24, 30 },
    dim = { 104, 108, 118 },
    accent = { 176, 110, 10 },
    accent2 = { 40, 110, 150 },
    ok = { 36, 140, 70 },
    warn = { 176, 120, 0 },
    alert = { 196, 44, 44 },
    ring = { 204, 207, 214 },
    needle = { 28, 30, 36 },
  },
}
