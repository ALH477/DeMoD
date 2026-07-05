-- SPDX-License-Identifier: MPL-2.0
-- demod-quanta panel for demod-ui (spec §10) — Copyright (c) 2026 DeMoD LLC
--
-- Logon-diagram score browser + exploration transport for the quanta engine.
-- Run:  ./demod-ui ui/quanta_panel.lua
--
-- Score data: loads ui/score.lua if present (emit one with
--   quanta-freeze score.qsc --lua ui/score.lua
-- ), else falls back to a small built-in demo score.
--
-- DCF wiring (ops 0x40..0x4F, spec §9) is stubbed where marked; the panel is
-- fully functional as a browser without the bridge.

-- ---------------- score ----------------
local ok, score = pcall(dofile, "ui/score.lua")
if not ok or type(score) ~= "table" then
  score = { sr = 48000, len = 144000, voices = 8, seed = "0xDEC0DE", atoms = {} }
  math.randomseed(1477)
  for i = 0, 119 do
    local on = math.random(0, 120000)
    score.atoms[#score.atoms+1] = {
      r = i, o = on, d = ({1024,4096,16384})[math.random(3)],
      f = 55 * 2^(math.random(0, 84)/12),
      a = 0.03 + 0.5*math.random()^2,
      l = (math.random() < 0.2) and 1 or 0 }
  end
end
local NA = #score.atoms

-- ---------------- state ----------------
local S = {
  k        = NA,          -- rank gate (exploration K)
  playing  = false,
  play_t0  = 0,
  ab       = false,       -- A/B: true = source monitor
  analyzing = false,
  progress = 0,
  hover    = nil,
  guitar   = dm.width() <= 320,
}

local tq, vi = dm.color.turquoise, dm.color.violet
local wh, dg = dm.color.white, dm.color.dark_gray
local W, H  = dm.width(), dm.height()

-- diagram rect (filled by layout below)
local DIA = { x = 12, y = 84, w = W - 24, h = H - 150 }

-- log-frequency y mapping, 32 Hz .. 16 kHz
local F_LO, F_HI = 32, 16000
local function fy(f)
  if f < F_LO then f = F_LO elseif f > F_HI then f = F_HI end
  local t = (math.log(f) - math.log(F_LO)) / (math.log(F_HI) - math.log(F_LO))
  return DIA.y + DIA.h * (1 - t)
end
local function tx(samp)
  return DIA.x + DIA.w * (samp / score.len)
end

-- ---------------- DCF stubs (spec §9) ----------------
local function dcf_send(op, payload)
  -- TODO(bridge): frame as 17-byte DCF header + payload, UDP :7777
  -- 0x40 ANALYZE_REQ | 0x43 LOAD | 0x44 PARAM | 0x45 AB | 0x46 FREEZE_REQ
  print(string.format("[dcf stub] op=0x%02X %s", op, payload or ""))
end

-- ---------------- widgets ----------------
local root = dm.root()

local title = dm.label("title", "QUANTA  //  " .. NA .. " atoms  " ..
                       score.voices .. " voices  seed " .. tostring(score.seed))
title:set_bounds(12, 8, W - 24, 20)
title:set_fg(vi[1], vi[2], vi[3])
root:add_child(title)

local status = dm.label("status", "score loaded — exploring")
status:set_bounds(12, 28, W - 24, 16)
status:set_fg(wh[1], wh[2], wh[3])
root:add_child(status)

local klab
if not S.guitar then
  local bar = dm.panel("bar"); bar:set_bounds(12, 48, W - 24, 30)
  bar:set_bg(dg[1], dg[2], dg[3]); bar:set_layout("hbox", 6, 3)
  root:add_child(bar)

  local b_an = dm.button("b_an", "ANALYZE")
  b_an:set_bounds(0, 0, 90, 0)
  b_an:on_click(function()
    S.analyzing, S.progress = true, 0
    status:set_text("analyzing… (DCF 0x40)")
    dcf_send(0x40, "src=live")
  end)
  bar:add_child(b_an)

  local b_fz = dm.button("b_fz", "FREEZE")
  b_fz:set_bounds(0, 0, 90, 0)
  b_fz:on_click(function()
    status:set_text(string.format("freeze requested at K=%d (DCF 0x46)", S.k))
    dcf_send(0x46, "K=" .. S.k)
  end)
  bar:add_child(b_fz)

  local b_ab = dm.button("b_ab", "A/B: MODEL")
  b_ab:set_bounds(0, 0, 110, 0)
  b_ab:on_click(function(w)
    S.ab = not S.ab
    w:set_text(S.ab and "A/B: SOURCE" or "A/B: MODEL")
    dcf_send(0x45, S.ab and "src" or "model")
  end)
  bar:add_child(b_ab)

  local b_pl = dm.button("b_pl", "PLAY")
  b_pl:set_bounds(0, 0, 70, 0)
  b_pl:on_click(function(w)
    S.playing = not S.playing
    if S.playing then S.play_t0 = dm.time() end
    w:set_text(S.playing and "STOP" or "PLAY")
  end)
  bar:add_child(b_pl)

  local prog = dm.progress("prog", 0)
  prog:set_bounds(0, 0, 140, 0)
  bar:add_child(prog)
