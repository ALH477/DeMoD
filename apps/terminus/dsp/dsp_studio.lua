-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  DSP STUDIO — DeMoD unified DSP GUI (demod-ui Lua port of "demodoom")

  A backend-agnostic effects-rack GUI. The same script runs:
    • on a desktop  -> stub or local (demodoom_core) backend
    • on the guitar -> orchestrator backend (control socket + param bus)

  Input funnels into one nav model from every source:
    keyboard / USB-serial encoder / Arduino  -> on_nav(action)
    demod5 i2c buttons + AS5600 encoder       -> on_input(evt, btn, val)

  Run:  ./demod-ui dsp/dsp_studio.lua
  Headless: SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 ./demod-ui dsp/dsp_studio.lua

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

-- ── locate our own directory so we can dofile sibling modules ───────────
local BASE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

-- Steam edition (DEMOD_EDITION=steam): Steam/DLC is the entitlement authority, so the
-- off-Steam Ed25519 paid gate is bypassed in the picker — same rule as home.lua.
local STEAM_ED = os.getenv("DEMOD_EDITION") == "steam"

local U = dofile(BASE .. "/util.lua")
local C = U.C
local selmod = dofile(BASE .. "/backend/select.lua")
local dsp, backend_name = selmod.select(BASE)
local midi_modes = dofile(BASE .. "/midi_modes.lua")
local midi = dofile(BASE .. "/../midi/init.lua") -- shared MIDI subsystem (owns on_midi)
-- External hardware MIDI → the "direct" source the MIDI Player consumes (when the
-- MIDI Player + Direct Controller are enabled in settings). Replaces the old stub.
midi.on_note(function(ev)
	midi_modes.input.push_event("direct", { type = ev.kind, note = ev.note, vel = ev.vel })
end)
local ok_rec, record = pcall(dofile, BASE .. "/../record.lua")
if not ok_rec then
	record = nil
end
local ok_route, route = pcall(dofile, BASE .. "/../route.lua")
if not ok_route then
	route = nil
end
-- a dedicated footswitch toggles recording hands-free; default 6 so it doesn't
-- steal a bypass foot (FOOT_1..5 = slot bypass). Override via DEMOD_RECORD_FOOT.
local REC_FOOT = tonumber(os.getenv("DEMOD_RECORD_FOOT") or "") or 6
-- a footswitch toggles the looper hands-free (default 7). Finds a loaded LOOPER
-- slot, toggles its RECORD param, and makes sure PLAY is on.
local LOOPER_FOOT = tonumber(os.getenv("DEMOD_LOOPER_FOOT") or "") or 7
-- tap-tempo footswitch (default 8): two+ taps set the BPM from the interval.
local TAP_FOOT = tonumber(os.getenv("DEMOD_TAP_FOOT") or "") or 8
-- latch the param<->MIDI control surface hands-free (default 9, past the in-use 1..8).
local CS_FOOT = tonumber(os.getenv("DEMOD_CS_FOOT") or "") or 9
-- start/stop the ARRANGE song transport hands-free (default 10, past 1..9).
local SONG_FOOT = tonumber(os.getenv("DEMOD_SONG_FOOT") or "") or 10
-- context transport (active screen's play/stop, song fallback) hands-free (default 11).
local TRANSPORT_FOOT = tonumber(os.getenv("DEMOD_TRANSPORT_FOOT") or "") or 11
local _tap_last = -1
local function toggle_looper()
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if sl and sl.loaded and (sl.name or ""):upper() == "LOOPER" then
			local recv = dsp.get_param(i, 0) or 0
			dsp.set_param(i, 0, recv > 0.5 and 0 or 1) -- toggle record
			dsp.set_param(i, 2, 1) -- play on
			return true
		end
	end
	return false
end

-- customization: load the same settings the home shell uses so the user's theme
-- + effect toggles carry across the whole console. Recolouring U.C in place (and
-- thus U.SLOT_COLORS, the same tables) re-themes DSP Studio.
local CFG_DIR = os.getenv("DEMOD_CONFIG")
	or ((os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or ".") .. "/.config")) .. "/demod")
local CFG
local SETTINGS -- hoisted so first-run can persist dsp_seen_intro
do
	local ok, SET = pcall(dofile, BASE .. "/../settings.lua")
	if ok and SET then
		SETTINGS = SET
		SET.load(CFG_DIR .. "/settings.lua")
		CFG = SET.values
		SET.apply_theme(U.C, CFG.theme)
		SET.apply_gamepad() -- honour the persisted controller mapping in this process too
		SET.apply_midi(midi) -- honour persisted MIDI config + CC bindings in this process
	else
		CFG = {
			theme = "Turquoise",
			scanlines = true,
			vignette = true,
			pulse = 0.7,
			boot_anim = true,
			reduce_motion = false,
		} -- safe fallback
	end
end

