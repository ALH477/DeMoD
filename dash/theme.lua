-- SPDX-License-Identifier: MPL-2.0
-- dash/theme.lua — a neutral slate look (periwinkle accent). Its own palette,
-- not the reserved DeMoD/TERMINUS phosphor trade dress.
return {
  night = {
    bg = {12,14,18}, panel = {24,28,34}, panel2 = {36,42,50}, text = {228,232,238},
    dim = {120,128,138}, accent = {120,160,220}, accent2 = {210,180,120},
    ok = {90,190,110}, warn = {235,185,80}, alert = {224,90,90},
    ring = {40,46,54}, needle = {235,240,245},
  },
  day = {
    bg = {234,236,240}, panel = {255,255,255}, panel2 = {222,226,232}, text = {24,28,36},
    dim = {110,116,126}, accent = {50,100,180}, accent2 = {170,120,40},
    ok = {40,150,80}, warn = {190,130,0}, alert = {200,50,50},
    ring = {206,210,218}, needle = {30,36,46},
  },
}
