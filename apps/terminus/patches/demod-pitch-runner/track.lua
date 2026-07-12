-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-pitch-runner/track.lua — chart generation + combined judging.

  PURE Lua (no dm.*) so it unit-tests under the interpreter (see selftest.lua).
  Generates a deterministic, scale-constrained, instrument-range-constrained note
  chart, and judges a hit on BOTH timing (beats) and — in PERFORM mode — pitch
  accuracy (cents). In PRACTICE mode cents is nil (the played pitch is correct by
  construction) so judging is timing-only.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local HERE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*/)") or "./"
local INST = dofile(HERE .. "instruments.lua")

local floor, abs = math.floor, math.abs

local M = {}

M.WINDOW = { perfect = 0.045, good = 0.110 } -- seconds of timing error at the hit-line
M.CENTS = { perfect = 15, good = 35 } -- cents of pitch error (PERFORM only)

local function lcg(seed)
	local s = floor(seed or 1) % 2147483647
	if s <= 0 then
		s = s + 2147483646
	end
	return function()
		s = (s * 16807) % 2147483647
		return s / 2147483647
	end
end

--[[ generate(seed, opts) -> ordered { {beat, note, dur, lane}, ... }
  opts = { profile=<instr>, scale=<theory scale with .steps>, root=60,
           bars=8, beats_per_bar=4, subdiv=1, density=0.7 }
  Every note is in-scale AND playable on the instrument; lane = string / band. ]]
function M.generate(seed, opts)
	opts = opts or {}
	local prof = opts.profile or INST.PROFILES[1]
	local scale = opts.scale or { steps = { 0, 2, 4, 5, 7, 9, 11 } }
	local root = opts.root or 60
	local bars = opts.bars or 8
	local bpb = opts.beats_per_bar or 4
	local subdiv = opts.subdiv or 1
	local density = opts.density or 0.7

	-- pool: every playable, in-scale pitch in the instrument's range
	local inscale = {}
	for _, s in ipairs(scale.steps) do
		inscale[s % 12] = true
	end
	local lo, hi = INST.range(prof)
	local pool = {}
	for m = lo, hi do
		if inscale[(m - root) % 12] and INST.playable(prof, m) then
			pool[#pool + 1] = m
		end
	end
	if #pool == 0 then
		pool = { lo }
	end

	local rnd = lcg(seed)
	local notes = {}
	for bar = 0, bars - 1 do
		for b = 0, bpb - 1 do
			for sd = 0, subdiv - 1 do
				local p = (sd == 0) and density or density * 0.4
				if rnd() < p then
					local m = pool[1 + (floor(rnd() * #pool) % #pool)]
					notes[#notes + 1] = {
						beat = bar * bpb + b + sd / subdiv,
						note = m,
						dur = 0,
						lane = INST.lane(prof, m),
					}
				end
			end
		end
	end
	return notes
end

-- chart built from an authored list of { beat, note, dur } (a real riff)
function M.from_song(song, prof)
	local notes = {}
	for _, n in ipairs(song.notes or {}) do
		notes[#notes + 1] = {
			beat = n.beat,
			note = n.note,
			dur = n.dur or 0,
			lane = INST.lane(prof, n.note),
		}
	end
	return notes
end

function M.length(notes)
	local last = 0
	for _, n in ipairs(notes) do
		local e = n.beat + (n.dur or 0)
		if e > last then
			last = e
		end
	end
	return last
end

--[[ judge(dbeat, cents, bpm) -> "perfect" | "good" | "miss"
  dbeat = beat-distance of the strike from the note. cents = pitch error in cents
  (PERFORM), or nil for PRACTICE (timing-only). ]]
function M.judge(dbeat, cents, bpm)
	local sec = abs(dbeat) * 60.0 / (bpm or 120)
	local timing
	if sec <= M.WINDOW.perfect then
		timing = "perfect"
	elseif sec <= M.WINDOW.good then
		timing = "good"
	else
		return "miss"
	end
	if cents == nil then
		return timing -- PRACTICE: timing only
	end
	local ac = abs(cents)
	if ac <= M.CENTS.perfect and timing == "perfect" then
		return "perfect"
	elseif ac <= M.CENTS.good then
		return "good"
	end
	return "miss" -- on time but out of tune
end

return M