local SCREENS = {}
do
	-- load screens defensively: a broken screen module shows an error placeholder
	-- instead of crashing the whole app.
	for _, f in ipairs({
		"fx_chain",
		"mixer",
		"params",
		"bindings",
		"macros",
		"mod_matrix",
		"scenes",
		"scripts",
		"sequencer",
		"arrange",
		"viz",
		"record",
		"routing",
		"patches",
		"settings",
	}) do
		local ok, mod = pcall(dofile, BASE .. "/screens/" .. f .. ".lua")
		if ok and type(mod) == "table" then
			SCREENS[#SCREENS + 1] = mod
		else
			io.stderr:write("[dsp] screen '" .. f .. "' failed to load: " .. tostring(mod) .. "\n")
			SCREENS[#SCREENS + 1] = {
				name = f:upper() .. " (ERR)",
				draw = function(c, W, H)
					c.U.text_c(W / 2, H / 2, "screen failed to load", c.C.red, 220)
				end,
			}
		end
	end
end

-- Fixed registry order (also the deep-link-by-index basis). The NAVIGATION order +
-- the tab bar's grouping derive from GROUPS below, so this list stays stable even as
-- the displayed/traversed order is regrouped.
local LOAD_ORDER = {
	"fx_chain",
	"mixer",
	"params",
	"bindings",
	"macros",
	"mod_matrix",
	"scenes",
	"scripts",
	"sequencer",
	"arrange",
	"viz",
	"record",
	"routing",
	"patches",
	"settings",
}

-- Build IDX map: filename -> registry index (1-based position in SCREENS)
local IDX = {}
for i, _ in ipairs(SCREENS) do
	local f = LOAD_ORDER[i]
	if f then
		IDX[f] = i
	end
end

-- ── screen taxonomy: 4 groups drive the two-level tab bar + traversal order ──
-- Screens are referenced by FILENAME (stable across reordering + error-stubs). The
-- bar shows the active group expanded to its screens + the others collapsed to a label;
-- tab/tab_prev walk NAV_ORDER (groups concatenated), so traversal stays grouped and
-- nothing is trapped.
local GROUPS = {
	{ id = "RACK", accent = C.turq, files = { "fx_chain", "mixer", "params" } },
	{ id = "MOD", accent = C.violet, files = { "bindings", "macros", "mod_matrix", "scenes", "scripts" } },
	{ id = "DAW", accent = C.orange, files = { "sequencer", "arrange", "record" } },
	{ id = "SYS", accent = C.blue, files = { "viz", "routing", "patches", "settings" } },
}
local NAV_ORDER = {} -- flat array of registry indices in grouped (traversal) order
local NAV_POS = {} -- registry index -> position in NAV_ORDER (inverse)
local SCREEN_GROUP = {} -- registry index -> group index
do
	for gi, g in ipairs(GROUPS) do
		g.idxs = {}
		for _, f in ipairs(g.files) do
			local idx = IDX[f]
			if idx then
				g.idxs[#g.idxs + 1] = idx
				NAV_ORDER[#NAV_ORDER + 1] = idx
				NAV_POS[idx] = #NAV_ORDER
				SCREEN_GROUP[idx] = gi
			end
		end
	end
	-- coverage guard: any screen missing from the taxonomy (new screen added without
	-- updating GROUPS, or a typo) falls into SYS so it is never unreachable.
	for idx = 1, #SCREENS do
		if not SCREEN_GROUP[idx] then
			local g = GROUPS[#GROUPS]
			g.idxs[#g.idxs + 1] = idx
			NAV_ORDER[#NAV_ORDER + 1] = idx
			NAV_POS[idx] = #NAV_ORDER
			SCREEN_GROUP[idx] = #GROUPS
			io.stderr:write("[dsp] screen index " .. idx .. " not in taxonomy; appended to SYS\n")
		end
	end
end

-- translation helper: uppercase screen names for the trade-dress navbar (ASCII-only font)
local function T(s)
	return s:upper()
end

-- ── app state + screen context ──────────────────────────────────────────
local S = { screen = 1, t = 0, boot = 0, _playing = true, _bpm = 120, _gain = 0.8 }
-- deep-link: the home shell may open us straight onto a screen (DEMOD_DSP_SCREEN).
-- Accept a NAME or short (case/space-insensitive) as well as an index, so deep-links
-- survive screens being inserted/reordered (a raw index silently drifts otherwise).
local _scr0 = os.getenv("DEMOD_DSP_SCREEN")
if _scr0 and _scr0 ~= "" then
	local n = tonumber(_scr0)
	if n then
		S.screen = U.clamp(math.floor(n), 1, #SCREENS)
	else
		local want = _scr0:lower():gsub("%s+", "")
		for i, sc in ipairs(SCREENS) do
			local nm = (sc.name or ""):lower():gsub("%s+", "")
			local sh = (sc.short or ""):lower():gsub("%s+", "")
			if want == nm or want == sh then
				S.screen = i
				break
			end
		end
	end
end
backend_name = backend_name or "unknown"
local ctx = { U = U, C = C, S = S, dsp = dsp, CFG = CFG, record = record, route = route }
ctx.midi = midi -- shared MIDI subsystem (CC-learn, telemetry)
ctx.mixp = dofile(BASE .. "/mixer_params.lua") -- mixer pseudo-param helpers (dB/pan + registrar)
ctx.settings = SETTINGS -- for persisting CC bindings from this process
ctx.cfg_path = CFG_DIR .. "/settings.lua"
-- screen switching, exposed on ctx so screens that bind tab to their own use (sequencer/
-- arrange transport) can still offer a route out via their command menus.
-- Traversal walks NAV_ORDER (grouped order), rolling across group boundaries so
-- tab/tab_prev still reach every screen and nothing is trapped. S.screen stays the
-- registry index; only the step sequence is regrouped.
function ctx.next_screen()
	local p = NAV_POS[S.screen] or 1
	S.screen = NAV_ORDER[(p % #NAV_ORDER) + 1]
	dm.redraw()
end
function ctx.prev_screen()
	local p = NAV_POS[S.screen] or 1
	S.screen = NAV_ORDER[((p - 2) % #NAV_ORDER) + 1]
	dm.redraw()
end
local floor = math.floor

-- ── parameter automation: record motion, replay on a trigger ──────────────
local automation = dofile(BASE .. "/automation.lua")
automation.load_all()
ctx.automation = automation
-- Capture every param write while recording (catches the PARAMS screen, CC-learn,
-- randomize — all routes go through dsp.set_param). Playback applies via the RAW
-- function so replayed events aren't re-captured into the take.
local raw_set_param = dsp.set_param
dsp.set_param = function(slot, index, value)
	raw_set_param(slot, index, value)
	if automation.recording then
		automation.capture(slot, index, value, S.t)
	end
end
ctx.set_param_raw = raw_set_param

-- ── unified param <-> interface binding (CC / footswitch / gamepad-perf) ─────
-- Generalizes the old MIDI-CC-only learn: any effect/synth param can be driven by an
-- assigned control. Attach the WRAPPED set_param so binding moves are captured into
-- takes too; import persisted bindings (migrating the legacy CC-learn map).
local bindings = dofile(BASE .. "/bindings.lua")
bindings.attach(dsp.set_param, dsp.get_param)
bindings.attach_midi(midi.send) -- param moves can emit MIDI out (the control surface)
bindings.import(CFG.param_bindings, CFG.perf_target, CFG.midi_cc_bindings, CFG.cs_out_bindings)
if SETTINGS then
	SETTINGS.apply_control_surface(bindings) -- honour persisted enabled/mode + open the out port
end
ctx.bindings = bindings
-- modulation layer (macros now; LFO/scene sources in later phases) rides the same surface
local modulation = dofile(BASE .. "/../modulation.lua")
modulation.attach(bindings)
modulation.import_macros(CFG.cs_macros, CFG.cs_macro_routes)
modulation.import_sources(CFG.cs_mod_sources, CFG.cs_mod_routes)
modulation.import_scenes(CFG.cs_scenes, CFG.cs_morph)
modulation.import_perf(CFG.cs_mod_perf)
modulation.import_seq(CFG.cs_seq)
modulation.attach_clock(midi.clock) -- LFO tempo-sync
modulation.attach_meters(function() -- env-follower source
	local m = dsp.meters()
	return m and m.levels
end)
ctx.modulation = modulation
-- arrangement / song player (DAW phase 4): the MASTER TRANSPORT. Drives the shared clock
-- and advances off clock.on_step (via midi.update), so the song plays regardless of the
-- active screen. Start empty (no auto-load), like the sequencer.
local arrangement = dofile(BASE .. "/arrangement.lua")
arrangement.attach(dsp, midi, automation, record)
arrangement.set_now(function()
	return S.t
end)
ctx.arrangement = arrangement
-- Re-register a live target for every loaded slot's params (idempotent; refreshes ranges)
-- so feed/perf always see fresh metadata as effects load, unload, or reorder.
function ctx.refresh_binding_targets()
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if sl and sl.loaded then
			for _, p in ipairs(dsp.params(i) or {}) do
				bindings.register_target(
					"slot" .. i .. ".p" .. p.index, -- canonical id (matches the PARAMS screen)
					((sl.name or "slot") .. " " .. (p.label or "?")),
					i,
					p.index,
					p.min or 0,
					p.max or 1,
					p.step or 0.01
				)
			end
		end
	end
	-- also register each loaded slot's mixer controls (gain/pan/mute/solo) as targets,
	-- so they're bindable / macro-routable / scene-capturable like any other param.
	if ctx.mixp then
		ctx.mixp.register(dsp, bindings)
	end
end
-- Persist the binding map + performance param through the shared settings file.
function ctx.save_bindings()
	if not (SETTINGS and CFG) then
		return
	end
	CFG.param_bindings = bindings.export()
	CFG.perf_target = bindings.perf() or ""
	CFG.cs_out_bindings = bindings.export_out() -- per-param MIDI-out dests
	CFG.cs_enabled = bindings.enabled() -- the latch (cs_mode stays friendly, set on the page)
	if ctx.modulation then -- persist macros + modulation sources/routes
		CFG.cs_macros = ctx.modulation.export_macros()
		CFG.cs_macro_routes = ctx.modulation.export_macro_routes()
		CFG.cs_mod_sources = ctx.modulation.export_sources()
		CFG.cs_mod_routes = ctx.modulation.export_mod_routes()
		CFG.cs_scenes = ctx.modulation.export_scenes()
		CFG.cs_morph = ctx.modulation.export_morph()
		CFG.cs_mod_perf = ctx.modulation.export_perf()
		CFG.cs_seq = ctx.modulation.export_seq()
	end
	pcall(SETTINGS.save, CFG_DIR .. "/settings.lua")
end

-- Trigger routing from hardware: a MIDI note or CC press fires (or, while assigning,
-- binds to) a matching script. CCs also feed the binding system (continuous param
-- control). (Footswitch + on-screen + gamepad handled elsewhere.)
midi.on_note(function(ev)
	if ev.kind == "note_on" then
		automation.on_control("midi", ev.note, S.t)
	end
end)
midi.on_cc(function(ev)
	bindings.feed("cc", ev.cc, ev.valuef, ev.ch, ev.value) -- 0..1 sweep (ch=out-learn, value=rel-encoder)
	modulation.feed("cc", ev.cc, ev.valuef) -- a CC assigned as a macro driver sweeps the macro
	modulation.feed_morph("cc", ev.cc, ev.valuef) -- a CC assigned as the morph driver crossfades scenes
	if ev.value > 0 then
		automation.on_control("cc", ev.cc, S.t)
	end
end)

-- shared cross-process manifest of patches running live in the engine (see live_patches.lua):
-- lets a patch Home loaded in the background appear here, and vice-versa.
local LP = (function()
	local ok, m = pcall(dofile, BASE .. "/../live_patches.lua")
	return (ok and type(m) == "table") and m or nil
end)()

-- if boot animation is off, skip straight to the UI
if not CFG.boot_anim then
	S.boot = 1
end

-- patches.lua module (registry + licensing + .so resolution), loaded early so the patch
-- boot-load just below can resolve a descriptor's .so. The INSTALLED catalogue is built lower.
local PM = (function()
	local ok, m = pcall(dofile, BASE .. "/../patches.lua")
	return (ok and type(m) == "table") and m or nil
end)()

-- patch boot-load: the home shell can hand us a Faust synth/fx patch to run
-- live in the engine (DEMOD_DSP_PATCH = path to the patch's fx descriptor .lua).
-- On the orchestrator backend this loads the compiled .so into demod-rt; on the
-- stub it loads a simulated slot so the flow is demoable with no device.
local _patch = os.getenv("DEMOD_DSP_PATCH")
if _patch and _patch ~= "" then
	local ok, spec = pcall(dofile, _patch)
	if ok and type(spec) == "table" and dsp.load_patch then
		local slot = math.max(1, math.min(dsp.slot_count(), spec.slot or 1))
		spec.patch_id = spec.patch_id or spec.id or spec.name or "patch" -- tag so it shows in the manager
		if not spec.path and PM and PM.patch_so then
			spec.path = PM.patch_so(_patch) -- older descriptors carry no path; use the shipped .so
		end
		dsp.load_patch(slot, spec)
		S.screen = 1 -- FX chain
		S.fx = { sel = slot, mode = "select" } -- focus the loaded slot
		S._patch_name = (spec.name or "PATCH"):upper()
		S._patch_t = 0
		if LP then -- record in the shared manifest so Home's badge + reconcile stay in sync
			LP.add({
				slot = slot,
				id = spec.patch_id,
				name = spec.name,
				kind = spec.kind or "fx",
				path = spec.path,
				bypassed = false,
				params = spec.params,
			})
		end
		io.stderr:write(
			string.format(
				"[dsp] loaded patch '%s' (%s) into slot %d\n",
				tostring(spec.name),
				tostring(spec.kind or "fx"),
				slot
			)
		)
	else
		io.stderr:write("[dsp] DEMOD_DSP_PATCH could not load: " .. tostring(_patch) .. "\n")
	end
end

-- ── installed patches: registry + cryptographic paid gate ────────────────
-- DSP Studio browses the SAME marketplace patches Home does (patches/index.lua) and
-- honours the SAME entitlement gate (entitlements.lua) so the picker can't sidestep a
-- paid patch. Discovery is best-effort — any failure just leaves the catalogue empty.
-- (PM is defined earlier, above the patch boot-load.)
local INSTALLED = {} -- installed fx/synth patch entries (the loadable catalogue)
if PM then
	local function pexists(p)
		local f = io.open(p, "r")
		if f then
			f:close()
			return true
		end
		return false
	end
	local dirs = {}
	local pd = os.getenv("DEMOD_PATCH_DIR")
		or (os.getenv("HOME") and (os.getenv("HOME") .. "/.nix-profile/share/demod/patches"))
	if pd then
		dirs[#dirs + 1] = pd
	end
	dirs[#dirs + 1] = BASE .. "/../patches" -- desktop dev stub
	pcall(PM.load, dirs)
	pcall(PM.load_owner, os.getenv("DEMOD_OWNER") or (CFG_DIR .. "/owner.lua"))
	-- verify the signed entitlement token → PM.entitled (unlocked paid-patch ids)
	local okE, ENT = pcall(dofile, BASE .. "/../entitlements.lua")
	local okK, PUB = pcall(dofile, BASE .. "/../keys/pubkeys.lua")
	if okE and type(ENT) == "table" and okK and type(PUB) == "table" then
		local set = ENT.verify({
			pubkey_hex = PUB.entitlement,
			ent_path = os.getenv("DEMOD_ENTITLEMENTS") or (CFG_DIR .. "/entitlements.lua"),
			pm = PM,
			account = os.getenv("DEMOD_ACCOUNT"),
			exists = pexists,
		})
		PM.entitled = set or {}
	end
	for _, p in ipairs(PM.list or {}) do
		if p.type == "fx" or p.type == "synth" then
			INSTALLED[#INSTALLED + 1] = p
		end
	end
	io.stderr:write(string.format("[dsp] patch catalogue: %d installed fx/synth\n", #INSTALLED))
end

-- ── DSP modal layer: effect picker + on-screen keyboard + toasts ─────────
local D = dofile(BASE .. "/fx_descriptors.lua")
-- the picker catalogue: EMPTY, the stock effects (alpha), then installed patches.
-- Each item: { t = "empty"|"stock"|"patch", label, category, desc, kind, np, entry, locked }
local PICK = { { t = "empty", label = "EMPTY", category = "clear", desc = "Clear this slot (passthrough)." } }
do
	local names = {}
	for name in pairs(D.effects) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, n in ipairs(names) do
		local meta = D.meta and D.meta[n]
		PICK[#PICK + 1] = {
			t = "stock",
			name = n,
			label = n,
			category = meta and meta.category or "FX",
			desc = meta and meta.desc,
			kind = (meta and meta.kind) or "fx",
			np = (D.effects[n] and #D.effects[n]) or 0,
		}
	end
	for _, p in ipairs(INSTALLED) do
		local locked = not STEAM_ED and PM and PM.is_paid(p) and not PM.is_entitled(p)
		PICK[#PICK + 1] = {
			t = "patch",
			entry = p,
			label = (p.name or p.id or "PATCH"):upper(),
			category = p.category or (p.type == "synth" and "Instrument" or "Effect"),
			desc = p.desc,
			kind = p.type,
			locked = locked and true or false,
		}
	end
end
local KB_KEYS = {}
for c = string.byte("A"), string.byte("Z") do
	KB_KEYS[#KB_KEYS + 1] = string.char(c)
end
for c = string.byte("0"), string.byte("9") do
	KB_KEYS[#KB_KEYS + 1] = string.char(c)
end
KB_KEYS[#KB_KEYS + 1] = "SPC"
KB_KEYS[#KB_KEYS + 1] = "DEL"
KB_KEYS[#KB_KEYS + 1] = "OK"

S.toasts = {}
function ctx.toast(msg, kind)
	S.toasts[#S.toasts + 1] = { msg = tostring(msg), kind = kind or "info", t = 0 }
	if #S.toasts > 4 then
		table.remove(S.toasts, 1)
	end
end
function ctx.pick_fx(slot)
	S.modal = { kind = "picker", slot = slot, sel = 1, t = 0 }
end
-- the installed fx/synth catalogue, exposed for the PATCHES screen
ctx.installed = INSTALLED
-- Load a marketplace registry entry into a slot (shared by the picker + PATCHES screen).
-- Honours the paid gate; dofiles the patch's fx descriptor and runs dsp.load_patch, which
-- (orchestrator) dlopens the patch's .so into demod-rt — it then runs in the background.
function ctx.load_patch_entry(slot, entry)
	if not entry or not slot then
		return false
	end
	if not STEAM_ED and PM and PM.is_paid(entry) and not PM.is_entitled(entry) then
		ctx.toast((entry.name or "patch") .. " - LOCKED (no entitlement)", "err")
		return false
	end
	if not entry.fx_file or entry.fx_file == "" or entry.fx_file:find("%.%.") then
		ctx.toast((entry.name or "patch") .. " - bad fx descriptor", "err")
		return false
	end
	local ok, spec = pcall(dofile, entry.fx_file)
	if not ok or type(spec) ~= "table" then
		ctx.toast((entry.name or "patch") .. " - descriptor failed to load", "err")
		return false
	end
	spec.patch_id = entry.id -- tags the slot as a patch (vs a stock effect)
	spec.name = spec.name or entry.name
	if not spec.path and PM and PM.patch_so then
		spec.path = PM.patch_so(entry.fx_file) -- older descriptors carry no path; use the shipped .so
	end
	if dsp.load_patch then
		dsp.load_patch(slot, spec)
	end
	if ctx.live_add then
		ctx.live_add(slot, entry, spec) -- cross-process manifest (wired in Phase 3; nil before)
	end
	ctx.toast(((spec.kind or entry.type) == "synth" and "Loaded synth " or "Loaded patch ") .. (entry.name or ""), "ok")
	return true
end
-- first empty slot — patches stack after the loaded stock chain. nil if the rack is full.
function ctx.free_slot()
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if not (sl and sl.loaded) then
			return i
		end
	end
	return nil
end
-- turn off every running patch (UNLOAD ALL); stock effects are left alone.
function ctx.unload_all_patches()
	local n = 0
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if sl and sl.loaded and sl.is_patch then
			if dsp.unload_slot then
				dsp.unload_slot(i)
			end
			if ctx.live_remove then
				ctx.live_remove(i)
			end
			n = n + 1
		end
	end
	if n > 0 then
		ctx.toast("Unloaded " .. n .. " patch" .. (n == 1 and "" or "es"))
	end
	return n
end

-- ── cross-process live-patch manifest sync ───────────────────────────────
-- Every patch load/unload/bypass writes the shared manifest so Home (and a later DSP
-- Studio session) stays in sync; reconcile_live pulls the manifest back into the shadow.
function ctx.live_add(slot, entry, spec)
	if not LP then
		return
	end
	LP.add({
		slot = slot,
		id = entry.id,
		name = spec.name or entry.name,
		kind = spec.kind or entry.type or "fx",
		path = spec.path,
		bypassed = false,
		params = spec.params,
	})
end
function ctx.live_remove(slot)
	if LP then
		LP.remove(slot)
	end
end
function ctx.live_set_bypass(slot, on)
	if LP then
		LP.set_bypass(slot, on)
	end
end
-- pull the manifest into the slot shadow: adopt patches loaded elsewhere (Home), reflect
-- bypass changes, and clear patch slots that vanished (unloaded elsewhere). adopt_patch is
-- shadow-only so this never re-issues an engine load (no demod-rt restart).
local function reconcile_live()
	if not LP then
		return
	end
	local want = {}
	for _, e in ipairs(LP.list()) do
		want[e.slot] = true
		local sl = dsp.slot(e.slot)
		if sl then
			if not (sl.is_patch and sl.patch_id == e.id and sl.loaded) then
				if dsp.adopt_patch then
					dsp.adopt_patch(e.slot, {
						name = e.name,
						kind = e.kind,
						path = e.path,
						params = e.params,
						bypassed = e.bypassed,
						patch_id = e.id,
					})
				end
			elseif (e.bypassed and true or false) ~= (sl.bypassed and true or false) then
				sl.bypassed = e.bypassed and true or false
			end
		end
	end
	for i = 1, dsp.slot_count() do
		local sl = dsp.slot(i)
		if sl and sl.is_patch and not want[i] then -- removed by the other process
			sl.loaded, sl.name, sl.bypassed, sl.dsp_path = false, "", true, ""
			sl.params, sl.is_patch, sl.patch_id, sl.presets = {}, nil, nil, nil
		end
	end
end
ctx.reconcile_live = reconcile_live
reconcile_live() -- adopt anything already running in the background at startup
ctx.refresh_binding_targets() -- seed binding targets for whatever's already loaded
function ctx.keyboard(title, onok)
	S.modal = { kind = "keyboard", title = title or "NAME", text = "", sel = 1, onok = onok, t = 0 }
end
-- on-screen musical keyboard for playing a loaded synth (nav-driven, encoder-native).
function ctx.piano(slot)
	S._note_q = S._note_q or {}
	S.modal = { kind = "piano", slot = slot, note = 60, t = 0 } -- middle C
end
-- play the given MIDI note on a slot now, and queue its release (on_update fires it).
local function piano_play(slot, note)
	if dsp.note_on then
		dsp.note_on(slot, note, 100)
	end
	S._note_q = S._note_q or {}
	S._note_q[#S._note_q + 1] = { slot = slot, note = note, t = 0.5 }
end

-- help / onboarding (parity with the home shell)
local HELP_PAGES = {
	{
		"NAVIGATE",
		{
			"turn / arrows    move the cursor",
			"press / select   open / descend / adjust",
			"back / esc       step back out (or menu)",
			"tab / NAV < >    switch screens (any screen)",
			"start / foot     play / stop transport",
		},
	},
	{
		"SCREENS",
		{
			"grouped: RACK . MOD . DAW . SYS",
			"RACK   FX CHAIN / MIXER / PARAMS",
			"MOD    BINDINGS / MACROS / MOD MATRIX / SCENES / SCRIPTS",
			"DAW    SEQUENCER / ARRANGE / RECORD",
			"SYS    VIZ / ROUTING / PATCHES / SETTINGS",
			"tab cycles within a group, then rolls on",
		},
	},
	{
		"MODULATION",
		{
			"BINDINGS   map CC/foot -> param  (+SHAPE)",
			"MACROS     one control -> many params",
			"MOD MATRIX LFO / env / step -> params",
			"SCENES     snapshot + crossfade the rack",
			"System > Control Surface: latch + MIDI out",
		},
	},
	{
		"INPUTS",
		{
			"encoder + buttons on the panel",
			"footswitch: bypass / record",
			"mouse + keyboard on desktop",
			"game controller: A=sel B=back X=2nd",
			"  Start=play/stop  LB/RB=screens",
			"  dpad/stick: move (hold=accelerate)",
		},
	},
	{
		"SYNTH",
		{
			"load a SYNTH on FX CHAIN (picker)",
			"slot menu > PLAY  on-screen piano",
			"  turn: note  tab: octave  sel: play",
			"SETTINGS > MIDI SYNTH: detected pitch",
			"computer keys: scripts/demod-keyboard.py",
			"SETTINGS > PANIC clears stuck notes",
		},
	},
	{
		"ROUTING",
		{
			"SOURCES -> [ RACK ] -> SINKS",
			"left: what feeds the rack input",
			"right: where its output goes",
			"turn: pick a row   sel: connect/off",
			"needs the desktop rig (PipeWire/JACK)",
		},
	},
}
function ctx.help()
	S.modal = { kind = "help", page = 1, t = 0 }
end

-- first run: show the controls overlay once, then remember it via shared settings
if not CFG.dsp_seen_intro then
	ctx.help()
	CFG.dsp_seen_intro = true
	if SETTINGS and SETTINGS.save then
		pcall(SETTINGS.save, CFG_DIR .. "/settings.lua")
	end
end

local function dsp_modal_nav(action)
	local m = S.modal
	if m.kind == "picker" then
		if action == "next" then
			m.sel = (m.sel % #PICK) + 1
		elseif action == "prev" then
			m.sel = ((m.sel - 2) % #PICK) + 1
		elseif action == "back" then
			S.modal = nil
		elseif action == "activate" then
			local it = PICK[m.sel]
			if not it or it.t == "empty" then
				if dsp.unload_slot then
					dsp.unload_slot(m.slot)
				end
				if ctx.live_remove then
					ctx.live_remove(m.slot)
				end
				ctx.toast("Slot " .. m.slot .. " cleared")
				S.modal = nil
			elseif it.t == "stock" then
				local desc, params = D.effects[it.name] or {}, {}
				for i, pd in ipairs(desc) do
					params[i] =
						{ label = pd.label, min = pd.min, max = pd.max, init = pd.init, step = pd.step, unit = pd.unit }
				end
				if dsp.load_patch then
					dsp.load_patch(
						m.slot,
						{ name = it.name, path = it.name:lower() .. ".dsp", params = params, kind = it.kind }
					)
				else
					dsp.load_slot(m.slot, it.name:lower() .. ".dsp")
				end
				ctx.toast((it.kind == "synth" and "Loaded synth " or "Loaded ") .. it.name, "ok")
				S.modal = nil
			elseif it.t == "patch" then
				if it.locked then
					ctx.toast((it.entry.name or "patch") .. " - LOCKED (no entitlement)", "err")
					-- leave the picker open so another effect/patch can be chosen
				else
					ctx.load_patch_entry(m.slot, it.entry)
					S.modal = nil
				end
			end
		end
	elseif m.kind == "help" then
		if action == "next" then
			m.page = (m.page % #HELP_PAGES) + 1
		elseif action == "prev" then
			m.page = ((m.page - 2) % #HELP_PAGES) + 1
		else -- activate / back close the overlay
			S.modal = nil
		end
	elseif m.kind == "keyboard" then
		if action == "next" then
			m.sel = (m.sel % #KB_KEYS) + 1
		elseif action == "prev" then
			m.sel = ((m.sel - 2) % #KB_KEYS) + 1
		elseif action == "back" then
			S.modal = nil
		elseif action == "activate" then
			local k = KB_KEYS[m.sel]
			if k == "OK" then
				local fn, t = m.onok, m.text
				S.modal = nil
				if fn and #t > 0 then
					fn(t)
				end
			elseif k == "DEL" then
				m.text = m.text:sub(1, -2)
			elseif k == "SPC" then
				if #m.text < 24 then
					m.text = m.text .. " "
				end
			elseif #m.text < 24 then -- cap matches the on-screen counter
				m.text = m.text .. k
			end
		end
	elseif m.kind == "piano" then
		if action == "next" then
			m.note = math.min(96, m.note + 1)
		elseif action == "prev" then
			m.note = math.max(24, m.note - 1)
		elseif action == "tab" then -- octave up
			m.note = math.min(108, m.note + 12)
		elseif action == "tab_prev" then -- octave down
			m.note = math.max(12, m.note - 12)
		elseif action == "activate" or action == "wet" then
			piano_play(m.slot, m.note)
		elseif action == "back" then
			if dsp.all_notes_off then
				dsp.all_notes_off(m.slot)
			end
			S._note_q = {}
			S.modal = nil
		end
	end
end

-- ── nav funnel ──────────────────────────────────────────────────────────
local function nav(action)
	if S.modal then
		dsp_modal_nav(action)
		dm.redraw()
		return
	end
	S.screen = U.clamp(S.screen, 1, #SCREENS)
	-- encoder "grab": while on, the nav encoder drives the performance param instead of
	-- moving the cursor; back releases it (so a pure-encoder panel is never trapped), tab
	-- still switches screens. Toggled from the BINDINGS manager.
	if S._perf_edit then
		if action == "next" then
			bindings.perf_apply(1)
			dm.redraw()
			return
		elseif action == "prev" then
			bindings.perf_apply(-1)
			dm.redraw()
			return
		elseif action == "back" then
			S._perf_edit = false
			ctx.toast("Encoder released")
			dm.redraw()
			return
		end
	end
	-- gamepad/key script trigger: a button mapped to "Script N" (settings.lua) fires the
	-- Nth automation script in the library.
	local sn = action:match("^script(%d+)$")
	if sn then
		automation.fire(automation.scripts[tonumber(sn)], S.t)
		dm.redraw()
		return
	end
	-- gamepad param control: buttons mapped to "Param Up/Down/Toggle" (settings.lua) nudge
	-- or toggle the performance param (the one assigned on the BINDINGS screen).
	-- a macro / the morph set as the modulation perf focus takes the gamepad knob; else
	-- it falls back to the control-surface performance param.
	if action == "param_up" then
		if modulation.perf() then
			modulation.perf_apply(1)
		else
			bindings.perf_apply(1)
		end
		dm.redraw()
		return
	elseif action == "param_down" then
		if modulation.perf() then
			modulation.perf_apply(-1)
		else
			bindings.perf_apply(-1)
		end
		dm.redraw()
		return
	elseif action == "param_toggle" then
		if modulation.perf() then
			modulation.perf_toggle()
		else
			bindings.perf_toggle()
		end
		dm.redraw()
		return
	end
	-- latch the param<->MIDI control surface (a controller button mapped to "Control Surface")
	if action == "cs_toggle" then
		local on = bindings.toggle_enabled()
		ctx.save_bindings()
		ctx.toast("Control Surface " .. (on and "ON" or "OFF"), on and "ok" or "info")
		dm.redraw()
		return
	end
	-- start/stop the ARRANGE song transport from anywhere (it's the master transport, so
	-- a song started on ARRANGE can be stopped from the mixer/FX/etc.)
	if action == "song_toggle" then
		local playing = arrangement.is_playing()
		if playing then
			arrangement.stop()
		else
			arrangement.play()
		end
		ctx.toast("Song " .. (playing and "STOP" or "PLAY"), playing and "info" or "ok")
		dm.redraw()
		return
	end
	local scr = SCREENS[S.screen]
	if scr.nav and scr.nav(ctx, action) then
		dm.redraw()
		return
	end
	-- context transport: the active screen (SEQUENCER/ARRANGE/RECORD) gets first dibs via
	-- scr.nav above; if none claimed it, play_stop falls back to the master song transport,
	-- so one button works from any screen.
	if action == "play_stop" then
		local playing = arrangement.is_playing()
		if playing then
			arrangement.stop()
		else
			arrangement.play()
		end
		ctx.toast("Song " .. (playing and "STOP" or "PLAY"), playing and "info" or "ok")
		dm.redraw()
		return
	end
	-- screen-switch on tab. Screens no longer intercept tab (it's reserved for moving
	-- between screens everywhere), so this always fires — you're never trapped on a screen.
	if action == "tab" then
		ctx.next_screen()
		return
	end
	if action == "tab_prev" then
		ctx.prev_screen()
		return
	end
	if action == "back" then
		S.screen = 1
		dm.redraw()
	end -- back at top → FX chain
end

-- desktop / encoder / serial → on_nav
function on_nav(action)
	nav(action)
end

-- tap-tempo: each tap measures the interval (in app time) → BPM (30..300 window)
local function tap_tempo()
	local now = S.t or 0
	if _tap_last >= 0 then
		local dt = now - _tap_last
		if dt > 0.2 and dt < 2.0 then
			local bpm = math.floor(60 / dt + 0.5)
			S._bpm = bpm
			if dsp.set_bpm then
				dsp.set_bpm(bpm)
			end
			if ctx.toast then
				ctx.toast("Tempo " .. bpm .. " BPM", "ok")
			end
		end
	end
	_tap_last = now
end

-- demod5 hardware (i2c buttons + AS5600) → on_input
function on_input(evt, btn, val)
	if evt == "ENC_CW" or evt == "ENC_ACCEL_CW" then
		nav("next")
	elseif evt == "ENC_CCW" or evt == "ENC_ACCEL_CCW" then
		nav("prev")
	elseif evt == "DOWN" then
		if btn == "NAV_RIGHT" then
			nav("tab")
		elseif btn == "NAV_LEFT" then
			nav("tab_prev")
		elseif btn == "NAV_DOWN" then
			nav("next")
		elseif btn == "NAV_UP" then
			nav("prev")
		elseif btn == "NAV_SELECT" or btn == "ENC_PUSH" then
			nav("activate")
		elseif btn == "NAV_BACK" then
			nav("back")
		elseif btn and btn:match("^FOOT_(%d)$") then
			local slot = tonumber(btn:match("^FOOT_(%d)$"))
			if automation.on_control("foot", slot, S.t) then
				-- a script trigger (or an in-progress assign) claimed this footswitch
			elseif bindings.feed("foot", slot) then
				-- a param binding (or an in-progress PARAMS/BINDINGS assign) claimed it
			elseif modulation.feed("foot", slot) then
				-- a footswitch assigned as a macro driver toggled the macro (or armed it)
			elseif modulation.feed_morph("foot", slot) then
				-- a footswitch assigned as the morph driver snapped scene A<->B
			elseif record and slot == REC_FOOT then
				-- hands-free record toggle
				local rs = record.status()
				if rs.recording then
					record.stop()
				else
					record.start(CFG)
				end
			elseif slot == TAP_FOOT then
				tap_tempo()
			elseif slot == CS_FOOT then
				-- hands-free latch of the param<->MIDI control surface
				local on = bindings.toggle_enabled()
				ctx.save_bindings()
				ctx.toast("Control Surface " .. (on and "ON" or "OFF"), on and "ok" or "info")
			elseif slot == SONG_FOOT then
				-- hands-free start/stop of the ARRANGE song transport
				local playing = arrangement.is_playing()
				if playing then
					arrangement.stop()
				else
					arrangement.play()
				end
				ctx.toast("Song " .. (playing and "STOP" or "PLAY"), playing and "info" or "ok")
			elseif slot == TRANSPORT_FOOT then
				-- hands-free context transport (active screen's play/stop, song fallback)
				nav("play_stop")
			elseif not (slot == LOOPER_FOOT and toggle_looper()) then
				-- LOOPER_FOOT is consumed by the looper toggle above; every other
				-- slot (and a looper foot the looper didn't claim) toggles bypass.
				local sl = dsp.slot(slot)
				if sl then
					dsp.set_bypass(slot, not sl.bypassed)
				end
			end
			-- echo to footswitch LEDs if the host exposes it
			if dm.input_set_leds then
				local mask = 0
				for i = 1, math.min(5, dsp.slot_count()) do
					local s2 = dsp.slot(i)
					if s2 and s2.loaded and not s2.bypassed then
						mask = mask | (1 << (i - 1))
					end
				end
				dm.input_set_leds(mask)
			end
		end
	elseif evt == "LONG_PRESS" and btn == "ENC_PUSH" then
		nav("wet")
	end
	dm.redraw()
end

-- ── update ──────────────────────────────────────────────────────────────
function on_update(dt)
	if dt > 0.05 then
		dt = 0.05
	end
	S.t = S.t + dt
	automation.update(S.t, raw_set_param) -- replay any running scripts (raw = no re-capture)
	modulation.update(dt) -- evaluate LFO/env/step sources on top of automation + manual edits
	arrangement.update(dt) -- song housekeeping (stepping rides clock.on_step via midi.update)
	S.boot = math.min(1, S.boot + dt / 1.0)
	S._live_poll = (S._live_poll or 0) + dt
	if S._live_poll > 1.0 then -- ~1 Hz: pick up patches Home loaded/removed in the background
		S._live_poll = 0
		reconcile_live()
		ctx.refresh_binding_targets() -- keep binding targets in sync with the live rack
	end
	if S._patch_t then
		S._patch_t = S._patch_t + dt
	end
	if S.modal then
		S.modal.t = (S.modal.t or 0) + dt
	end
	for i = #S.toasts, 1, -1 do
		local tt = S.toasts[i]
		tt.t = tt.t + dt
		if tt.t > 2.5 then
			table.remove(S.toasts, i)
		end
	end
	if dsp.poll then
		dsp.poll(dt)
	end
	-- release scheduled synth notes (the piano modal plays note_on then queues a
	-- note_off here); polyphonic, fixed sustain, independent of the active screen.
	if S._note_q then
		for i = #S._note_q, 1, -1 do
			local e = S._note_q[i]
			e.t = e.t - dt
			if e.t <= 0 then
				if dsp.note_off then
					dsp.note_off(e.slot, e.note)
				end
				table.remove(S._note_q, i)
			end
		end
	end
	S.screen = U.clamp(S.screen, 1, #SCREENS)
	local scr = SCREENS[S.screen]
	if scr and scr.update then
		scr.update(ctx, dt)
	end
	midi.update(dt)
	midi_modes.update(ctx)
	dm.redraw()
end

-- ── chrome ──────────────────────────────────────────────────────────────
local function draw_background(W, H)
	U.rect(0, 0, W, H, C.bg)
	-- faint Sierpinski lattice (identity motif), themed + subtle
	local s = math.min(W, H) * 0.95
	dm.draw.sierpinski(
		floor(W / 2),
		floor(H * 0.12),
		floor(W / 2 - s / 2),
		floor(H * 0.95),
		floor(W / 2 + s / 2),
		floor(H * 0.95),
		3,
		{ 0, 0, 0, 0 },
		{ C.turq[1], C.turq[2], C.turq[3], 6 }
	)
	-- phosphor scanlines (Appearance setting; frozen by reduce-motion)
	if CFG.scanlines then
		local off = CFG.reduce_motion and 0 or (S.t * 14) % 4
		for y = 0, H, 4 do
			U.line(0, y + off, W, y + off, C.panel, 28)
		end
	end
	if CFG.vignette then
		U.vignette(W, H)
	end
end

-- Two-level grouped tab bar (scales 320px..desktop). The 15 screens are grouped into
-- RACK/MOD/DAW/SYS (GROUPS); the bar shows the ACTIVE group expanded to its screens +
-- the other groups collapsed to a single label, so at most ~8 cells show instead of 15.
-- Labels derive from each screen module (scr.short / scr.name) so they never desync.
-- Compact panels have no room for tabs, so they show a GROUP . SCREEN breadcrumb +
-- group dots + a position pip (which also teaches where you are in the 15-screen map).
local function draw_tabs(W, H)
	U.gradient_v(0, 0, W, 48, C.panel_hi, C.panel)
	U.line(0, 48, W, 48, C.border, 180)
	local compact = W < 380
	local narrow = W < 560
	local active_gi = SCREEN_GROUP[S.screen] or 1
	local ag = GROUPS[active_gi]
	-- position of the active screen within its group (for the compact pip)
	local within, total_in_g = 1, #ag.idxs
	for i, idx in ipairs(ag.idxs) do
		if idx == S.screen then
			within = i
			break
		end
	end

	if compact then
		local cur = SCREENS[S.screen]
		local name = T((cur and cur.name) or "")
		local bc = "<  " .. ag.id .. " . " .. name .. "  >"
		if U.text_w(bc) > W - 16 then -- fall back to the short name if the full one won't fit
			name = T((cur and (cur.short or cur.name)) or "")
			bc = "<  " .. ag.id .. " . " .. name .. "  >"
		end
		U.text_c(W / 2, 8, U.ellipsize(bc, W - 16), C.white, 245)
		-- group dots (active filled in its accent) + "[n/m]" position within the group
		local n = #GROUPS
		local dx = W / 2 - (n - 1) * 8
		for gi, grp in ipairs(GROUPS) do
			local on = (gi == active_gi)
			U.circle(dx + (gi - 1) * 16, 34, on and 4 or 2, on and grp.accent or C.border, on and 230 or 140)
		end
		U.text_r(W - 10, 30, "[" .. within .. "/" .. total_in_g .. "]", C.dim, 150)
		return
	end

	U.text(16, 8, "DSP", C.turq, 230)
	if not narrow then
		U.text(16 + 4 * 8, 8, "STUDIO", C.violet, 200)
	end
	local tabsX = narrow and 56 or 168
	local pad = 10 -- per-cell horizontal padding (8px font)

	-- cells: active group expands to one cell per screen; other groups collapse to a label
	local cells = {}
	for gi, g in ipairs(GROUPS) do
		if gi == active_gi then
			for _, idx in ipairs(g.idxs) do
				cells[#cells + 1] = { screen = idx, accent = g.accent }
			end
		else
			cells[#cells + 1] = { group = gi, accent = g.accent }
		end
	end

	local available = W - tabsX - 24 -- leave room for the flanking < >
	local function labelOf(c, useShort)
		if c.group then
			return GROUPS[c.group].id -- group ids (RACK/MOD/...) are trade dress, untranslated
		end
		local scr = SCREENS[c.screen]
		return T((useShort and (scr.short or scr.name)) or scr.name)
	end
	local function totalWidth(useShort)
		local w = 0
		for _, c in ipairs(cells) do
			w = w + U.text_w(labelOf(c, useShort)) + pad
		end
		return w
	end
	-- fit cascade: full names → short labels → ellipsize (only the last for a future huge group)
	local useShort = narrow or (totalWidth(false) > available)
	local ellip = (totalWidth(useShort) > available) and math.floor(available / #cells) or nil

	-- "< >" flanking the cells signals they're switchable (tab / NAV_LEFT-RIGHT)
	U.text(tabsX - 12, 16, "<", C.dim, 150)
	local x = tabsX
	for _, c in ipairs(cells) do
		local label = labelOf(c, useShort)
		if ellip then
			label = U.ellipsize(label, ellip - pad)
		end
		local cw = U.text_w(label) + pad
		if c.screen then
			local on = (c.screen == S.screen)
			if on then
				U.rect(x, 6, cw - 6, 36, c.accent, 30)
				U.tline(x, 6, x + cw - 6, 6, 2, c.accent, 230)
				U.glowline(x, 41, x + cw - 6, 41, c.accent, 230, 3)
			end
			-- members of the active group read in the group accent (dim when not the
			-- current screen), binding the expanded group together visually
			U.text_c(x + (cw - 6) / 2, 16, label, on and C.white or c.accent, on and 255 or 170)
		else
			U.text_c(x + (cw - 6) / 2, 16, label, c.accent, 150) -- collapsed (non-active) group
		end
		x = x + cw
	end
	U.text(x + 2, 16, ">", C.dim, 150)
end

local function draw_status(W, H)
	local m = dsp.meters() or {}
	local sy = H - 22
	U.line(0, H - 30, W, H - 30, C.border, 140)
	local compact = W < 380
	U.text(16, sy, "BKND", C.dim, 150)
	U.text(16 + 5 * 8, sy, (backend_name or "?"):upper(), C.green, 200)
	if compact then
		U.text(120, sy, string.format("P %.0f", m.pitch_hz or 0), C.dim, 140)
	else
		U.text(200, sy, string.format("PITCH %.0fHz", m.pitch_hz or 0), C.dim, 160)
		U.text(360, sy, string.format("BPM %.0f", m.bpm or 0), C.dim, 160)
		for b = 0, 3 do
			local on = (m.beat or 0) == b
			U.circle(470 + b * 16, sy + 6, on and 4 or 2, on and C.turq or C.border, on and 230 or 140)
		end
	end
	-- master-transport cue: show the song is running even when you've left the ARRANGE screen
	if arrangement.is_playing() then
		U.text_r(W - 16, sy, string.format(">SONG b%d", arrangement.song_bar()), C.green, 220)
	end
end

local function draw_boot(W, H)
	if S.boot >= 1 then
		return
	end
	local p = S.boot
	local a = floor((1 - p) * 255)
	U.rect(0, 0, W, H, C.bg, a)
	-- a Sierpinski-glow assemble, matching the home shell's boot
	local s = math.min(W, H) * 0.34 * (0.5 + p * 0.5)
	local cx, cy = W / 2, H / 2
	dm.draw.sierpinski_glow(
		floor(cx),
		floor(cy - s * 0.6),
		floor(cx - s * 0.7),
		floor(cy + s * 0.5),
		floor(cx + s * 0.7),
		floor(cy + s * 0.5),
		3,
		{ 0, 0, 0, 0 },
		{ C.turq[1], C.turq[2], C.turq[3], floor(a * 0.8) },
		{ C.turq[1], C.turq[2], C.turq[3], a },
		8
	)
	U.text_c(cx, cy + s * 0.6 + 12, "DSP STUDIO", C.turq, a)
end

-- a "patch live in the engine" banner under the tab bar (bright then settles)
local function draw_patch_banner(W, H)
	if not S._patch_name then
		return
	end
	local fresh = (S._patch_t or 99) < 3
	local a = fresh and floor(180 + 70 * math.abs(math.sin(S.t * 4))) or 150
	local label = "PATCH LIVE: " .. S._patch_name
	U.rect(W / 2 - (#label * 8) / 2 - 8, 52, #label * 8 + 16, 18, C.turq, fresh and 38 or 18)
	U.text_c(W / 2, 56, label, C.turq, a)
end

-- encoder-grab indicator: while on, the nav encoder is driving the performance param
local function draw_perf_indicator(W, H)
	if not S._perf_edit then
		return
	end
	local t = ctx.bindings and ctx.bindings.target(ctx.bindings.perf())
	local label = "KNOB: " .. (t and U.ellipsize(t.label, 200) or "(no perf param)")
	local a = floor(180 + 70 * math.abs(math.sin(S.t * 4)))
	U.rect(W / 2 - (#label * 8) / 2 - 8, 52, #label * 8 + 16, 18, C.violet, 38)
	U.text_c(W / 2, 56, label, C.violet, a)
end

-- effect picker (load into a slot) + on-screen keyboard (name entry) + toasts
local function draw_picker(W, H)
	local m = S.modal
	local n = #PICK
	local rowH = 24
	U.rect(0, 0, W, H, C.bg, floor(180 * math.min((m.t or 0) * 8, 1)))
	local bw = math.min(W * 0.84, 440)
	-- scroll window so the list always fits the screen height
	local maxRows = math.max(3, math.min(n, math.floor((H - 150) / rowH)))
	local infoH = 30
	local bh = 46 + maxRows * rowH + infoH
	local bx, by = floor(W / 2 - bw / 2), math.max(40, floor(H / 2 - bh / 2))
	U.gradient_v(bx, by, bw, bh, C.panel_hi, C.panel)
	U.rect(bx, by, bw, bh, C.panel)
	U.tline(bx, by, bx + bw, by, 2, C.turq, 255)
	U.tline(bx, by + bh, bx + bw, by + bh, 2, C.turq, 255)
	U.text(bx + 16, by + 14, string.format("LOAD INTO SLOT %02d", m.slot), C.turq, 255)
	if n > maxRows then
		U.text_r(bx + bw - 16, by + 14, string.format("%d/%d", m.sel, n), C.dim, 150)
	end
	-- keep the selection visible
	local off = 0
	if m.sel > maxRows then
		off = math.min(m.sel - maxRows, math.max(0, n - maxRows))
	end
	for row = 1, maxRows do
		local i = row + off
		if i > n then
			break
		end
		local it = PICK[i]
		local ry = by + 40 + (row - 1) * rowH
		local sel = (i == m.sel)
		if sel then
			U.rect(bx + 8, ry, bw - 16, rowH - 4, C.turq, 40)
			U.tline(bx + 8, ry, bx + 8, ry + rowH - 4, 3, C.turq, 255)
		end
		U.text(bx + 22, ry + 4, it.label, sel and C.white or C.dim, sel and 255 or (it.locked and 110 or 180))
		-- type chip right after the name: marketplace patch vs stock instrument
		local chipx = bx + 22 + (#it.label + 1) * 8
		if it.t == "patch" then
			U.text(chipx, ry + 4, "[PCH]", C.turq, sel and 220 or 150)
		elseif it.kind == "synth" then
			U.text(chipx, ry + 4, "[SYN]", C.violet, sel and 220 or 150)
		end
		local rtag = it.locked and "LOCKED" or it.category
		if rtag then
			U.text_r(bx + bw - 16, ry + 4, rtag, it.locked and C.red or C.dim, sel and 200 or 110)
		end
	end
	-- description of the selected effect (truncated to width; ASCII only)
	local sit = PICK[m.sel] or PICK[1]
	local info
	if sit.t == "empty" then
		info = "Clear this slot (passthrough)."
	elseif sit.t == "stock" then
		info = (sit.desc and (sit.desc .. "  (" .. (sit.np or 0) .. " params)")) or ((sit.np or 0) .. " params")
	else
		info = sit.locked and ("PAID - locked (no entitlement). " .. (sit.desc or ""))
			or (sit.desc and sit.desc ~= "" and sit.desc or "Marketplace patch.")
	end
	info = U.ellipsize(info, bw - 32)
	local iy = by + 40 + maxRows * rowH
	U.line(bx + 12, iy + 2, bx + bw - 12, iy + 2, C.border, 120)
	U.text(bx + 16, iy + 8, info, C.dim, 200)
	U.text_c(W / 2, by + bh + 12, "[ turn: choose   press: load   back: cancel ]", C.dim, 150)
end
local function draw_keyboard(W, H)
	local m = S.modal
	U.rect(0, 0, W, H, C.bg, floor(190 * math.min((m.t or 0) * 8, 1)))
	local bw = math.min(W * 0.86, 560)
	local bh = 168
	local bx, by = floor(W / 2 - bw / 2), floor(H / 2 - bh / 2)
	U.gradient_v(bx, by, bw, bh, C.panel_hi, C.panel)
	U.rect(bx, by, bw, bh, C.panel)
	U.tline(bx, by, bx + bw, by, 2, C.turq, 255)
	U.tline(bx, by + bh, bx + bw, by + bh, 2, C.turq, 255)
	U.text(bx + 16, by + 12, m.title, C.turq, 255)
	U.rect(bx + 16, by + 34, bw - 32, 22, C.bg, 200)
	local caret = (math.floor((m.t or 0) * 2) % 2 == 0) and "|" or " "
	U.text(bx + 24, by + 38, m.text .. caret, C.white, 230)
	U.text_r(bx + bw - 24, by + 38, tostring(#m.text) .. "/24", C.dim, 130)
	local cols = 13
	local kw = (bw - 32) / cols
	local kh = 26
	local gy = by + 66
	for i, k in ipairs(KB_KEYS) do
		local r = floor((i - 1) / cols)
		local c = (i - 1) % cols
		local kx = floor(bx + 16 + c * kw)
		local ky = gy + r * kh
		local sel = (i == m.sel)
		if sel then
			U.rect(kx, ky, floor(kw) - 2, kh - 2, C.turq, 60)
			U.tline(kx, ky, kx, ky + kh - 2, 2, C.turq, 255)
		end
		U.text_c(kx + kw / 2, ky + 5, k, sel and C.white or C.dim, sel and 255 or 180)
	end
	U.text_c(W / 2, by + bh + 12, "[ turn: keys   press: type / OK   back: cancel ]", C.dim, 150)
end
local function draw_help(W, H)
	local m = S.modal
	local page = HELP_PAGES[m.page] or HELP_PAGES[1]
	local lines = page[2]
	U.rect(0, 0, W, H, C.bg, floor(205 * math.min((m.t or 0) * 8, 1)))
	local bw = math.min(W * 0.9, 520)
	local bh = 70 + #lines * 22
	local bx, by = floor(W / 2 - bw / 2), math.max(40, floor(H / 2 - bh / 2))
	U.gradient_v(bx, by, bw, bh, C.panel_hi, C.panel)
	U.rect(bx, by, bw, bh, C.panel)
	U.tline(bx, by, bx + bw, by, 2, C.turq, 255)
	U.tline(bx, by + bh, bx + bw, by + bh, 2, C.turq, 255)
	U.text(bx + 16, by + 12, "HELP - " .. page[1], C.turq, 255)
	U.text_r(bx + bw - 16, by + 12, string.format("%d/%d", m.page, #HELP_PAGES), C.dim, 160)
	for i, ln in ipairs(lines) do
		U.text(bx + 20, by + 40 + (i - 1) * 22, ln, C.white, 210)
	end
	U.text_c(W / 2, by + bh + 12, "[ turn: page   sel/back: close ]", C.dim, 160)
end
-- on-screen piano: one octave centred on the selected note; turn moves chromatically
-- (auto-crossing octaves), tab shifts an octave, sel plays. Instruments read violet.
local PIANO_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local PIANO_WHITE = { 0, 2, 4, 5, 7, 9, 11 } -- semitone of each of the 7 white keys
local PIANO_WHITE_NAME = { "C", "D", "E", "F", "G", "A", "B" }
local PIANO_BLACK_AFTER = { [0] = 1, [1] = 3, [3] = 6, [4] = 8, [5] = 10 } -- black after white wi
local function draw_piano(W, H)
	local m = S.modal
	U.rect(0, 0, W, H, C.bg, floor(190 * math.min((m.t or 0) * 8, 1)))
	local bw = math.min(W * 0.88, 560)
	local bh = 196
	local bx, by = floor(W / 2 - bw / 2), math.max(40, floor(H / 2 - bh / 2))
	U.gradient_v(bx, by, bw, bh, C.panel_hi, C.panel)
	U.rect(bx, by, bw, bh, C.panel)
	U.tline(bx, by, bx + bw, by, 2, C.violet, 255)
	U.tline(bx, by + bh, bx + bw, by + bh, 2, C.violet, 255)
	local sl = dsp.slot(m.slot)
	U.text(bx + 16, by + 12, string.format("PLAY  SLOT %02d", m.slot), C.violet, 255)
	U.text_r(bx + bw - 16, by + 12, U.ellipsize((sl and sl.name) or "SYNTH", 160), C.dim, 180)

	local oct = math.floor(m.note / 12) - 1
	local semi = m.note % 12
	U.text_c(W / 2, by + 38, PIANO_NAMES[semi + 1] .. tostring(oct), C.white, 255)

	local kx0 = bx + 24
	local kw = (bw - 48) / 7
	local ky = by + 78
	local wkh = bh - (ky - by) - 26
	for wi = 0, 6 do
		local on = (semi == PIANO_WHITE[wi + 1])
		local nx = floor(kx0 + wi * kw)
		U.rect(nx + 1, ky, floor(kw) - 2, wkh, on and C.violet or C.white, on and 235 or 36)
		U.text_c(nx + kw / 2, ky + wkh - 16, PIANO_WHITE_NAME[wi + 1], on and C.bg or C.dim, on and 255 or 150)
	end
	local bkw = kw * 0.62
	local bkh = wkh * 0.58
	for wi = 0, 5 do
		local s = PIANO_BLACK_AFTER[wi]
		if s then
			local nx = floor(kx0 + (wi + 1) * kw - bkw / 2)
			U.rect(nx, ky, floor(bkw), floor(bkh), (semi == s) and C.violet or C.bg, 255)
		end
	end
	U.text_c(W / 2, by + bh + 12, "[ turn: note   tab: octave   sel: play   back: close ]", C.dim, 150)
end
local DSP_TC = { info = C.turq, ok = C.green, warn = C.yellow, err = C.red }
local function draw_dsp_toasts(W, H)
	for i, tt in ipairs(S.toasts) do
		local col = DSP_TC[tt.kind] or C.turq
		local a = floor(255 * math.max(0, math.min(tt.t * 8, (2.5 - tt.t) * 4, 1)))
		if a > 0 then
			local tw = #tt.msg * 8 + 24
			local bx = W - tw - 16
			local by = H - 48 - (#S.toasts - i) * 28
			U.gradient_v(bx, by, tw, 22, C.panel_hi, C.panel)
			U.rect(bx, by, tw, 22, col, floor(a * 0.14))
			U.tline(bx, by, bx, by + 22, 3, col, a)
			U.text(bx + 10, by + 3, tt.msg, col, a)
		end
	end
end

-- ── frame ───────────────────────────────────────────────────────────────
function on_draw()
	local W, H = dm.width(), dm.height()
	draw_background(W, H)
	S.screen = U.clamp(S.screen, 1, #SCREENS)
	local scr = SCREENS[S.screen]
	if scr then
		scr.draw(ctx, W, H)
	end
	draw_tabs(W, H)
	draw_patch_banner(W, H)
	draw_perf_indicator(W, H)
	draw_status(W, H)
	if S.modal then
		if S.modal.kind == "picker" then
			draw_picker(W, H)
		elseif S.modal.kind == "keyboard" then
			draw_keyboard(W, H)
		elseif S.modal.kind == "help" then
			draw_help(W, H)
		elseif S.modal.kind == "piano" then
			draw_piano(W, H)
		end
	end
	draw_dsp_toasts(W, H)
	U.brackets(W, H, C.turq) -- console corner frame (matches home)
	draw_boot(W, H)
end

io.stderr:write("[dsp] DSP STUDIO up — backend=" .. backend_name .. "\n")
