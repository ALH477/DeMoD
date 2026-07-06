-- SPDX-License-Identifier: MPL-2.0
--[[
  ar_hud.lua — AR passthrough HUD demo (needs an ARHUD=1 build; dm.ar).

  Opens a passthrough source (a camera/video feed decoded OUT OF PROCESS to raw
  RGBA — see tools/ar_testframe.sh) and composites it UNDER the UI as the base
  layer. The root is left empty so the feed shows through; the HUD is drawn as an
  overlay in on_draw(). Strings are ASCII-only (the 8x16 font renders nothing
  else); on_update() calls dm.redraw() so the reticle animation stays live.

  Run headless:
    tools/ar_testframe.sh /tmp/demod-ar.rgba
    SDL_VIDEODRIVER=dummy DEMOD_AR_FRAME=/tmp/demod-ar.rgba \
      DEMOD_SHOT=/tmp/out.ppm DEMOD_SHOT_FRAME=40 ./demod-ui examples/ar_hud.lua
]]

local FRAME = os.getenv("DEMOD_AR_FRAME") or "/tmp/demod-ar.rgba"

-- Optional stereo: DEMOD_AR_EYES=2 gives a side-by-side (Cardboard) view, and
-- DEMOD_AR_K1/K2 apply lens barrel-distortion per eye (e.g. K1=0.22 K2=0.24).
local EYES = tonumber(os.getenv("DEMOD_AR_EYES") or "1") or 1
local K1 = tonumber(os.getenv("DEMOD_AR_K1") or "0") or 0
local K2 = tonumber(os.getenv("DEMOD_AR_K2") or "0") or 0

if dm.ar then
  local ok, err = dm.ar.open({
    source = "file:" .. FRAME,
    w = 640,
    h = 360, -- producer frame size (must match the writer)
    fit = "cover", -- fill the framebuffer, cropping to preserve aspect
    alpha = 255, -- opaque base layer
    eyes = EYES, -- 1 = mono, 2 = side-by-side stereo
    k1 = K1,
    k2 = K2, -- lens barrel-distortion coefficients (0 = flat)
  })
  if not ok then
    print("[ar_hud] dm.ar.open failed: " .. tostring(err))
  end
else
  print("[ar_hud] dm.ar is absent — rebuild with 'make ARHUD=1'")
end

-- Optional 6DOF head tracking: DEMOD_AR_POSE=/path to a file of 7 float32
-- (pos x,y,z + quat x,y,z,w) written by an IMU/OpenXR bridge.
local POSE = os.getenv("DEMOD_AR_POSE")
if dm.pose and POSE then
  local ok, err = dm.pose.open({ source = "file:" .. POSE })
  if not ok then
    print("[ar_hud] dm.pose.open failed: " .. tostring(err))
  end
end

-- The root panel paints an opaque background over everything, so make it
-- transparent (alpha 0) — otherwise it would hide the passthrough feed. Keep
-- the root empty; the video is the background and the HUD is an on_draw overlay.
dm.root():set_bg(0, 0, 0, 0)

local t = 0
local pose = nil -- latest {x,y,z,qx,qy,qz,qw}

function on_pose(x, y, z, qx, qy, qz, qw)
  pose = { x, y, z, qx, qy, qz, qw }
end

function on_update(dt)
  t = t + (dt or 0)
  dm.redraw() -- animate the HUD even between input events
end

local TQ = { 0x00, 0xF5, 0xD4 } -- turquoise accent

local function crosshair(cx, cy)
  local g = 16
  dm.draw.line(cx - g, cy, cx - 4, cy, TQ[1], TQ[2], TQ[3], 255)
  dm.draw.line(cx + 4, cy, cx + g, cy, TQ[1], TQ[2], TQ[3], 255)
  dm.draw.line(cx, cy - g, cx, cy - 4, TQ[1], TQ[2], TQ[3], 255)
  dm.draw.line(cx, cy + 4, cx, cy + g, TQ[1], TQ[2], TQ[3], 255)
  dm.draw.circle(cx, cy, 3, TQ[1], TQ[2], TQ[3], 255)
end

function on_draw()
  local W, H = dm.width(), dm.height()
  local cx, cy = math.floor(W / 2), math.floor(H / 2)

  crosshair(cx, cy)

  -- corner brackets (framing reticle)
  local m, b = 24, 28
  dm.draw.line(m, m, m + b, m, TQ[1], TQ[2], TQ[3], 200)
  dm.draw.line(m, m, m, m + b, TQ[1], TQ[2], TQ[3], 200)
  dm.draw.line(W - m, m, W - m - b, m, TQ[1], TQ[2], TQ[3], 200)
  dm.draw.line(W - m, m, W - m, m + b, TQ[1], TQ[2], TQ[3], 200)

  -- telemetry readout (ASCII only)
  dm.draw.text(m, H - 40, "AR HUD  ALT 120M  HDG 045  SPD 12KT", TQ[1], TQ[2], TQ[3], 255, 2)

  -- head-tracking pose readout (when a dm.pose source is attached)
  if pose then
    local s =
      string.format("POSE  X %.2f  Y %.2f  Z %.2f  QW %.2f", pose[1], pose[2], pose[3], pose[7])
    dm.draw.text(m, m + 40, s, TQ[1], TQ[2], TQ[3], 220, 1)
  end

  -- a blinking REC dot to prove the frame is live
  if math.floor(t * 2) % 2 == 0 then
    dm.draw.circle(W - m - 6, H - 30, 6, 0xFF, 0x4C, 0x6A, 255)
    dm.draw.text(W - m - 60, H - 38, "REC", 0xFF, 0x4C, 0x6A, 255, 2)
  end
end
