-- SPDX-License-Identifier: MPL-2.0
-- input.lua — where the pointer is and whether it is pressed.
--
-- Normally that is dm.mouse_x/y/down: a mouse, or the first finger on a
-- touchscreen through SDL's touch-to-mouse emulation. With
-- DEMOD_MIXER_GESTURES=<file.lua> it is a recorded gesture instead, replayed
-- by frame — how apps/mixer/test/mixer_e2e.sh drags a fader with no display.
-- The file returns function(layout) -> { {frame=N, x=, y=, down=bool}, ... };
-- each step holds until the next. The C path from an SDL event to
-- dm.mouse_down() is not exercised by that replay.
local I = { frame = 0 }
local script, steps, last

function I.load(layout_fn)
  local path = os.getenv("DEMOD_MIXER_GESTURES")
  if not path then
    return
  end
  script = dofile(path)
  I.layout_fn = layout_fn
end

function I.scripted()
  return script ~= nil
end

function I.tick()
  I.frame = I.frame + 1
end

-- -> x, y, down
function I.read()
  if not script then
    return dm.mouse_x(), dm.mouse_y(), (dm.mouse_down and dm.mouse_down()) or false
  end
  if not steps then
    steps = script(I.layout_fn(dm.width(), dm.height()))
  end
  for _, s in ipairs(steps) do
    if s.frame <= I.frame then
      last = s
    else
      break
    end
  end
  if not last then
    return -1, -1, false
  end
  return last.x, last.y, last.down == true
end

-- The last scripted frame, so a test run knows when it is done.
function I.last_frame()
  if not steps then
    return 0
  end
  return steps[#steps].frame
end

return I