end

-- K slider row
local ky = S.guitar and 48 or (H - 58)
klab = dm.label("klab", "K = " .. S.k)
klab:set_bounds(12, ky, 110, 18)
klab:set_fg(tq[1], tq[2], tq[3])
root:add_child(klab)

local kslider = dm.slider("k", 1, NA, NA)
kslider:set_bounds(126, ky, W - 138, 18)
kslider:on_change(function(w)
  S.k = math.floor(w:get_value() + 0.5)
  klab:set_text("K = " .. S.k)
  dcf_send(0x44, "K=" .. S.k)          -- PARAM: rank gate
  dm.redraw()
end)
root:add_child(kslider)

if S.guitar then
  DIA = { x = 6, y = 74, w = W - 12, h = H - 82 }
else
  DIA = { x = 12, y = 84, w = W - 24, h = H - 150 }
end

-- ---------------- per-frame ----------------
function on_update(dt)
  if S.analyzing then
    S.progress = S.progress + dt * 0.5
    local p = dm.find("prog")
    if p then p:set_value(math.min(S.progress, 1)) end
    if S.progress >= 1 then
      S.analyzing = false
      status:set_text("analysis complete — score ready (DCF 0x42)")
    end
    dm.redraw()
  end
  if S.playing then dm.redraw() end

  -- hover inspection: nearest atom within 10 px
  local mx, my = dm.mouse_x(), dm.mouse_y()
  local best, bd = nil, 100
  if mx >= DIA.x and mx <= DIA.x + DIA.w and my >= DIA.y and my <= DIA.y + DIA.h then
    for i = 1, NA do
      local a = score.atoms[i]
      local ax0, ax1, ay = tx(a.o), tx(a.o + a.d), fy(a.f)
      if mx >= ax0 - 4 and mx <= ax1 + 4 then
        local d2 = (my - ay) * (my - ay)
        if d2 < bd then bd, best = d2, a end
      end
    end
  end
  if best ~= S.hover then
    S.hover = best
    if best then
      status:set_text(string.format(
        "atom r=%d  %.1f Hz  %.0f ms  amp %.3f  layer %d%s",
        best.r, best.f, best.d / score.sr * 1000, best.a, best.l,
        best.r >= S.k and "  [gated]" or ""))
    end
    dm.redraw()
  end
end

-- ---------------- diagram ----------------
function on_draw()
  local bk = dm.color.black
  dm.draw.rect(DIA.x, DIA.y, DIA.w, DIA.h, 16, 16, 26)

  -- octave grid
  local f = 64
  while f <= F_HI do
    local y = fy(f)
    dm.draw.line(DIA.x, y, DIA.x + DIA.w, y, 42, 42, 62)
    dm.draw.text(DIA.x + 4, y - 12, f >= 1000 and (f/1000 .. "k") or tostring(f),
                 100, 100, 130)
    f = f * 2
  end

  -- atoms as logon strokes (LOD cap ~5000 draw ops)
  local cap = 5000
  for i = 1, math.min(NA, cap) do
    local a = score.atoms[i]
    local x0, x1, y = tx(a.o), tx(a.o + a.d), fy(a.f)
    if x1 - x0 < 2 then x1 = x0 + 2 end
    local c = (a.l == 1) and vi or tq
    local alpha = 40 + math.min(215, math.floor(a.a * 900))
    if a.r >= S.k then alpha = 18 end
    local th = (a.l == 1) and 3 or 2
    dm.draw.thick_line(x0, y, x1, y, th, c[1], c[2], c[3], alpha)
  end

  -- playhead
  if S.playing then
    local dur = score.len / score.sr
    local t = (dm.time() - S.play_t0) % dur
    local x = DIA.x + DIA.w * (t / dur)
    dm.draw.line(x, DIA.y, x, DIA.y + DIA.h, tq[1], tq[2], tq[3], 220)
  end

  -- hover marker
  if S.hover then
    local a = S.hover
    dm.draw.circle(tx(a.o), fy(a.f), 5, 232, 232, 240, 200)
  end

  -- Sierpinski seal, corner signature (depth 3: realtime-safe)
  local sx, sy = DIA.x + DIA.w - 34, DIA.y + DIA.h - 8
  dm.draw.sierpinski(sx, sy, sx + 26, sy, sx + 13, sy - 24, 3,
                     {10, 10, 15, 0}, {vi[1], vi[2], vi[3], 120})
end
