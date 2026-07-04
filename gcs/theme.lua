-- SPDX-License-Identifier: MPL-2.0
-- gcs/theme.lua — an aviation look (green accent, amber warn). Own palette.
return {
  night = {
    bg = {8,12,10}, panel = {18,26,22}, panel2 = {28,40,32}, text = {228,236,230},
    dim = {110,128,116}, accent = {110,205,130}, accent2 = {240,200,90},
    ok = {110,205,130}, warn = {240,200,90}, alert = {235,95,85},
    ring = {36,48,40}, needle = {236,242,236},
    sky = {44,62,92}, ground = {74,58,40},
  },
  day = {
    bg = {232,238,234}, panel = {255,255,255}, panel2 = {220,230,222}, text = {20,30,24},
    dim = {100,120,106}, accent = {30,140,70}, accent2 = {180,130,20},
    ok = {30,140,70}, warn = {180,120,0}, alert = {200,50,45},
    ring = {204,214,206}, needle = {24,34,26},
    sky = {150,180,210}, ground = {150,130,100},
  },
}
