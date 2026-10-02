-- SPDX-License-Identifier: MPL-2.0
-- gestures.lua — the scripted session apps/mixer/test/mixer_e2e.sh replays:
-- drag channel 1 from unity down to a quarter of its travel, drag channel 2's
-- pan hard right, tap M on channel 3 and S on channel 4, push the master to
-- the top, flip to page 2 and push channel 9 to the top.
return function(L)
  local steps, f = {}, 20
  local function at(x, y, down)
    steps[#steps + 1] = { frame = f, x = x, y = y, down = down }
    f = f + 3
  end
  local function cx(r)
    return r.x + r.w // 2
  end
  local function cy(r)
    return r.y + r.h // 2
  end
  local function tap(r)
    at(cx(r), cy(r), true)
    at(cx(r), cy(r), false)
    f = f + 6
  end
  local function drag(x0, y0, x1, y1, n)
    for k = 0, n do
      at(math.floor(x0 + (x1 - x0) * k / n), math.floor(y0 + (y1 - y0) * k / n), true)
    end
    at(x1, y1, false)
    f = f + 6
  end

  local t1 = L.strips[1].track
  drag(cx(t1), t1.y + math.floor(t1.h * 0.25), cx(t1), t1.y + math.floor(t1.h * 0.75), 12)
  local p2 = L.strips[2].pan
  drag(cx(p2), cy(p2), p2.x + p2.w - 1, cy(p2), 8)
  tap(L.strips[3].mute)
  tap(L.strips[4].solo)
  local mt = L.master.track
  drag(cx(mt), mt.y + math.floor(mt.h * 0.25), cx(mt), mt.y - 6, 8)
  tap(L.next)
  drag(cx(t1), t1.y + math.floor(t1.h * 0.25), cx(t1), t1.y - 6, 8)
  return steps
end
