-- SPDX-License-Identifier: MPL-2.0
-- taper_test.lua — plain `lua apps/mixer/test/taper_test.lua`. The fader law's
-- fixed points and its round trip, so a change to the curve is a decision.
local here = (arg and arg[0] or ""):match("^(.*/)") or "./"
local T = dofile(here .. "../taper.lua")
local fails = 0
local function check(name, ok)
  print((ok and "PASS: " or "FAIL: ") .. name)
  if not ok then
    fails = fails + 1
  end
end
local function near(a, b, e)
  return math.abs(a - b) <= (e or 1e-6)
end

check("bottom of travel is silence", T.pos_to_gain(0) == 0 and T.db_text(0) == "-inf")
check("unity at three quarters", near(T.pos_to_gain(0.75), 1.0))
check("top is demod-rt's maximum slot gain, 1.5", near(T.pos_to_gain(1), 1.5))
check("a quarter of the travel is -40 dB", near(T.pos_to_gain(0.25), 0.01, 1e-9))
local worst = 0
for k = 2, 200 do -- k = 1 is p = 0.005, inside the dead zone below
  local p = k / 200
  worst = math.max(worst, math.abs(T.gain_to_pos(T.pos_to_gain(p)) - p))
end
check(string.format("position -> gain -> position round-trips (worst %.2e)", worst), worst < 1e-9)
check("the bottom 0.5% is a dead zone a finger can find: silence", T.pos_to_gain(0.005) == 0)
check("one detent up from unity is +1.0 dB", T.db_text(T.step_db(1.0, 1)) == "+1.0")
check("detents stop at 1.5", near(T.step_db(1.5, 3), 1.5))
check("detents down from -60 dB reach silence", T.step_db(10 ^ (-60 / 20), -1) == 0)
os.exit(fails == 0 and 0 or 1)
