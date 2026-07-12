-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  settings.lua — the dedicated settings + customization model for TERMINUS.

  Self-contained: schema + persistence + curated themes + value editing. The
  shell (home.lua) reads M.values live each frame, opens a settings overlay per
  category, and calls M.act()/M.apply_theme()/M.save(). Persisted as a Lua table
  file (dofile — the repo's universal config pattern; no JSON parser), so it
  survives reboot. Hardware-bound knobs are intentionally out of v1; every row
  here is something the Lua shell can actually apply.

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local M = {}

local function exists(p)
	local f = io.open(p, "r")
	if f then
		f:close()
		return true
	end
	return false
end
local function clamp(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end
-- POSIX shell single-quote (config dir derives from env; never trust as shell syntax). SECURITY.md F-7.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- ── Curated accent themes (primary + secondary, mutated into the palette) ─
M.THEMES = {
	Turquoise = { primary = { 0, 245, 212 }, secondary = { 139, 92, 246 } },
	Violet = { primary = { 139, 92, 246 }, secondary = { 0, 245, 212 } },
	Green = { primary = { 76, 255, 130 }, secondary = { 0, 245, 212 } },
	Amber = { primary = { 255, 200, 80 }, secondary = { 255, 120, 80 } },
	Mono = { primary = { 200, 220, 230 }, secondary = { 120, 140, 170 } },
}
local THEME_ORDER = { "Turquoise", "Violet", "Green", "Amber", "Mono" }

-- ── Game controller remapping ─────────────────────────────────────────────
-- Friendly action options shown on the Controller page; mapped to the canonical
-- on_nav actions the framework's dm.gamepad_map understands.
M.GP_ACTIONS = {
	"None",
	"Move Up",
	"Move Down",
	"Activate",
	"Back",
	"Screen Prev",
	"Screen Next",
	"Secondary",
	"Script 1",
	"Script 2",
	"Script 3",
	"Script 4",
	"Param Up",
	"Param Down",
	"Param Toggle",
	"Control Surface",
	"Song Play/Stop",
	"Play/Stop",
}
local GP_CANON = {
	None = "none",
	["Move Up"] = "prev",
	["Move Down"] = "next",
	Activate = "activate",
	Back = "back",
	["Screen Prev"] = "tab_prev",
	["Screen Next"] = "tab",
	Secondary = "wet",
	["Script 1"] = "script1", -- DSP Studio: fire automation script N (dsp_studio nav)
	["Script 2"] = "script2",
	["Script 3"] = "script3",
	["Script 4"] = "script4",
	["Param Up"] = "param_up", -- DSP Studio: nudge/toggle the BINDINGS performance param
	["Param Down"] = "param_down",
	["Param Toggle"] = "param_toggle",
	["Control Surface"] = "cs_toggle", -- latch the param<->MIDI control surface on/off
	["Song Play/Stop"] = "song_toggle", -- DSP Studio: start/stop the ARRANGE song transport
	["Play/Stop"] = "play_stop", -- DSP Studio: context transport (active screen first, song fallback)
}
-- Control-surface global mode: friendly choice -> canonical (control_surface.lua). One
-- place so the persisted (friendly) and runtime (canonical) values never desync.
local CS_MODE_CANON = {
	["Both"] = "both",
	["Params Only"] = "params",
	["MIDI Only"] = "midi",
}
local CS_MODE_ORDER = { "Both", "Params Only", "MIDI Only" }
-- one row per button: persistence key, SDL button name, label, default friendly action
M.GP_BUTTONS = {
	{ key = "gp_a", sdl = "a", label = "A", default = "Activate" },
	{ key = "gp_b", sdl = "b", label = "B", default = "Back" },
	{ key = "gp_x", sdl = "x", label = "X", default = "Secondary" },
	{ key = "gp_y", sdl = "y", label = "Y", default = "None" },
	{ key = "gp_lb", sdl = "leftshoulder", label = "LB (L1)", default = "Screen Prev" },
	{ key = "gp_rb", sdl = "rightshoulder", label = "RB (R1)", default = "Screen Next" },
	{ key = "gp_up", sdl = "dpup", label = "D-pad Up", default = "Move Up" },
	{ key = "gp_down", sdl = "dpdown", label = "D-pad Down", default = "Move Down" },
	{ key = "gp_left", sdl = "dpleft", label = "D-pad Left", default = "Screen Prev" },
	{ key = "gp_right", sdl = "dpright", label = "D-pad Right", default = "Screen Next" },
	{ key = "gp_start", sdl = "start", label = "Start", default = "Play/Stop" },
	{ key = "gp_back", sdl = "back", label = "Select", default = "None" },
}

-- ── Defaults (also the persistence whitelist + type reference) ────────────
M.DEFAULTS = {
	theme = "Turquoise",
	scanlines = true,
	vignette = true,
	pulse = 0.7, -- background pulse intensity 0..1
	boot_anim = true,
	reduce_motion = false,
	default_page = "Channels", -- or "Patches"
	card_scale = 1.0, -- 0.85..1.15
	wrap = true, -- focus wraps at the ends
	invert_enc = false,
	hover_focus = true,
	seen_intro = false, -- first-run onboarding shown? (hidden flag, not in schema)
	dsp_seen_intro = false, -- DSP Studio first-run help shown? (hidden flag)
	midi_enabled = true,
	midi_direct = false,
	midi_mirrored = false,
	midi_secondary = true,
	midi_max_voices = 6,
	midi_velocity = "confidence",
	-- hardware MIDI input (the System → MIDI page; distinct from the pitch-detect Player above)
	midi_in_device = "Auto", -- "Auto" (framework DEMOD_MIDI) | "None" | <friendly name>
	midi_channel = "Omni", -- "Omni" | "1".."16"
	midi_clock_source = "Internal", -- "Internal" | "External"
	midi_thru = false, -- echo input to the MIDI output (controller passthrough)
	midi_velocity_mode = "As-played", -- "As-played" | "Fixed"
	midi_cc_bindings = {}, -- { ["<cc>"] = "<target id>", ... } legacy CC-learn (migrates into param_bindings)
	-- unified param<->control bindings (DSP Studio): { ["slot1.p0"] = "cc:74:abs", ... }
	param_bindings = {},
	perf_target = "", -- the performance param id driven by gamepad/encoder (or "")
	-- control surface (the shared param<->MIDI bridge; see control_surface.lua)
	cs_enabled = true, -- master latch: when off it's a pure param-only registry
	cs_mode = "Both", -- "Both" | "Params Only" | "MIDI Only" (friendly; CS_MODE_CANON maps it)
	cs_out_device = "Auto", -- "Auto" | "None" | <device name> for param->MIDI-out emission
	cs_out_bindings = {}, -- per-target MIDI-out dest: { ["slot1.p0"] = "cc:1:74" } (kind:ch:num)
	-- modulation layer (modulation.lua): macros (one control -> many params)
	cs_macros = {}, -- { ["macro1"] = "label:driver-src:driver-code" }
	cs_macro_routes = {}, -- { ["macro1"] = "slot1.p0=exp/inv/lo0/hi80;slot2.p1=lin" }
	-- modulation sources (LFO / env-follower / step) + their routes
	cs_mod_sources = {}, -- { ["lfo1"] = "lfo:sine:sync:div=1-4:hz1:depth80:bipol" }
	cs_mod_routes = {}, -- { ["lfo1"] = "slot1.p0=exp/lo0/hi100@depth100;slot3.p2=lin@depth60" }
	-- scene morphing: param snapshots + a crossfade pair
	cs_scenes = {}, -- { ["A"] = "slot1.p0=30;slot2.p1=80" } (values are int percent)
	cs_morph = {}, -- { pair = "A:B", driver = "cc:20" }
	cs_mod_perf = "", -- gamepad/encoder perf focus: "" | "macro:macro1" | "morph"
	cs_seq = {}, -- tempo-synced scene sequencer: { enabled = "0"|"1", div = "1/1" }
	record_format = "wav", -- wav | flac | mp3
	record_bitdepth = "24", -- 16 | 24 | 32 (string so it cycles as a choice)
	record_samplerate = "48000", -- 44100 | 48000 | 96000
	record_dual = true, -- capture dry input alongside wet output
}
-- controller button defaults (flat string keys → persisted by the existing save/load)
for _, b in ipairs(M.GP_BUTTONS) do
	M.DEFAULTS[b.key] = b.default
end
M.values = {}

-- ── Schema: ordered categories of typed rows ──────────────────────────────
-- row: { key, label, type, options?, min?, max?, step?, scale?, unit?, get?, run? }
M.categories = {
	{
		name = "Appearance",
		rows = {
			{ key = "theme", label = "Accent Theme", type = "choice", options = THEME_ORDER },
			{ key = "scanlines", label = "Scanlines", type = "toggle" },
			{ key = "vignette", label = "CRT Vignette", type = "toggle" },
			{
				key = "pulse",
				label = "Background Pulse",
				type = "slider",
				min = 0,
				max = 1,
				step = 0.05,
				scale = 100,
				unit = "%",
			},
			{ key = "boot_anim", label = "Boot Animation", type = "toggle" },
			{ key = "reduce_motion", label = "Reduce Motion", type = "toggle" },
		},
	},
	{
		name = "Layout",
		rows = {
			{ key = "default_page", label = "Startup Page", type = "choice", options = { "Channels", "Patches" } },
			{
				key = "card_scale",
				label = "Card Scale",
				type = "slider",
				min = 0.85,
				max = 1.15,
				step = 0.05,
				scale = 100,
				unit = "%",
			},
			{ key = "wrap", label = "Focus Wrap", type = "toggle" },
		},
	},
	{
		name = "Input",
		rows = {
			{ key = "invert_enc", label = "Invert Encoder", type = "toggle" },
			{ key = "hover_focus", label = "Hover-to-Focus", type = "toggle" },
		},
	},
	{
		name = "MIDI Player",
		rows = {
			{ key = "midi_enabled", label = "MIDI Player", type = "toggle" },
			{ key = "midi_direct", label = "  Direct Controller", type = "toggle" },
			{ key = "midi_mirrored", label = "  Mirrored", type = "toggle" },
			{ key = "midi_secondary", label = "  Secondary Player", type = "toggle" },
			{ key = "midi_max_voices", label = "Max Voices", type = "slider", min = 1, max = 12, step = 1 },
			{ key = "midi_velocity", label = "Velocity From", type = "choice", options = { "confidence", "fixed" } },
		},
	},
	{
		name = "Recording",
		rows = {
			{ key = "record_format", label = "Format", type = "choice", options = { "wav", "flac", "mp3" } },
			{ key = "record_bitdepth", label = "Bit Depth", type = "choice", options = { "16", "24", "32" } },
			{
				key = "record_samplerate",
				label = "Sample Rate",
				type = "choice",
				options = { "44100", "48000", "96000" },
			},
			{ key = "record_dual", label = "Dual (dry+wet)", type = "toggle" },
		},
	},
	{
		name = "System",
		rows = {
			{
				type = "info",
				label = "Realtime",
				get = function()
					return "1.33 ms callback"
				end,
			},
			{
				type = "info",
				label = "Network",
				get = function()
					return "USB-C bridge"
				end,
			},
			{
				type = "info",
				label = "Display",
				get = function()
					return "adaptive"
				end,
			},
			{
				type = "info",
				label = "Firmware",
				get = function()
					return "ArchibaldOS"
				end,
			},
			{
				type = "action",
				key = "reset",
				label = "Reset to Defaults",
				run = function()
					M.reset()
				end,
			},
		},
	},
}

-- Controller remap category — one choice row per button, generated from GP_BUTTONS.
do
	local rows = {}
	for _, b in ipairs(M.GP_BUTTONS) do
		rows[#rows + 1] = { key = b.key, label = b.label, type = "choice", options = M.GP_ACTIONS }
	end
	M.categories[#M.categories + 1] = { name = "Controller", rows = rows }
end

-- ── MIDI hardware-input category (System → MIDI) ───────────────────────────
-- Distinct from the "MIDI Player" category above (that's the pitch-detect synth
-- player). This page configures the shared midi/ subsystem: which controller,
-- channel, clock source, velocity, thru. Applied live via M.apply_midi.
local MIDI_CHANNELS = { "Omni" }
for i = 1, 16 do
	MIDI_CHANNELS[#MIDI_CHANNELS + 1] = tostring(i)
end
do
	local device_row = { key = "midi_in_device", label = "Input Device", type = "choice", options = { "Auto", "None" } }
	M._midi_device_row = device_row -- kept so midi_refresh_devices can repopulate it
	M.categories[#M.categories + 1] = {
		name = "MIDI",
		rows = {
			device_row,
			{ key = "midi_channel", label = "Channel", type = "choice", options = MIDI_CHANNELS },
			{ key = "midi_clock_source", label = "Clock", type = "choice", options = { "Internal", "External" } },
			{ key = "midi_velocity_mode", label = "Velocity", type = "choice", options = { "As-played", "Fixed" } },
			{ key = "midi_thru", label = "MIDI Thru", type = "toggle" },
			-- live status (read-only) — fed by the subsystem handle stored in apply_midi
			{
				type = "info",
				label = "Connected",
				get = function()
					return M._midi and M._midi.connected_label() or "(none)"
				end,
			},
			{
				type = "info",
				label = "Activity",
				get = function()
					if not M._midi then
						return "-"
					end
					return (M._midi.activity() > 0.05 and "* " or "  ") .. M._midi.last_label()
				end,
			},
			{
				type = "info",
				label = "Tempo",
				get = function()
					if not M._midi then
						return "-"
					end
					if M._midi.clock_source() == "external" then
						return string.format("%.0f BPM (ext)", M._midi.bpm())
					end
					return "internal"
				end,
			},
			{
				type = "action",
				key = "midi_clear_cc",
				label = "Clear CC Bindings",
				run = function()
					if M._midi and M._midi.learn then
						M._midi.learn.set_bindings({})
					end
					M.values.midi_cc_bindings = {}
				end,
			},
		},
	}
end

-- ── Control Surface category (the shared param<->MIDI bridge) ───────────────
-- Enabled = master latch (mappable to a controller button / footswitch too); Mode picks
-- the direction. MIDI-out destinations are assigned per-param on the DSP Studio BINDINGS
-- screen and persist in cs_out_bindings. Applied live via M.apply_control_surface.
do
	local out_row = { key = "cs_out_device", label = "MIDI Out", type = "choice", options = { "Auto", "None" } }
	M._cs_out_row = out_row
	M.categories[#M.categories + 1] = {
		name = "Control Surface",
		rows = {
			{ key = "cs_enabled", label = "Enabled", type = "toggle" },
			{ key = "cs_mode", label = "Mode", type = "choice", options = CS_MODE_ORDER },
			out_row,
			{
				type = "info",
				label = "MIDI Out",
				get = function()
					if not M.values.cs_enabled then
						return "off"
					end
					return CS_MODE_CANON[M.values.cs_mode] == "params" and "params only" or "active"
				end,
			},
			{
				type = "action",
				key = "cs_clear_out",
				label = "Clear MIDI-out Map",
				run = function()
					M.values.cs_out_bindings = {}
					if M._cs and M._cs.import then
						-- re-seed the live registry without out specs
						M._cs.import(
							M.values.param_bindings,
							M.values.perf_target,
							M.values.midi_cc_bindings,
							{},
							{ enabled = M.values.cs_enabled, mode = CS_MODE_CANON[M.values.cs_mode] }
						)
					end
				end,
			},
		},
	}
end

-- Push the current control-surface config to the live registry (mirrors apply_gamepad /
-- apply_midi). cs is the loaded control_surface.lua module. Safe to call with nil.
function M.apply_control_surface(cs)
	if not cs then
		return
	end
	M._cs = cs -- handle for the Clear action above
	if cs.set_enabled then
		cs.set_enabled(M.values.cs_enabled and true or false)
	end
	if cs.set_mode then
		cs.set_mode(CS_MODE_CANON[M.values.cs_mode] or "both")
	end
	-- Open a MIDI output for emission (best-effort). "None" opens nothing; "Auto" reuses the
	-- selected input device's id (many ports are bidirectional); a named device opens by id.
	if M._midi and M._midi.open_output then
		local dev = M.values.cs_out_device
		if dev == "Auto" then
			local inid = M._midi_name_to_id and M._midi_name_to_id[M.values.midi_in_device]
			if inid then
				M._midi.open_output(inid)
			end
		elseif dev and dev ~= "None" then
			local id = M._midi_name_to_id and M._midi_name_to_id[dev]
			if id then
				M._midi.open_output(id)
			end
		end
	end
end

-- Rebuild the Input Device choices from the live device list (call on opening the
-- MIDI page). Keeps a friendly-name → device-id map for apply_midi. No-op safe.
function M.midi_refresh_devices(midi)
	M._midi = midi or M._midi -- keep a handle for the live status info rows
	local row = M._midi_device_row
	if not row then
		return
	end
	local opts = { "Auto", "None" }
	M._midi_name_to_id = {}
	if midi and midi.devices then
		for _, d in ipairs(midi.devices()) do
			local name = d.name or d.id
			opts[#opts + 1] = name
			M._midi_name_to_id[name] = d.id
		end
	end
	row.options = opts
	local cur, found = M.values.midi_in_device, false
	for _, o in ipairs(opts) do
		if o == cur then
			found = true
			break
		end
	end
	if not found then
		M.values.midi_in_device = "Auto" -- persisted device unplugged → show Auto
	end
end

-- Push the current MIDI config to the live subsystem (mirrors apply_gamepad). The
-- caller passes the loaded midi/init module. Safe to call with nil.
function M.apply_midi(midi)
	if not midi then
		return
	end
	M._midi = midi -- handle for the live status info rows
	local ch = M.values.midi_channel
	midi.set_channel(ch == "Omni" and 0 or (tonumber(ch) or 0))
	midi.set_velocity(M.values.midi_velocity_mode == "Fixed" and "fixed" or "as_played")
	midi.clock.set_source(M.values.midi_clock_source == "External" and "external" or "internal")
	if midi.set_thru then
		midi.set_thru(M.values.midi_thru and true or false)
	end
	if type(M.values.midi_cc_bindings) == "table" then
		midi.learn.set_bindings(M.values.midi_cc_bindings)
	end
	local dev = M.values.midi_in_device
	if dev == "None" then
		midi.close_all()
	elseif dev ~= "Auto" then
		local id = M._midi_name_to_id and M._midi_name_to_id[dev]
		if id then
			midi.select_device(id)
		end
	end
end

-- Push the current controller mapping to the framework (dm.gamepad_map). Safe when
-- there's no `dm` / no controller (the binding no-ops). Called at boot + on edit by
-- each shell, since TERMINUS runs home/DSP as separate framebuffer-handoff processes.
function M.apply_gamepad()
	if not (dm and dm.gamepad_map) then
		return
	end
	for _, b in ipairs(M.GP_BUTTONS) do
		dm.gamepad_map(b.sdl, GP_CANON[M.values[b.key]] or "none")
	end
end

-- category index by name (System channel blade items map to these)
function M.cat_index(name)
	for i, c in ipairs(M.categories) do
		if c.name == name then
			return i
		end
	end
	return nil
end

-- ── Apply a theme by mutating the shell palette in place ──────────────────
-- COL.turq / COL.violet are referenced everywhere (focus, boot, pulse, chrome,
-- and the DSP/Systems channel accents), so recolouring them re-themes the whole
-- identity live, with no per-call-site edits.
function M.apply_theme(COL, name)
	local th = M.THEMES[name] or M.THEMES.Turquoise
	COL.turq[1], COL.turq[2], COL.turq[3] = th.primary[1], th.primary[2], th.primary[3]
	COL.violet[1], COL.violet[2], COL.violet[3] = th.secondary[1], th.secondary[2], th.secondary[3]
end

-- ── Value display + editing ───────────────────────────────────────────────
function M.display(row)
	if row.type == "info" then
		return row.get and row.get() or ""
	end
	if row.type == "action" then
		return "[ go ]"
	end
	local v = M.values[row.key]
	if row.type == "toggle" then
		return v and "ON" or "OFF"
	end
	if row.type == "choice" then
		return tostring(v)
	end
	if row.type == "slider" then
		return string.format("%d%s", math.floor((row.scale or 1) * v + 0.5), row.unit or "")
	end
	return tostring(v)
end

-- mutate a row's value by `dir` (+1/-1). Returns the changed key (or nil).
function M.act(row, dir)
	dir = dir or 1
	if row.type == "toggle" then
		M.values[row.key] = not M.values[row.key]
		return row.key
	elseif row.type == "choice" then
		local opts, cur = row.options, M.values[row.key]
		local idx = 1
		for i, o in ipairs(opts) do
			if o == cur then
				idx = i
				break
			end
		end
		idx = ((idx - 1 + dir) % #opts) + 1
		M.values[row.key] = opts[idx]
		return row.key
	elseif row.type == "slider" then
		local v = clamp(M.values[row.key] + dir * row.step, row.min, row.max)
		M.values[row.key] = math.floor(v / row.step + 0.5) * row.step -- snap to step grid
		return row.key
	elseif row.type == "action" then
		if row.run then
			row.run()
		end
		return row.key
	end
	return nil
end

function M.reset()
	for k, v in pairs(M.DEFAULTS) do
		M.values[k] = v
	end
end

-- ── Persistence (a Lua `return { ... }` table; dofile to read) ─────────────
M._order = {}
for k in pairs(M.DEFAULTS) do
	M._order[#M._order + 1] = k
end
table.sort(M._order)

function M.load(path)
	M.reset() -- start from defaults
	if path and exists(path) then
		local ok, t = pcall(dofile, path)
		if ok and type(t) == "table" then
			for k, v in pairs(t) do -- only known keys, matching type
				if M.DEFAULTS[k] ~= nil and type(v) == type(M.DEFAULTS[k]) then
					M.values[k] = v
				end
			end
		end
	end
end

function M.save(path)
	if not path then
		return false
	end
	local dir = path:gsub("/[^/]*$", "")
	if dir ~= path then
		os.execute("mkdir -p " .. shq(dir) .. " 2>/dev/null")
	end
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write("-- TERMINUS settings (generated; edit via System → settings)\nreturn {\n")
	for _, k in ipairs(M._order) do
		local v = M.values[k]
		if type(v) == "string" then
			f:write(string.format("  %s = %q,\n", k, v))
		elseif type(v) == "boolean" then
			f:write(string.format("  %s = %s,\n", k, tostring(v)))
		elseif type(v) == "number" then
			f:write(string.format("  %s = %s,\n", k, tostring(v)))
		elseif type(v) == "table" then
			-- flat string→string map (e.g. midi_cc_bindings: { ["<cc>"]="<target>" })
			local parts = {}
			for bk, bv in pairs(v) do
				parts[#parts + 1] = string.format("[%q] = %q", tostring(bk), tostring(bv))
			end
			f:write(string.format("  %s = { %s },\n", k, table.concat(parts, ", ")))
		end
	end
	f:write("}\n")
	f:close()
	return true
end

return M
