-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/midi_input.lua — unified MIDI input abstraction.

  Supports multiple concurrent input sources:
  - "direct"     : external USB MIDI controller (future JACK/ALSA binding)
  - "detection"  : notes coming from the pitch detector (mirrored + secondary)
  - "secondary"  : processed secondary player events

  All sources feed into a single event stream that the MIDI Player modes can consume.

  Industry standard approach: route everything through JACK MIDI or ALSA Sequencer.
  For now we provide a clean Lua interface that the framework can drive.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

local M = {}

M.sources = {
	direct = {},
	detection = {},
	secondary = {},
}

-- Unified event queue (simple ring for low latency)
local events = {}
local max_events = 64
local write_ptr = 1

function M.push_event(src, event)
	event.src = src
	event.t = (event.t or 0)
	events[write_ptr] = event
	write_ptr = (write_ptr % max_events) + 1
end

function M.poll()
	-- Return all pending events since last poll (simple implementation)
	local out = {}
	for i = 1, max_events do
		if events[i] then
			table.insert(out, events[i])
			events[i] = nil
		end
	end
	return out
end

-- External hardware MIDI now arrives through the shared subsystem (midi/init.lua),
-- which the host pushes here as the "direct" source — no JACK client stub needed.

return M
