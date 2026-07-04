-- SPDX-License-Identifier: MPL-2.0
-- media.lua — the Audio/Media surface: an out-of-engine music player (driven by
-- auto/media.sh over a command FIFO + a state file) and a 3-band EQ that drives
-- the audio engine over the control socket (dm.ctl_set_param on a configurable
-- slot; a no-op if no engine is up). Cursor spans transport + EQ.
local M = { name = "MEDIA", cursor = 1 }

local STATE   = os.getenv("DEMOD_MEDIA_STATE") or "/tmp/demod-media.kv"
local CMD     = os.getenv("DEMOD_MEDIA_CMD") or "/tmp/demod-media.cmd"
local EQ_SLOT = tonumber(os.getenv("DEMOD_EQ_SLOT") or "0")
local BANDS   = { "low", "mid", "high" }
local eq      = { low = 50, mid = 50, high = 50 }   -- 0..100

local function read_state()
  local f = io.open(STATE, "r"); if not f then return {} end
  local s = f:read("*a"); f:close()
  local t = {}
  for k, v in (s or ""):gmatch("(%w+)=([^%s]+)") do t[k] = v end
  return t
end

local function send(cmd)
  local f = io.open(CMD, "w"); if f then f:write(cmd .. "\n"); f:close() end
end

local function set_eq(ctx, i, val)
  eq[BANDS[i]] = val
  if dm.ctl_set_param then pcall(dm.ctl_set_param, EQ_SLOT, i - 1, val / 100) end
  ctx.log("EQ " .. BANDS[i] .. "=" .. val)
end

local function bump(ctx, i)
  local v = eq[BANDS[i]] + 25
  if v > 100 then v = 0 end
  set_eq(ctx, i, v)
end

function M.draw(ctx)
  local th, U, W, H = ctx.th, ctx.U, ctx.W, ctx.H
  local st = read_state()
  local playing = st.playing == "1"
  U.text(24, 58, "MEDIA", th.accent, 2)

  -- now playing
  U.panel(24, 100, W - 48, 90, th.panel, 255, th.accent2)
  U.text(40, 116, "NOW PLAYING", th.dim, 1)
  U.text(40, 142, st.title and st.title:gsub("_", " ") or "(no media)", th.text, 2)
  U.textr(W - 40, 116, (st.index or "0") .. "/" .. (st.count or "0"), th.dim, 1)
  U.textr(W - 40, 142, playing and "PLAYING" or "PAUSED", playing and th.ok or th.warn, 1)

  -- transport (cursor 1..3)
  local ty, bw, gap, bx = 210, 120, 20, 24
  local labels = { "|<<", playing and "||" or ">", ">>|" }
  for i = 1, 3 do
    local sel = M.cursor == i
    U.panel(bx, ty, bw, 56, sel and th.panel2 or th.panel, 255, sel and th.accent or nil)
    U.textc(bx + bw / 2, ty + 20, labels[i], sel and th.accent or th.text, 2)
    bx = bx + bw + gap
  end

  -- EQ (cursor 4..6)
  local ey, ex, ebw = 300, 24, 120
  U.text(24, ey, "EQUALIZER (slot " .. EQ_SLOT .. ")", th.dim, 1)
  for i = 1, 3 do
    local sel = M.cursor == 3 + i
    local val = eq[BANDS[i]]
    U.panel(ex, ey + 24, ebw, 150, sel and th.panel2 or th.panel, 255, sel and th.accent or nil)
    local barh, bx2, by = 100, ex + ebw / 2 - 12, ey + 40
    U.rect(bx2, by, 24, barh, th.ring, 255)
    local fh = math.floor(barh * val / 100)
    U.rect(bx2, by + barh - fh, 24, fh, th.accent, 255)
    U.textc(ex + ebw / 2, ey + 24 + 118, string.upper(BANDS[i]), th.dim, 1)
    U.textc(ex + ebw / 2, ey + 24 + 100, tostring(val), sel and th.accent2 or th.text, 1)
    ex = ex + ebw + 20
  end

  U.text(24, H - 52, "turn: select   press: act/adjust   media dir: $DEMOD_MEDIA_DIR", th.dim, 1)
end

function M.nav(action, ctx)
  if action == "prev" then M.cursor = (M.cursor - 2) % 6 + 1; return true end
  if action == "next" then M.cursor = M.cursor % 6 + 1; return true end
  if action == "activate" then
    if M.cursor == 1 then send("prev")
    elseif M.cursor == 2 then send("toggle")
    elseif M.cursor == 3 then send("next")
    else bump(ctx, M.cursor - 3) end
    return true
  end
  return false
end

function M.zones(ctx)
  local z = {}
  local ty, bw, gap, bx = 210, 120, 20, 24
  local acts = { "prev", "toggle", "next" }
  for i = 1, 3 do
    local a = acts[i]
    z[#z + 1] = { x = bx, y = ty, w = bw, h = 56, on = function() M.cursor = i; send(a) end }
    bx = bx + bw + gap
  end
  local ey, ex, ebw = 300, 24, 120
  for i = 1, 3 do
    local ii = i
    z[#z + 1] = { x = ex, y = ey + 24, w = ebw, h = 150,
      on = function() M.cursor = 3 + ii; bump(ctx, ii) end }
    ex = ex + ebw + 20
  end
  return z
end

return M
