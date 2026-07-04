-- SPDX-License-Identifier: MPL-2.0
-- rov/theme.lua — a deep-subsea look (blue accent). Own palette.
return {
  night = {
    bg = {6,12,20}, panel = {16,26,38}, panel2 = {24,38,54}, text = {224,232,240},
    dim = {104,120,138}, accent = {80,150,220}, accent2 = {230,180,90},
    ok = {80,190,120}, warn = {235,185,80}, alert = {224,90,90},
    ring = {30,44,60}, needle = {232,240,248},
  },
  day = {
    bg = {228,236,244}, panel = {255,255,255}, panel2 = {216,226,238}, text = {18,28,40},
    dim = {96,112,132}, accent = {30,100,180}, accent2 = {180,120,20},
    ok = {30,150,90}, warn = {180,120,0}, alert = {200,50,50},
    ring = {200,212,224}, needle = {22,34,48},
  },
}
