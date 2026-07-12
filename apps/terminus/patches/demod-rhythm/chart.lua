-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-rhythm/chart.lua — pure beat-map generation + hit judging.

  No dm.* / no display: this is the testable core of RHYTHM. A seed deterministically
  reproduces a whole track (LCG, same family as demod-learn/theory.lua phrase()), and
  judge() classifies a strike's timing. Runs under the embedded interpreter:

      ~/demod-ui/demod-ui patches/demod-rhythm/selftest.lua

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local floor = math.floor

local C = {}

-- C-major pentatonic over the root: always consonant, never a wrong note.
C.ROOT = 48 -- C3
C.SCALE = { 0, 2, 4, 7, 9 } -- maj pentatonic degrees
C.LANES = 3

-- Timing windows, in SECONDS of absolute error at the hit-line.
C.WINDOW = { perfect = 0.045, good = 0.110 }

-- map a (lane, scale-degree) pair to a MIDI note: higher lanes => higher octave.
local function note_for(lane, deg_idx)
	return C.ROOT + 12 * lane + C.SCALE[deg_idx]
end

--[[ generate(seed, bars, opts) -> ordered list of { beat, lane, note }
  beat is in beats from 0 (monotonic non-decreasing); lane is 0..LANES-1.
  opts: { beats_per_bar=4, subdiv=2, density=0.55 }  (density = on-beat note chance) ]]
function C.generate(seed, bars, opts)
	opts = opts or {}
	local bpb = opts.beats_per_bar or 4
	local subdiv = opts.subdiv or 2 -- slots per beat (2 = eighth notes)
	local density = opts.density or 0.55
	bars = bars or 16

	local s = (seed or 1) % 2147483647
	if s <= 0 then
		s = s + 2147483646
	end
	local function rnd()
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end

	local notes = {}
	local last_lane = -1
	for bar = 0, bars - 1 do
		for b = 0, bpb - 1 do
			for sd = 0, subdiv - 1 do
				-- offbeats are sparser than downbeats so it stays readable
				local p = (sd == 0) and density or density * 0.45
				if rnd() < p then
					local lane = floor(rnd() * C.LANES) % C.LANES
					-- avoid long runs in one lane
					if lane == last_lane and rnd() < 0.5 then
						lane = (lane + 1) % C.LANES
					end
					last_lane = lane
					local deg = 1 + (floor(rnd() * #C.SCALE) % #C.SCALE)
					notes[#notes + 1] = {
						beat = bar * bpb + b + sd / subdiv,
						lane = lane,
						note = note_for(lane, deg),
					}
				end
			end
		end
	end
	return notes
end

-- total length of a chart in beats (last note's beat, or 0)
function C.length(notes)
	local last = 0
	for _, n in ipairs(notes) do
		if n.beat > last then
			last = n.beat
		end
	end
	return last
end

--[[ judge(dbeat, bpm) -> "perfect" | "good" | "miss"
  dbeat = absolute beat-distance between the note and the strike moment. ]]
function C.judge(dbeat, bpm)
	local sec = math.abs(dbeat) * 60.0 / (bpm or 120)
	if sec <= C.WINDOW.perfect then
		return "perfect"
	elseif sec <= C.WINDOW.good then
		return "good"
	end
	return "miss"
end

return C
