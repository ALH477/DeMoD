-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/pattern_player.lua — shared step-pattern note firing (pure, dm-free).

  One implementation of "play one step of a note grid" used by BOTH the SEQUENCER
  screen and the ARRANGEMENT song player, so note-on/off + voice tracking behave
  identically everywhere. One-step gate: each :step releases the previous step's
  notes, then fires the new step's. Chords = multiple notes in a step column.

      local PP = dofile(".../pattern_player.lua")
      local p = PP.new()
      p:step(dsp, target_slot, cells, step_idx)  -- cells[step] = { [note] = vel(0..1) }
      p:release(dsp)                              -- note_off everything sounding
      p:panic(dsp, target_slot)                  -- release + all_notes_off (on stop)

  Pure: takes the `dsp` contract table (note_on/note_off/all_notes_off) as an arg.
  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local floor = math.floor

local PP = {}
PP.__index = PP

local M = {}

function M.new()
	return setmetatable({ sounding = {} }, PP)
end

-- note_off everything this player started, then forget it
function PP:release(dsp)
	if dsp and dsp.note_off then
		for _, sn in ipairs(self.sounding) do
			dsp.note_off(sn.slot, sn.note)
		end
	end
	self.sounding = {}
end

-- release the previous step's notes, then fire cells[step_idx] on `target` (a slot index)
function PP:step(dsp, target, cells, step_idx)
	self:release(dsp)
	if not (dsp and dsp.note_on and target) then
		return
	end
	local col = cells and cells[step_idx]
	if not col then
		return
	end
	for note, vel in pairs(col) do
		dsp.note_on(target, note, floor((vel or 0.8) * 127 + 0.5))
		self.sounding[#self.sounding + 1] = { slot = target, note = note }
	end
end

-- hard stop: release tracked notes + an all-notes-off safety net on the target
function PP:panic(dsp, target)
	self:release(dsp)
	if dsp and target and dsp.all_notes_off then
		dsp.all_notes_off(target)
	end
end

return M
