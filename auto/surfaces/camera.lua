-- SPDX-License-Identifier: MPL-2.0
-- camera.lua — the rear-view (backup) camera. A SAFETY surface: the shell marks
-- it non-preemptible on reverse and never locks it out. It blits the latest RGBA
-- frame written by camera.sh (ffmpeg v4l2/test source), or a "no signal"
-- placeholder, and always overlays static parking guidelines. This addresses the
-- FMVSS 111 rear-visibility function — see docs/automotive-compliance.md.
local C = { name = "CAMERA", safety = true }

local FRAME = os.getenv("DEMOD_CAMERA_FRAME") or "/tmp/demod-camera.rgba"
local CW, CH = 640, 360

local function read_frame()
  local f = io.open(FRAME, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close()
  if s and #s >= CW * CH * 4 then return s:sub(1, CW * CH * 4) end
  return nil
end

function C.draw(ctx)
  local th, U, W, H = ctx.th, ctx.U, ctx.W, ctx.H
  U.rect(0, 40, W, H - 40, {0, 0, 0}, 255)
  local ix = math.floor(W / 2 - CW / 2)
  local iy = math.floor((H + 40) / 2 - CH / 2)

  local fr = read_frame()
  if fr then
    dm.draw.blit(ix, iy, CW, CH, fr)
  else
    U.panel(ix, iy, CW, CH, th.panel, 255, nil)
    U.textc(W / 2, iy + CH / 2 - 8, "REAR VIEW - no signal", th.dim, 2)
    U.textc(W / 2, iy + CH / 2 + 22, "connect a camera ($DEMOD_CAMERA_DEV)", th.dim, 1)
  end

  -- static parking guidelines (near red / mid amber / far green)
  local gy0, gy1 = iy + CH - 24, iy + 48
  local function guide(off, col)
    dm.draw.thick_line(math.floor(W / 2 - 150 + off), gy0, math.floor(W / 2 - 64 + off), gy1,
      3, col[1], col[2], col[3], 220)
    dm.draw.thick_line(math.floor(W / 2 + 150 - off), gy0, math.floor(W / 2 + 64 - off), gy1,
      3, col[1], col[2], col[3], 220)
  end
  guide(0, th.alert); guide(42, th.warn); guide(84, th.ok)

  -- reverse banner
  U.rect(0, 44, W, 30, th.alert, 235)
  U.textc(W / 2, 51, "REVERSE   -   REAR CAMERA", {20, 20, 20}, 1)
end

return C
