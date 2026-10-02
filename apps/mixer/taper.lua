-- SPDX-License-Identifier: MPL-2.0
-- taper.lua — fader position (0..1) <-> linear gain (0..1.5, demod-rt's slot
-- gain range). Unity sits at 3/4 of the travel, as on a console, so the top
-- quarter is +0..+3.5 dB of headroom and the rest -60..0 dB; the bottom is
-- silence. Pure functions; apps/mixer/test/taper_test.lua checks the round trip.
local T = {}

T.UNITY = 0.75
T.GMAX = 1.5
T.MAX_DB = 20 * math.log(1.5, 10) -- +3.52 dB
T.MIN_DB = -60

local function db(g)
  return 20 * math.log(g, 10)
end

function T.pos_to_gain(p)
  if p <= 0.005 then
    return 0.0
  end
  if p > 1 then
    p = 1
  end
  local d
  if p >= T.UNITY then
    d = (p - T.UNITY) / (1 - T.UNITY) * T.MAX_DB
  else
    d = T.MIN_DB + (p / T.UNITY) * -T.MIN_DB
  end
  return math.min(T.GMAX, 10 ^ (d / 20))
end

function T.gain_to_pos(g)
  if g <= 10 ^ (T.MIN_DB / 20) then
    return 0.0
  end
  local d = db(math.min(g, T.GMAX))
  if d >= 0 then
    return math.min(1.0, T.UNITY + d / T.MAX_DB * (1 - T.UNITY))
  end
  return (d - T.MIN_DB) / -T.MIN_DB * T.UNITY
end

-- One encoder detent: +/- 1 dB from the current gain, through the same range.
function T.step_db(g, steps)
  if g <= 10 ^ (T.MIN_DB / 20) then
    return steps > 0 and 10 ^ (T.MIN_DB / 20) or 0.0
  end
  local d = db(g) + steps
  if d < T.MIN_DB then
    return 0.0
  end
  return math.min(T.GMAX, 10 ^ (d / 20))
end

function T.db_text(g)
  if g <= 10 ^ (T.MIN_DB / 20) then
    return "-inf"
  end
  return string.format("%+.1f", db(g))
end

return T
