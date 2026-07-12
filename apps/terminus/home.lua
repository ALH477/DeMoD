-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  TERMINUS Home — DeMoD unified shell (native demod-ui port)

  Polished build with full sub-menu integration: every channel opens into its
  own "blade" detail panel with its own focusable entries, previews, and back
  navigation. Same single focus-field model funnels every input.

  Run:  ./demod-ui home.lua
  Headless test: SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 ./demod-ui home.lua

  © 2026 DeMoD LLC. Private.
============================================================================ ]]

-- ── Palette ─────────────────────────────────────────────────────────────
local COL = {
	bg = { 10, 10, 15 },
	panel = { 18, 18, 30 },
	panel_hi = { 26, 26, 46 },
	border = { 42, 42, 62 },
	turq = { 0, 245, 212 },
	violet = { 139, 92, 246 },
	white = { 232, 232, 240 },
	dim = { 106, 106, 134 },
	red = { 255, 76, 106 },
	green = { 76, 255, 130 },
	yellow = { 255, 217, 76 },
}

-- ── Channels + their sub-menus (the "other menus" integrated) ────────────
local CHANNELS = {
	{
		id = "dsp",
		name = "DSP STUDIO",
		tag = "Effects . Synth",
		accent = COL.turq,
		preview = "dsp",
		items = {
			{ label = "Effects Rack", meta = "6 slots . live" },
			{ label = "Synth Engine", meta = "Faust . poly" },
			{ label = "XY Pad", meta = "morph . macro" },
			{ label = "Tuner", meta = "E2 . 82 Hz" },
			{ label = "Save Preset", meta = "local . cloud" },
		},
	},
	{
		id = "lyrics",
		name = "LYRICS",
		tag = "Worship . Karaoke",
		accent = COL.violet,
		preview = "lyrics",
		items = {
			{ label = "Open Display", meta = "stage output", lyrics = "launch" },
			{ label = "Load Set", meta = ".dls / .lrc", lyrics = "load" },
			{ label = "Play / Pause", meta = "transport", lyrics = "toggle" },
			{ label = "Next Section", meta = "bar quantized", lyrics = "next" },
			{ label = "Tap Tempo", meta = "clock", lyrics = "tap" },
			{ label = "Setlist", meta = "sections", lyrics = "sections" },
			{ label = "Now Playing", meta = "status", lyrics = "status" },
			{ label = "Display Style", meta = "LRC mode", lyrics = "style" },
		},
	},
	{
		id = "ferro",
		name = "FERROFLUID",
		tag = "Faraday Visualizer",
		accent = COL.green,
		preview = "ferro",
		items = {
			{ label = "Pattern Mode", meta = "hex . spiral" },
			{ label = "Sensitivity", meta = "audio-react" },
			{ label = "Palette", meta = "phosphor" },
			{ label = "Fullscreen", meta = "output" },
		},
	},
	{
		id = "market",
		name = "MARKETPLACE",
		tag = "Patches . USB-C Bridge",
		accent = COL.yellow,
		preview = "market",
		items = {
			{ label = "Sync via USB-C", meta = "companion" },
			{ label = "My Patches", meta = "StreamDB" },
			{ label = "Featured", meta = "from bridge" },
			{ label = "Sell a Patch", meta = "upload" },
		},
	},
	{
		id = "learn",
		name = "LEARN",
		tag = "Music from Zero",
		accent = COL.turq,
		preview = "learn",
		items = {
			{ label = "Notes & Tuner", meta = "pitch . names", lesson = "pitch" },
			{ label = "Rhythm & Timing", meta = "metronome . tap", lesson = "rhythm" },
			{ label = "Scales & Intervals", meta = "what fits", lesson = "intervals" },
			{ label = "Ear / Play-Along", meta = "listen . repeat", lesson = "ear" },
		},
	},
	{
		id = "settings",
		name = "SYSTEM",
		tag = "Settings . Status",
		accent = COL.red,
		preview = "settings",
		items = {
			{ label = "Appearance", meta = "theme . crt" },
			{ label = "Layout", meta = "pages . scale" },
			{ label = "Input", meta = "encoder" },
			{ label = "Controller", meta = "remap buttons" },
			{ label = "MIDI", meta = "device . clock . cc" },
			{ label = "Control Surface", meta = "latch . mode . midi out" },
			{ label = "System", meta = "status . reset" },
			{ label = "Ownership", meta = "adopt . license" },
			{ label = "Help", meta = "controls" },
			{ label = "Power", meta = "restart . off" },
		},
	},
}

-- ── Channel launch wiring ────────────────────────────────────────────────
-- Single-display console model. Activating a blade item hands the framebuffer
-- to the target app. Under the `terminus` supervisor ($TERMINUS_LAUNCH set) we
-- write the command + dm.quit(); the supervisor runs it and returns us to home
-- when it exits. With no supervisor (desktop dev) we fall back to dm.exec, which
-- backgrounds the app in a second window. Each channel's `launch.probe` is
-- existence-checked so a missing target shows an error in the blade instead of
-- silently failing; blade items may carry a `screen` for deep-linking.
-- our own directory (".." when run as a bare relative filename with no dir part)
local BASE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

-- Steam edition (DEMOD_EDITION=steam, set by the Steam launcher): an SSA-clean,
-- instrument-only build. The MARKETPLACE channel becomes a native WORKSHOP browser, a
-- DeMoD HARDWARE showcase advertises the instrument, and the off-Steam paid-patch gate +
-- USB-C bridge are inert (Steam/DLC is the entitlement authority). steam.lua no-ops when
-- the Steamworks binding is absent, so this same file runs unchanged on every edition.
local STEAM = dofile(BASE .. "/steam.lua")
local STEAM_ED = STEAM.is_edition()
local HOMEENV = os.getenv("HOME")
local function exists(p)
	if not p then
		return false
	end
	local f = io.open(p, "r")
	if f then
		f:close()
		return true
	end
	return false
end

-- ── Startup integrity self-check (tamper-evidence; see integrity.lua) ─────────
-- Verifies the signed-build manifest + per-file hashes of the running app dir. Warn,
-- don't brick (field patches must not hard-fail); DEMOD_STRICT_INTEGRITY=1 refuses.
local INTEG = (function()
	local ok, mod = pcall(dofile, BASE .. "/integrity.lua")
	if not ok or type(mod) ~= "table" or not mod.check then
		return { ok = true, skipped = "no integrity module", rev = "dev" }
	end
	return mod.check(BASE, os.getenv("DEMOD_UI_BIN")) -- also measure the host binary (D3)
end)()
io.stderr:write(
	string.format(
		"[TERMINUS] build rev=%s integrity=%s%s\n",
		INTEG.rev or "?",
		INTEG.ok and (INTEG.signed and "signed-ok" or (INTEG.skipped or "hash-ok")) or "FAIL",
		(INTEG.problems and #INTEG.problems > 0) and (" [" .. table.concat(INTEG.problems, "; ") .. "]") or ""
	)
)
if os.getenv("DEMOD_STRICT_INTEGRITY") == "1" and not INTEG.ok and dm.quit then
	io.stderr:write("[TERMINUS] strict integrity: refusing to run a tampered build.\n")
	dm.quit()
end

-- POSIX shell single-quote: wrap in '...' and escape embedded quotes. Use for ANY value
-- interpolated into a shell command — patch ids/paths originate in a manifest written by
-- the bridge/indexer and must not be trusted as shell syntax. See SECURITY.md F-6.
local function shq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end
-- resolve the demod-ui binary: env → sibling copy → framework repo → PATH name
local UIBIN = os.getenv("DEMOD_UI_BIN")
if not (UIBIN and exists(UIBIN)) then
	if exists(BASE .. "/demod-ui") then
		UIBIN = BASE .. "/demod-ui"
	elseif HOMEENV and exists(HOMEENV .. "/demod-ui/demod-ui") then
		UIBIN = HOMEENV .. "/demod-ui/demod-ui"
	else
		UIBIN = "demod-ui"
	end
end
local LAUNCH_FILE = os.getenv("TERMINUS_LAUNCH")

-- launch_now: hand off the display (supervisor) or background it (desktop dev).
function launch_now(cmd)
	if LAUNCH_FILE then
		local f = io.open(LAUNCH_FILE, "w")
		if f then
			f:write(cmd)
			f:close()
		end
		if dm.quit then
			dm.quit()
		end
	elseif dm.exec then
		dm.exec(cmd)
	end
end

local duck_anim = dofile(BASE .. "/patches/duck-anim.lua")
duck_anim.init()

-- spec: an env override (full command, trusted, no probe) wins; otherwise a
-- desktop-default command plus a probe path that must exist (else NOT INSTALLED).
local function spec(env_cmd, default_cmd, probe)
	if env_cmd and env_cmd ~= "" then
		return { cmd = env_cmd, probe = nil }
	end
	return { cmd = default_cmd, probe = probe }
end
local DL = (HOMEENV or ".") .. "/Downloads" -- desktop dev location of sibling repos

-- Channel 1 — DSP STUDIO → dsp_studio.lua, with per-item screen deep-links.
local DSP_ENTRY = os.getenv("DEMOD_DSP_STUDIO") or (BASE .. "/dsp/dsp_studio.lua")
CHANNELS[1].launch = { cmd = UIBIN .. " " .. DSP_ENTRY, probe = DSP_ENTRY }
-- Deep-link by screen NAME/short (DSP Studio resolves it), so these survive screens
-- being inserted or reordered — a raw index silently drifts (it did, before this).
CHANNELS[1].items[1].screen = "fx" -- Effects Rack → FX CHAIN
CHANNELS[1].items[4].screen = "viz" -- Tuner       → VISUALIZER (pitch meters)
CHANNELS[1].items[5].screen = "settings" -- Save Preset → SETTINGS (presets)

-- Channel 2 — LYRICS → demod-lyrics stage display + lyrics_cli TCP controller.
-- Built on the RISC-V device (not cross-built); missing → NOT INSTALLED.
local LYR = DL .. "/demod-lyrics/demod-lyrics"
local LYR_SCORE = os.getenv("DEMOD_LYRICS_SCORE") or (DL .. "/demod-lyrics/worship_set.dls")
local LYR_LRC = os.getenv("DEMOD_LYRICS_LRC") or (DL .. "/demod-lyrics/test.lrc")
local LYR_FILE = os.getenv("DEMOD_LYRICS_FILE") or (exists(LYR_SCORE) and LYR_SCORE or LYR_LRC)
local LYR_CLI_ROOT = DL .. "/lyrics_cli"
local LYR_CLI_ENV = os.getenv("DEMOD_LYRICS_CLI")
local LYR_CLI
if LYR_CLI_ENV and LYR_CLI_ENV ~= "" then
	LYR_CLI = LYR_CLI_ENV
elseif exists(LYR_CLI_ROOT .. "/demod/cli.py") then
	LYR_CLI = "PYTHONPATH=" .. shq(LYR_CLI_ROOT) .. " python3 -m demod.cli"
else
	LYR_CLI = "demod-cli"
end
local LYR_HOST = os.getenv("DEMOD_LYRICS_HOST") or "localhost"
local LYR_PORT = tonumber(os.getenv("DEMOD_LYRICS_PORT") or "") or 7709
local LYR_TIMEOUT = os.getenv("DEMOD_LYRICS_TIMEOUT") or "0.5"
CHANNELS[2].launch = spec(os.getenv("DEMOD_LYRICS"), shq(LYR), LYR)

-- Channel 3 — FERROFLUID → demod-ferrofluid-rt realtime visualizer.
local FERRO = DL .. "/demod-ferrofluid/realtime/demod-ferrofluid-rt"
CHANNELS[3].launch = spec(os.getenv("DEMOD_FERRO"), FERRO, FERRO)

-- Channel 5 — LEARN → the free music-from-zero patch app (patches/demod-learn).
-- Each blade item deep-links straight into its lesson via DEMOD_LEARN_LESSON.
local LEARN = os.getenv("DEMOD_LEARN") or (BASE .. "/patches/demod-learn/main.lua")
CHANNELS[5].launch = { cmd = UIBIN .. " " .. LEARN, probe = LEARN }

-- Steam-edition reshape: WORKSHOP (free community patches via Steam) replaces the USB-C
-- marketplace channel, and a HARDWARE showcase advertises the instrument. Done AFTER the
-- index-based wiring above so slots 1..6 stay valid; HARDWARE is appended (no index shift).
if STEAM_ED then
	for _, ch in ipairs(CHANNELS) do
		if ch.id == "market" then
			ch.name = "WORKSHOP"
			ch.tag = "Community Patches . Steam"
			ch.items = {
				{ label = "Browse Workshop", meta = "community", wk = "browse" },
				{ label = "My Subscriptions", meta = "installed", wk = "subs" },
				{ label = "How It Works", meta = "free . community", wk = "info" },
			}
		end
	end
	CHANNELS[#CHANNELS + 1] = {
		id = "hardware",
		name = "DEMOD HARDWARE",
		tag = "The Instrument",
		accent = COL.turq,
		preview = "systems",
		items = {
			{ label = "The Guitar", meta = "RISC-V . on-board DSP" },
			{ label = "Why Hardware", meta = "low-latency . standalone" },
			{ label = "Full Marketplace", meta = "lives on the device" },
			{ label = "Get the Instrument", meta = "demod.ltd", hw = "store" },
		},
	}
	-- PACKS: the paid DLC bundles (Metal Forge / Voices / Effects + the Deluxe Complete-the-Set),
	-- read from the generated patches/bundles.lua. Each shows owned/locked (steam.dlc_owned no-ops
	-- to locked until the SDK) and a "Buy on Steam" overlay CTA — the in-app DLC upsell.
	local okb, BD = pcall(dofile, BASE .. "/patches/bundles.lua")
	local bundles = (okb and type(BD) == "table" and BD.bundles) or {}
	if #bundles > 0 then
		local items = {}
		for _, b in ipairs(bundles) do
			local owned = b.dlc_appid and STEAM.dlc_owned(b.dlc_appid)
			items[#items + 1] = {
				label = b.name,
				meta = (owned and "OWNED" or ("$" .. tostring(b.steam_price)))
					.. (b.complete_the_set and " . Complete the Set" or " . Steam DLC"),
				pack = b,
			}
		end
		CHANNELS[#CHANNELS + 1] = {
			id = "packs",
			name = "PACKS",
			tag = "DLC . Complete the Set",
			accent = COL.yellow,
			preview = "market",
			items = items,
		}
	end
	io.stderr:write(string.format("[TERMINUS] Steam edition: WORKSHOP + HARDWARE + PACKS (%d channels)\n", #CHANNELS))
end

-- Patches (page 2) load via the patches.lua module further below, once the
-- config dir (owner path) is known. See that block + PATCHES.md.

-- ── Settings + customization (dedicated, persisted) ──────────────────────
-- Loaded once at boot; the shell reads CFG live each frame and saves on edit.
-- See settings.lua (schema/persistence/themes) and the System channel.
local CFG_DIR = os.getenv("DEMOD_CONFIG")
	or ((os.getenv("XDG_CONFIG_HOME") or (HOMEENV and HOMEENV .. "/.config") or ".") .. "/demod")
local CFG_PATH = CFG_DIR .. "/settings.lua"
local SET = dofile(BASE .. "/settings.lua")
SET.load(CFG_PATH)
local CFG = SET.values
SET.apply_theme(COL, CFG.theme)
SET.apply_gamepad() -- push the persisted controller mapping to the framework
local midi = dofile(BASE .. "/midi/init.lua") -- shared MIDI subsystem (owns on_midi)
SET.midi_refresh_devices(midi)
SET.apply_midi(midi) -- push persisted MIDI config (device/channel/clock/velocity/thru)

-- Steam edition: bring up Steamworks once so DLC ownership + overlay callbacks flow.
-- No-ops (and harmless) on every non-Steam build, the device, or with no Steam client.
if STEAM_ED then
	STEAM.init()
end

-- ── Patches + device ownership (page 2) ──────────────────────────────────
-- patches.lua owns the index (load/validate/sort) + licensing (adopt/wipe).
-- The account that "owns" this guitar comes from the USB-C bridge ($DEMOD_ACCOUNT,
-- the companion's logged-in account this session); adopting under a different
-- account wipes all paid patches. See PATCHES.md.
local PM = dofile(BASE .. "/patches.lua")
-- take recorder: shared with DSP Studio; home shows a "REC" badge while a take is
-- running (the recorder is detached, so it persists across app switches).
local REC = (function()
	local ok, r = pcall(dofile, BASE .. "/record.lua")
	return ok and r or nil
end)()
local PATCH_DIRS = {}
do
	local pd = os.getenv("DEMOD_PATCH_DIR") or (HOMEENV and (HOMEENV .. "/.nix-profile/share/demod/patches"))
	if pd then
		PATCH_DIRS[#PATCH_DIRS + 1] = pd
	end
	PATCH_DIRS[#PATCH_DIRS + 1] = BASE .. "/patches" -- desktop dev stub
end
local OWNER_PATH = os.getenv("DEMOD_OWNER") or (CFG_DIR .. "/owner.lua")
-- user-arranged patch order (Reorder), persisted next to settings so it survives
-- the indexer regenerating index.lua. See PATCHES.md.
local ORDER_PATH = os.getenv("DEMOD_PATCH_ORDER") or (CFG_DIR .. "/patch-order.lua")
local ACCOUNT = os.getenv("DEMOD_ACCOUNT") -- bridge/companion account (this session)
local PATCH_REMOVE = os.getenv("DEMOD_PATCH_REMOVE") -- device removal cmd template ("%s" = id)
-- Desktop rig: the Tauri marketplace companion (demod-edge-system storefront).
-- Set by the demod-desktop launcher; when present, the Marketplace channel opens
-- it as a windowed sibling (it talks to the local bridge on 127.0.0.1:7635). On
-- the device this is unset → the honest USB-C bridge modal is shown instead.
local MARKET = os.getenv("DEMOD_MARKETPLACE")
if MARKET == "" then
	MARKET = nil
end

local function patch_remove_hook(id)
	if PATCH_REMOVE and dm.exec then
		dm.exec((PATCH_REMOVE:gsub("%%s", function()
			return shq(id)
		end)))
		return true -- dispatched (fire-and-forget; device removal can't be confirmed here)
	end
	return false -- no device hook configured (desktop / no bridge)
end
local function ui_normalize_patches() -- UI-only fields (module is UI-agnostic)
	for _, p in ipairs(PM.list) do
		if not p.accent then
			p.accent = PM.is_paid(p) and COL.yellow or COL.turq
		end
		if not p.tag then
			p.tag = (p.type == "synth" and "Faust Synth") or (p.type == "fx" and "Faust FX") or "Program"
		end
		p.preview = (p.type == "fx" or p.type == "synth") and "fx" or "program"
	end
end
-- ── Signed entitlements (gate paid patches cryptographically) ────────────────
-- A paid patch is usable only under a valid, unexpired, account-matching entitlement
-- token signed by the marketplace's entitlement key. We verify it client-side with the
-- embedded PUBLIC key (dm.crypto) — a cracked client that flips is_paid still can't forge
-- the signature. The token (a Lua `return {...}` with account/products/iat/exp/sig) is
-- written by the bridge/indexer; path overridable for testing.
local PUBKEYS = (function()
	local ok, k = pcall(dofile, BASE .. "/keys/pubkeys.lua")
	return (ok and type(k) == "table") and k or {}
end)()
local ENT_PATH = os.getenv("DEMOD_ENTITLEMENTS") or (CFG_DIR .. "/entitlements.lua")
local function unhex(s)
	if type(s) ~= "string" or #s == 0 or #s % 2 ~= 0 then
		return nil
	end
	local bad = false
	local out = (
		s:gsub("..", function(h)
			local b = tonumber(h, 16)
			if not b then -- D11: reject malformed hex rather than coercing to NUL
				bad = true
				return ""
			end
			return string.char(b)
		end)
	)
	if bad then
		return nil
	end
	return out
end
-- Verify the entitlement token and populate PM.entitled (the set of unlocked paid ids).
-- Any failure (missing/expired/forged/wrong-account/wrong-device/no-crypto) → no paid entitlements.
-- v=2 tokens include device binding; v=1 tokens (no device field) accepted only when this
-- device has no DEMOD_DEVICE_ID (transition). D4: device must match. D9: account must match
-- even on unowned devices (nil account → no entitlements unlock).
local function verify_entitlements()
	PM.entitled = {}
	local pub = unhex(PUBKEYS.entitlement)
	if not (dm.crypto and dm.crypto.ed25519_verify and pub and exists(ENT_PATH)) then
		return
	end
	local ok, tok = pcall(dofile, ENT_PATH)
	if not ok or type(tok) ~= "table" or type(tok.sig) ~= "string" then
		return
	end
	local sig = unhex(tok.sig)
	-- D4: include device ID in the canonical form. v=2 tokens carry `device`;
	-- v=1 tokens omit it. Re-derive with our device ID (the backend signed with the same).
	local canon = PM.entitlement_canonical(tok.account, tok.products, tok.iat, tok.exp, tok.device)
	if not (sig and #sig == 64 and dm.crypto.ed25519_verify(pub, canon, sig)) then
		toast("Entitlement signature invalid", "err")
		return
	end
	local now = os.time()
	if tonumber(tok.exp) and now > tonumber(tok.exp) then
		toast("Entitlement expired", "warn")
		return
	end
	-- D4: device binding — v=2 tokens must match this device's ID; v=1 tokens (no device
	-- field) accepted only when we don't have a device ID yet (pre-binding transition).
	local my_device = PM.device_id
	local tok_device = tok.device or ""
	if tok_device ~= "" and my_device ~= "" and tok_device ~= my_device then
		io.stderr:write("[TERMINUS] entitlement: wrong device (token=" .. tok_device .. " me=" .. my_device .. ")\n")
		return
	end
	-- D9: account must match even on unowned devices — nil owner/account → no entitlements unlock.
	local expected = (PM.owner and PM.owner.account) or ACCOUNT or ""
	if tok.account and tostring(tok.account) ~= tostring(expected) then
		return
	end
	local n = 0
	for _, id in ipairs(tok.products or {}) do
		PM.entitled[tostring(id)] = true
		n = n + 1
	end
	io.stderr:write(string.format("[TERMINUS] entitlements: verified token, %d product(s) unlocked\n", n))
end

local function reload_patches()
	PM.load(PATCH_DIRS)
	ui_normalize_patches()
	verify_entitlements() -- re-evaluate gating whenever the patch set changes
end
PM.load_order(ORDER_PATH) -- before the first load so the sort honours the saved arrangement
PM.load_owner(OWNER_PATH)
reload_patches()

-- ── Install deep-link (signed capability; see IP_PROTECTION.md) ──────────────
-- $DEMOD_OPEN_URI carries a demod://install/<product>?exp&jti&sig set by the OS
-- x-scheme-handler. We verify it client-side with the embedded deeplink public key + expiry
-- (the actual install + anti-spam — jti replay, rate-limit — is enforced by the bridge).
local function verify_install_uri(uri)
	if type(uri) ~= "string" then
		return nil
	end
	local product = uri:match("^demod://install/([%w%-%._]+)")
	local exp = uri:match("[?&]exp=(%d+)")
	local jti = uri:match("[?&]jti=([%w%-%._]+)")
	local sig = uri:match("[?&]sig=(%x+)")
	local pub = unhex(PUBKEYS.deeplink)
	if not (product and exp and jti and sig and pub and dm.crypto and dm.crypto.ed25519_verify) then
		return nil
	end
	local rawsig = unhex(sig)
	local canon = PM.install_link_canonical(product, exp, jti)
	if not (rawsig and #rawsig == 64 and dm.crypto.ed25519_verify(pub, canon, rawsig)) then
		return nil
	end
	if os.time() > tonumber(exp) then
		return nil
	end
	return product
end
local PENDING_INSTALL = verify_install_uri(os.getenv("DEMOD_OPEN_URI"))
if os.getenv("DEMOD_OPEN_URI") then
	io.stderr:write(
		string.format(
			"[TERMINUS] open-uri → %s\n",
			PENDING_INSTALL and ("verified install: " .. PENDING_INSTALL) or "rejected (bad signature/expired)"
		)
	)
end

-- Live patch refresh: the desktop indexer (or the device hook) rewrites index.lua
-- when the marketplace installs a patch; we poll its raw content to pick it up
-- without a restart. Returns the content of the first index.lua found in PATCH_DIRS.
local function index_raw()
	for _, d in ipairs(PATCH_DIRS) do
		local f = io.open(d .. "/index.lua", "r")
		if f then
			local s = f:read("*a")
			f:close()
			return s
		end
	end
	return nil
end
local last_index_raw = index_raw()

-- ── State ────────────────────────────────────────────────────────────────
local S = {
	focus = 1,
	t = 0,
	pulse = 0,
	level = 0.35,
	boot = CFG.boot_anim and 0 or 1,
	page = (CFG.default_page == "Patches") and 2 or 1,
	pfocus = { 1, 1 }, -- 1 = channels, 2 = patches
	open = nil, -- {kind="channel"|"patch", ...} active blade
	modal = nil, -- {kind="confirm"|"bridge"|"settings"|"help", ...} overlay
	toasts = {}, -- transient feedback notifications (bottom-right)
	cards = {},
	mode = "wide",
}

-- ── Toasts (transient feedback) ──────────────────────────────────────────
-- kind: "info" | "ok" | "warn" | "err". Stacked bottom-right, fade after ~2.5s.
function toast(msg, kind)
	S.toasts[#S.toasts + 1] = { msg = tostring(msg), kind = kind or "info", t = 0 }
	if #S.toasts > 4 then
		table.remove(S.toasts, 1)
	end -- cap the stack
end

-- ── Pages ────────────────────────────────────────────────────────────────
-- Page model: page 1 = channels; pages 2.. = patch grids of PER_PAGE cards each.
-- The patch pages grow as the library grows (one new page per PER_PAGE patches),
-- so cards keep a stable size and "switch spots" as you page / reorder.
local PER_PAGE = 6
local function patch_page_count()
	return math.max(1, math.ceil(#PM.list / PER_PAGE))
end
local function total_pages()
	return 1 + patch_page_count()
end
-- global index into PM.list for slot i on the current patch page (page >= 2)
local function patch_index(i)
	return (S.page - 2) * PER_PAGE + i
end
local function page_items()
	if S.page < 2 then
		return CHANNELS
	end
	local out = {}
	local first = patch_index(1)
	for i = first, math.min(#PM.list, first + PER_PAGE - 1) do
		out[#out + 1] = PM.list[i]
	end
	return out
end

-- launch a patch "program" (reuses the channel launch machinery)
-- ── background patches (run a patch in the engine without opening DSP Studio) ──
-- The shared manifest + a thin control-socket client let Home load (or stop) an fx/synth
-- patch live in demod-rt and stay on Home; DSP Studio reflects it via the same manifest.
local LP = (function()
	local ok, m = pcall(dofile, BASE .. "/live_patches.lua")
	return (ok and type(m) == "table") and m or nil
end)()
local ENGINE = (function()
	local ok, m = pcall(dofile, BASE .. "/dsp/backend/engine_ctl.lua")
	return (ok and type(m) == "table") and m or nil
end)()
local FX_STOCK = tonumber(os.getenv("DEMOD_FX_STOCK_SLOTS") or "") or 5 -- stock chain owns slots 1..5
local FX_TOTAL = tonumber(os.getenv("DEMOD_FX_SLOTS") or "") or 12 -- patches stack into 6..TOTAL

-- set of patch ids currently running (refreshed ~1 Hz in on_update) — drives the card badge.
local LIVE_IDS = {}
local function refresh_live_ids()
	LIVE_IDS = {}
	if LP then
		for _, e in ipairs(LP.list()) do
			LIVE_IDS[tostring(e.id)] = e.slot
		end
	end
end
refresh_live_ids()

-- ── Control surface (the shared param<->MIDI bridge; see control_surface.lua) ──
-- Home has no DSP backend in-process, so param TARGETS come from the live_patches manifest
-- using the SAME canonical ids (slotN.pM) DSP Studio uses — the persisted bindings file is
-- literally shared. Writes go to the background engine over the control socket; a local
-- value shadow (authoritative-on-read from the manifest, shadow-on-write) backs get_param so
-- toggle/step/nudge and the echo guard have a coherent current value.
local CS = (function()
	local ok, m = pcall(dofile, BASE .. "/control_surface.lua")
	return (ok and type(m) == "table") and m or nil
end)()
local CS_VALUES = {} -- [slot] = { [idx0] = value }
local MOD -- modulation layer (macros); read-only in Home
if CS then
	CS.attach(function(slot, idx, value) -- set_param
		if ENGINE then
			ENGINE.set_param(slot, idx, value)
		end
		CS_VALUES[slot] = CS_VALUES[slot] or {}
		CS_VALUES[slot][idx] = value
	end, function(slot, idx) -- get_param
		local s = CS_VALUES[slot]
		return (s and s[idx]) or 0
	end)
	CS.attach_midi(midi.send)
	CS.import(CFG.param_bindings, CFG.perf_target, CFG.midi_cc_bindings, CFG.cs_out_bindings)
	SET.apply_control_surface(CS) -- enabled/mode + open the MIDI-out port
	-- modulation layer (read-only in Home: macros run, editing happens in DSP Studio)
	MOD = (function()
		local ok, m = pcall(dofile, BASE .. "/modulation.lua")
		return (ok and type(m) == "table") and m or nil
	end)()
	if MOD then
		MOD.attach(CS)
		MOD.import_macros(CFG.cs_macros, CFG.cs_macro_routes)
		MOD.import_sources(CFG.cs_mod_sources, CFG.cs_mod_routes)
		MOD.import_scenes(CFG.cs_scenes, CFG.cs_morph)
		MOD.import_perf(CFG.cs_mod_perf)
		MOD.import_seq(CFG.cs_seq)
		MOD.attach_clock(midi.clock) -- LFO tempo-sync (env-follower self-disables: no in-process meters)
	end
	midi.on_cc(function(ev)
		CS.feed("cc", ev.cc, ev.valuef, ev.ch, ev.value) -- inbound CC drives the bound param (ch=out-learn, value=rel-enc)
		if MOD then
			MOD.feed("cc", ev.cc, ev.valuef) -- a CC assigned as a macro driver sweeps the macro
			MOD.feed_morph("cc", ev.cc, ev.valuef) -- morph-driver CC crossfades scenes
		end
	end)
end
-- Re-register CS targets from the manifest + reconcile the value shadow (called ~1 Hz).
local function cs_refresh_targets()
	if not (CS and LP) then
		return
	end
	for _, e in ipairs(LP.list()) do
		local sl = tonumber(e.slot)
		if sl then
			CS_VALUES[sl] = CS_VALUES[sl] or {}
			for j, p in ipairs(e.params or {}) do
				local idx = j - 1
				CS.register_target(
					"slot" .. sl .. ".p" .. idx,
					(e.name or "patch") .. " " .. (p.label or "?"),
					sl,
					idx,
					p.min,
					p.max,
					p.step
				)
				if CS_VALUES[sl][idx] == nil then -- seed once; Home's own writes win until next reconcile
					CS_VALUES[sl][idx] = (p.value ~= nil) and p.value or p.init
				end
			end
		end
	end
end
cs_refresh_targets()

-- Load — or, if it's already running, STOP — an fx/synth patch in the background engine
-- without switching to DSP Studio. Returns true if it handled the activation (stay on Home),
-- false to fall back to the foreground DSP Studio launch. Toggling gives "turn off from Home".
local function background_load_patch(p)
	if not LP then
		return false
	end
	local live_slot = LP.slot_of(p.id)
	if live_slot then -- already running → turn it off
		if ENGINE then
			ENGINE.unload_fx(live_slot)
		end
		LP.remove(live_slot)
		refresh_live_ids()
		toast(p.name .. " stopped", "ok")
		return true
	end
	local ok, fxspec = pcall(dofile, p.fx_file)
	if not ok or type(fxspec) ~= "table" then
		return false -- bad descriptor → let the foreground path report NOT INSTALLED
	end
	-- older fx descriptors carry no explicit .so path; load the patch's own shipped .so (next to fx.lua)
	if not fxspec.path and PM and PM.patch_so then
		fxspec.path = PM.patch_so(p.fx_file)
	end
	local slot = LP.free_slot(FX_STOCK + 1, FX_TOTAL)
	if not slot then
		toast("Rack full - stop a patch or open DSP Studio", "warn")
		return true
	end
	local eng = ENGINE and ENGINE.available()
	if eng then
		ENGINE.load_fx(slot, fxspec.path or fxspec.name)
		for j, pd in ipairs(fxspec.params or {}) do
			ENGINE.set_param(slot, j - 1, pd.init)
		end
	end
	LP.add({
		slot = slot,
		id = p.id,
		name = fxspec.name or p.name,
		kind = fxspec.kind or p.type,
		path = fxspec.path,
		bypassed = false,
		params = fxspec.params,
	})
	refresh_live_ids()
	toast((p.name or "Patch") .. (eng and " running in background" or " queued (open DSP Studio)"), "ok")
	return true
end

local function launch_patch(p)
	-- cryptographic paid-patch gate: a paid patch launches only under a verified entitlement.
	-- Skipped in the Steam edition — Steam/DLC is the entitlement authority there (a DLC pack's
	-- patches are only registered when owned), so there is no Ed25519 marketplace gate.
	if not STEAM_ED and PM.is_paid(p) and not PM.is_entitled(p) then
		toast(p.name .. " - LOCKED (no entitlement)", "err")
		return
	end
	local cmd, probe
	if p.type == "fx" or p.type == "synth" then
		-- load the patch's Faust synth/fx live into the engine, via DSP Studio
		-- (DEMOD_DSP_PATCH = the patch's fx descriptor; the orchestrator dlopens its .so)
		if not p.fx_file or p.fx_file == "" then
			toast(p.name .. " - missing fx descriptor (fx_file)", "err")
			return
		end
		if p.fx_file:find("%.%.") then -- defense-in-depth: no path traversal into dofile
			toast(p.name .. " - invalid fx_file path", "err")
			return
		end
		-- default: load into the background engine and STAY on Home (activate again to stop).
		-- DEMOD_PATCH_FOREGROUND=1 forces the old behaviour (open DSP Studio with it preloaded).
		if not os.getenv("DEMOD_PATCH_FOREGROUND") and background_load_patch(p) then
			return
		end
		cmd = "DEMOD_DSP_PATCH=" .. shq(p.fx_file) .. " " .. shq(UIBIN) .. " " .. shq(DSP_ENTRY)
		probe = p.fx_file -- descriptor must exist (the .so check is device-side)
	elseif p.lua then
		cmd, probe = shq(UIBIN) .. " " .. shq(p.lua), p.probe or p.lua
	elseif p.cmd then
		cmd, probe = p.cmd, p.probe -- by contract a full shell command (packaged patch); trusted as-is
	end
	if not cmd then
		return
	end
	if probe and not exists(probe) then
		toast(p.name .. " - NOT INSTALLED", "err")
		return
	end
	S.launching = { name = p.name, accent = p.accent, t = 0 } -- launch hand-off card
	launch_now(cmd)
end

-- flip between pages (encoder long-press / tab / NAV_LEFT-RIGHT); not over a blade/modal
local function flip_page()
	if S.open or S.modal or S.moving then
		return
	end
	S.pfocus[S.page] = S.focus
	S.page = (S.page % total_pages()) + 1
	local n = #page_items()
	local f = S.pfocus[S.page] or 1
	S.focus = (n == 0) and 1 or (((f - 1) % n) + 1)
	S.cards = {} -- rebuild the card layout for the new page
end

-- ── Reorder (move mode) ──────────────────────────────────────────────────
-- The patch blade's "Reorder" action enters move mode: the focused card is
-- "held", turn/arrows carry it through slots and across pages, press saves the
-- new order (persisted), back cancels. Encoder-native so it works on the device.
local function move_to(gi) -- focus the card now at global index gi
	S.page = 2 + math.floor((gi - 1) / PER_PAGE)
	S.focus = ((gi - 1) % PER_PAGE) + 1
	S.cards = {} -- positions/page changed → rebuild layout
end
local function begin_move(gi)
	local snap = {}
	for i, p in ipairs(PM.list) do
		snap[i] = p.id
	end
	S.moving = { pos = gi, snapshot = snap }
	S.open = nil
	move_to(gi)
	toast("Move: turn to reposition, press saves, back cancels", "ok")
end
local function move_held(d)
	if not S.moving then
		return
	end
	local from = S.moving.pos
	local to = from + d
	if to < 1 or to > #PM.list then
		return -- clamp at the ends (no wrap while moving)
	end
	PM.list[from], PM.list[to] = PM.list[to], PM.list[from]
	S.moving.pos = to
	move_to(to)
end
local function commit_move()
	PM.save_order(ORDER_PATH)
	S.moving = nil
	toast("Patch order saved", "ok")
end
local function cancel_move()
	local byid = {}
	for _, p in ipairs(PM.list) do
		byid[p.id] = p
	end
	local restored = {}
	for _, id in ipairs(S.moving.snapshot) do
		if byid[id] then
			restored[#restored + 1] = byid[id]
		end
	end
	PM.list = restored
	S.moving = nil
	S.cards = {}
	toast("Move cancelled", "warn")
end

-- ── Draw helpers ─────────────────────────────────────────────────────────
local floor = math.floor
local function rect(x, y, w, h, c, a)
	dm.draw.rect(floor(x), floor(y), floor(w), floor(h), c[1], c[2], c[3], a or 255)
end
local function line(x0, y0, x1, y1, c, a)
	dm.draw.line(floor(x0), floor(y0), floor(x1), floor(y1), c[1], c[2], c[3], a or 255)
end
local function tline(x0, y0, x1, y1, th, c, a)
	dm.draw.thick_line(floor(x0), floor(y0), floor(x1), floor(y1), th, c[1], c[2], c[3], a or 255)
end
local function text(x, y, s, c, a)
	dm.draw.text(floor(x), floor(y), s, c[1], c[2], c[3], a or 255)
end
local function circle(cx, cy, r, c, a)
	if r < 1 then
		return
	end
	dm.draw.circle(floor(cx), floor(cy), floor(r), c[1], c[2], c[3], a or 255)
end
local function gradient_v(x, y, w, h, top, bot)
	dm.draw.gradient_v(floor(x), floor(y), floor(w), floor(h), top[1], top[2], top[3], bot[1], bot[2], bot[3])
end
local function lerp(a, b, k)
	return a + (b - a) * k
end
local function clamp(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end
-- Per-row fill loops (vignette, phosphor horizon, scanlines) cost scales with
-- screen area. At very high resolutions stride the loops so the software renderer
-- does ~1/step the work. Stays 1 through 1440 (so the device, 1080p, and the
-- default 1440p render cap are visually unchanged) and only strides at native
-- >=2160 (uncapped 4K) — complements the framework render-scale cap.
local function rstep(H)
	return math.max(1, math.floor(H / 1080))
end

-- ── Layout ────────────────────────────────────────────────────────────────
local COLS = 3
local function pick_mode(W, H)
	if W < 540 or H < 380 then
		return "compact"
	elseif W < 960 then
		return "standard"
	else
		return "wide"
	end
end

local function targets(W, H)
	local out = {}
	local n = #page_items()
	if n == 0 then
		return out
	end -- empty page (e.g. no patches) → handled by draw
	local cs = CFG.card_scale or 1 -- customization: card scale
	local topPad = (S.mode == "compact") and 52 or 92
	local botPad = 56
	local areaY, areaH = topPad, H - topPad - botPad
	local cyc = areaY + areaH / 2

	if S.mode == "wide" then
		-- size the grid for a full page of slots so cards stay a constant size as
		-- you page (a partial last patch page keeps the same 3x2 footprint).
		local slots = (S.page >= 2) and PER_PAGE or n
		local rows = math.ceil(slots / COLS)
		local gap = 20
		local mx = math.max(36, W * 0.06)
		local cw = (W - mx * 2 - gap * (COLS - 1)) / COLS
		local ch = math.min((areaH - gap * (rows - 1)) / rows, cw * 0.74)
		cw = cw * cs
		ch = ch * cs
		local gh = ch * rows + gap * (rows - 1)
		local oy = areaY + (areaH - gh) / 2
		for i = 1, n do
			local r = floor((i - 1) / COLS)
			local c = (i - 1) % COLS
			out[i] = {
				x = mx + c * (cw + gap) + cw / 2,
				y = oy + r * (ch + gap) + ch / 2,
				w = cw,
				h = ch,
				alpha = 1,
				scale = (i == S.focus) and 1.05 or 1.0,
			}
		end
	elseif S.mode == "standard" then
		local cw = math.min(W * 0.42, 360) * cs
		local ch = cw * 0.72
		local spread = cw * 0.74
		for i = 1, n do
			local d = i - S.focus
			local sc = math.max(0.62, 1 - math.abs(d) * 0.16)
			out[i] = {
				x = W / 2 + d * spread,
				y = cyc,
				w = cw,
				h = ch,
				alpha = math.max(0, 1 - math.abs(d) * 0.34),
				scale = sc,
			}
		end
	else
		local cw = math.min(W * 0.66, 300) * cs
		local ch = math.min(cw * 0.82, areaH * 0.86)
		local peek = W * 0.5 + cw * 0.5 - 16
		for i = 1, n do
			local d = i - S.focus
			if d == 0 then
				out[i] = { x = W / 2, y = cyc, w = cw, h = ch, alpha = 1, scale = 1 }
			elseif math.abs(d) == 1 then
				local s = (d > 0) and 1 or -1
				out[i] = { x = W / 2 + s * peek, y = cyc, w = cw, h = ch, alpha = 0.5, scale = 0.8 }
			else
				local s = (d > 0) and 1 or -1
				out[i] = { x = W / 2 + s * peek * 1.6, y = cyc, w = cw, h = ch, alpha = 0, scale = 0.7 }
			end
		end
	end
	return out
end

-- ── In-shell modals (confirm dialogs, USB-C bridge sync) ───────────────
-- Some channels act in-shell rather than launching an app: SYSTEM → Power is a
-- confirm dialog; MARKETPLACE → a USB-C bridge that streams "patches" (block
-- packs) into StreamDB (reverse-trie KV) with a clear "ready to disconnect".
local function mk_confirm(title, accent, choices, sel)
	return {
		kind = "confirm",
		title = title,
		accent = accent or COL.turq,
		choices = choices,
		sel = sel or #choices,
		t = 0,
	} -- default = last (Cancel)
end
local function mk_bridge() -- luacheck: ignore (dormant marketplace bridge-transition modal constructor; handlers live below)
	duck_anim.reset()
	return { kind = "bridge", t = 0, phase = 1, prog = 0, total = 24, done_blocks = 0, blocks = {}, emit = 0 }
end
local function mk_settings(cat)
	return { kind = "settings", cat = cat, sel = 1, adjust = false, t = 0 }
end
local function mk_text(title, accent, body)
	return {
		kind = "text",
		title = title,
		accent = accent or COL.turq,
		body = tostring(body or ""),
		t = 0,
	}
end
-- live-apply a just-changed setting (theme recolours the palette in place)
local function settings_changed(key)
	if key == "theme" then
		SET.apply_theme(COL, CFG.theme)
	elseif key and key:match("^gp_") then
		SET.apply_gamepad() -- a controller button was remapped
	elseif key and key:match("^midi") then
		SET.apply_midi(midi) -- a MIDI input setting changed (device/channel/clock/…)
	elseif key and key:match("^cs_") then
		SET.apply_control_surface(CS) -- a control-surface setting changed (enabled/mode/out device)
	end
end

-- ── Lyrics integration (demod-lyrics display + lyrics_cli control plane) ──
local LYR_STYLES = { "teleprompter", "karaoke", "static" }
local lyr_style_idx = 1

local function basename(path)
	return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function is_dls(path)
	return tostring(path or ""):lower():match("%.dls$") ~= nil
end

local function run_capture(cmd)
	local p = io.popen(cmd .. " 2>&1")
	if not p then
		return false, "unable to start command"
	end
	local out = p:read("*a") or ""
	local ok = p:close()
	out = out:gsub("%s+$", "")
	return ok == true, out
end

local function lyrics_cli_cmd(args)
	return LYR_CLI
		.. " --host "
		.. shq(LYR_HOST)
		.. " --port "
		.. tostring(LYR_PORT)
		.. " --timeout "
		.. shq(LYR_TIMEOUT)
		.. " "
		.. args
end

local function lyrics_run(args)
	return run_capture(lyrics_cli_cmd(args))
end

local function lyrics_launch_cmd()
	local L = CHANNELS[2].launch
	local args = os.getenv("DEMOD_LYRICS_ARGS")
	if args == nil then
		args = (LYR_FILE and exists(LYR_FILE)) and shq(LYR_FILE) or ""
	end
	return L.cmd .. ((args and args ~= "") and (" " .. args) or "")
end

local function short_output(out)
	out = tostring(out or ""):gsub("\n", "  ")
	if #out > 64 then
		out = out:sub(1, 61) .. "..."
	end
	return out ~= "" and out or "no response"
end

local function lyrics_status_text()
	local live = is_dls(LYR_FILE)
	local ok, out = lyrics_run(live and "live-status" or "status")
	if not ok and live then
		ok, out = lyrics_run("status")
	end
	if not ok then
		return false, "Lyrics engine is not reachable at " .. LYR_HOST .. ":" .. tostring(LYR_PORT) .. "\n\n" .. out
	end
	return true, out
end

local function lyrics_action(ch, it)
	if not it or not it.lyrics then
		return false
	end
	local act = it.lyrics
	if act == "launch" then
		local L = ch.launch
		if L.probe and not exists(L.probe) then
			S.open.not_installed = true
			S.open.not_installed_msg = "LYRICS — display not installed"
			return true
		end
		S.launching = { name = ch.name, accent = ch.accent, t = 0 }
		launch_now(lyrics_launch_cmd())
		return true
	end

	if act == "load" then
		if not (LYR_FILE and exists(LYR_FILE)) then
			toast("Lyrics file not found", "err")
			return true
		end
		local cmd = is_dls(LYR_FILE) and ("live-load " .. shq(LYR_FILE)) or ("load " .. shq(LYR_FILE))
		local ok, out = lyrics_run(cmd)
		toast(ok and ("Loaded " .. basename(LYR_FILE)) or short_output(out), ok and "ok" or "err")
		return true
	end

	if act == "toggle" then
		local live = is_dls(LYR_FILE)
		local ok, out = lyrics_run(live and "live-status" or "status")
		local playing = ok and out:match("state=1") ~= nil
		local cmd = live and (playing and "live-pause" or "live-play") or (playing and "pause" or "play")
		ok, out = lyrics_run(cmd)
		toast(ok and (playing and "Lyrics paused" or "Lyrics playing") or short_output(out), ok and "ok" or "err")
		return true
	end

	if act == "next" then
		if not is_dls(LYR_FILE) then
			toast("Next Section needs a .dls score", "warn")
			return true
		end
		local ok, out = lyrics_run("next bar")
		toast(ok and "Next section queued" or short_output(out), ok and "ok" or "err")
		return true
	end

	if act == "tap" then
		if not is_dls(LYR_FILE) then
			toast("Tap Tempo needs a .dls score", "warn")
			return true
		end
		local ok, out = lyrics_run("tap")
		toast(ok and "Tap registered" or short_output(out), ok and "ok" or "err")
		return true
	end

	if act == "sections" then
		local ok, out = lyrics_run("sections")
		S.modal = mk_text("LYRICS SETLIST", ch.accent, ok and out or ("Cannot read sections\n\n" .. out))
		return true
	end

	if act == "status" then
		local ok, out = lyrics_status_text()
		S.modal = mk_text("LYRICS STATUS", ch.accent, ok and out or out)
		return true
	end

	if act == "style" then
		lyr_style_idx = (lyr_style_idx % #LYR_STYLES) + 1
		local mode = LYR_STYLES[lyr_style_idx]
		local ok, out = lyrics_run("mode " .. mode)
		toast(ok and ("Display style: " .. mode) or short_output(out), ok and "ok" or "err")
		return true
	end

	return false
end

-- launch_quit: end the console session (supervisor loop exits on "__quit__").
local function launch_quit()
	if LAUNCH_FILE then
		local f = io.open(LAUNCH_FILE, "w")
		if f then
			f:write("__quit__")
			f:close()
		end
	end
	if dm.quit then
		dm.quit()
	end
end

-- confirm a Power / dialog choice: run its command, quit, or just dismiss
local function modal_confirm()
	local c = S.modal.choices[S.modal.sel]
	S.modal = nil
	if not c then
		return
	end
	if c.quit then
		launch_quit()
	elseif c.fn then
		c.fn()
	elseif c.cmd and dm.exec then
		dm.exec(c.cmd)
	end
end

-- adopt flow: register this guitar to `account`. Adopting under a NEW account
-- wipes all paid patches (free stay) — paid licenses don't transfer with hardware.
local function adopt_modal(account)
	if not account or account == "" then
		toast("No account - sync via Marketplace", "warn")
		return
	end
	local plan = PM.adopt_plan(account)
	if plan.mode == "same" then
		toast("Owned by " .. account, "ok")
		return
	end
	local function commit()
		local r = PM.do_adopt(account, OWNER_PATH, patch_remove_hook, account, os.date("%Y-%m-%d"))
		PM.load_owner(OWNER_PATH)
		ui_normalize_patches()
		local n = #PM.list
		if S.focus > n then
			S.focus = math.max(1, n)
		end
		toast("Adopted by " .. account, "ok")
		if r.wiped > 0 then
			toast("Wiped " .. r.wiped .. " paid patches", "warn")
		end
	end
	if plan.mode == "adopt" then
		S.modal = mk_confirm("ADOPT GUITAR  -" .. account, COL.turq, {
			{ label = "ADOPT", fn = commit },
			{ label = "NOT NOW" },
		}, 1)
	else -- transfer (different owner): destructive → default to Cancel
		S.modal = mk_confirm("TRANSFER  -wipes " .. #plan.paid_to_wipe .. " paid patches", COL.red, {
			{ label = "ADOPT & WIPE", fn = commit },
			{ label = "CANCEL" },
		}, 2)
	end
end

-- ── Onboarding + help (a controls cheat-sheet; first-run is a 3-card intro) ─
local HELP_PAGES = {
	{
		title = "NAVIGATE",
		lines = {
			"Turn / Arrows .... move focus",
			"Press / Enter .... open . select",
			"Back / Esc ....... go back",
		},
	},
	{
		title = "PAGES & APPS",
		lines = {
			"L / R . Tab ...... flip pages",
			"Page 1 ........... system channels",
			"Page 2 ........... installed patches",
			"Footswitch ....... toggle FX (DSP)",
		},
	},
	{
		title = "GET PATCHES",
		lines = {
			"Marketplace ...... sync over USB-C",
			"System > Ownership  adopt this guitar",
			"Paid patches tie to your account.",
		},
	},
}
local function mk_help(onboarding)
	return { kind = "help", onboarding = onboarding, page = 1, t = 0 }
end
local function onboarding()
	S.modal = mk_help(true)
end
local function finish_onboarding()
	S.modal = nil
	CFG.seen_intro = true
	SET.save(CFG_PATH)
	if ACCOUNT and PM.adopt_plan(ACCOUNT).mode ~= "same" then
		adopt_modal(ACCOUNT)
	end -- chain to adopt
end

-- open the in-shell view for an interactive channel item; returns true if handled
local function open_inshell(ch, it)
	if ch.id == "lyrics" and it then
		return lyrics_action(ch, it)
	elseif ch.id == "settings" and it then
		if it.label == "Ownership" then
			adopt_modal(ACCOUNT)
			return true
		end
		if it.label == "Help" then
			S.modal = mk_help(false)
			return true
		end
		if it.label == "Power" then
			S.modal = mk_confirm("POWER  -confirm", ch.accent, {
				{ label = "RESTART", cmd = os.getenv("DEMOD_REBOOT") or "systemctl reboot" },
				{ label = "SHUT DOWN", cmd = os.getenv("DEMOD_POWEROFF") or "systemctl poweroff" },
				{ label = "EXIT TO SHELL", quit = true },
				{ label = "CANCEL" },
			}, 4)
			return true
		end
		local ci = SET.cat_index(it.label) -- Appearance / Layout / Input / System
		if ci then
			if it.label == "MIDI" then
				SET.midi_refresh_devices(midi) -- repopulate device list on open (hotplug)
			end
			S.modal = mk_settings(ci)
			return true
		end
	elseif ch.id == "market" then
		if STEAM_ED then
			-- Steam edition: the Workshop popup IS the Steam overlay (no off-Steam marketplace).
			-- Each item opens its own app-scoped Workshop page. (it.wk = browse|subs|info)
			local wk = (it and it.wk) or "browse"
			STEAM.overlay_workshop(wk)
			local what = (wk == "subs" and "your Workshop subscriptions")
				or (wk == "info" and "Workshop help")
				or "the Steam Workshop"
			toast("Opening " .. what, "ok")
			return true
		end
		if MARKET and dm.exec then
			dm.exec(MARKET)
			toast("Opening Marketplace companion", "ok")
		else
			-- honest "coming soon" state (no companion connected)
			S.open.not_installed = true
			S.open.not_installed_msg = "MARKETPLACE — companion not connected"
		end
		return true
	elseif ch.id == "hardware" then
		-- advertise the physical instrument: open the DeMoD store in the Steam overlay
		-- (hardware is a separate product → SSA-legal to link out).
		STEAM.overlay_url(os.getenv("DEMOD_HARDWARE_URL") or "https://demod.ltd")
		toast("Opening the DeMoD store", "ok")
		return true
	elseif ch.id == "packs" then
		-- DLC bundle: if owned its patches are already installed; if locked, open the Steam
		-- store page (overlay) to buy. dm.steam.dlc_owned no-ops to locked until the SDK lands.
		local pk = it and it.pack
		if pk and pk.dlc_appid and STEAM.dlc_owned(pk.dlc_appid) then
			toast((pk.name or "Pack") .. " - owned (installed)", "ok")
		else
			-- Open THIS DLC's store page in the overlay (app-scoped once real ids land;
			-- a placeholder dlc_appid degrades to the generic store front).
			STEAM.overlay_store(pk and pk.dlc_appid)
			toast("Opening Steam store - " .. (pk and pk.name or "DLC"), "ok")
		end
		return true
	end
	return false
end

-- ── Blade helpers (channels and patches share the right-side blade) ──────
local function blade_subject()
	if not S.open then
		return nil
	end
	if S.open.kind == "patch" then
		return PM.list[S.open.pidx]
	end
	return CHANNELS[S.open.idx]
end
local function patch_actions(p)
	local locked = PM.is_paid(p) and not PM.is_entitled(p)
	return {
		{
			label = locked and "Launch (LOCKED)" or "Launch",
			meta = locked and "no entitlement" or ((p.type == "app" and "program") or "into engine"),
			act = "launch",
		},
		{ label = "Reorder", meta = "move card", act = "reorder" },
		{ label = "Uninstall", meta = PM.is_paid(p) and "paid" or "free", act = "uninstall" },
	}
end
local function blade_items()
	if not S.open then
		return {}
	end
	if S.open.kind == "patch" then
		local p = PM.list[S.open.pidx]
		return p and patch_actions(p) or {}
	end
	return CHANNELS[S.open.idx].items
end
-- where the blade's item/action list starts (patches have a metadata panel above)
local function blade_list_geom(W, H)
	local px, py, pw = blade_geom(W, H)
	local listY = (S.open and S.open.kind == "patch") and (py + 210) or (py + 96)
	return px, py, pw, listY, 44
end
local function open_uninstall(p)
	S.modal = mk_confirm("UNINSTALL  -" .. (p.name or "patch"), COL.red, {
		{
			label = "UNINSTALL",
			fn = function()
				local hooked = false
				PM.uninstall(p.id, function(id)
					hooked = patch_remove_hook(id)
				end)
				S.open = nil
				local n = #PM.list
				if S.focus > n then
					S.focus = math.max(1, n)
				end
				toast(
					hooked and ((p.name or "patch") .. " uninstalled (verify on device)")
						or ((p.name or "patch") .. " removed (no device hook)"),
					hooked and "ok" or "warn"
				)
			end,
		},
		{ label = "CANCEL" },
	}, 2)
end

-- ── Navigation — single funnel ─────────────────────────────────────────
function set_focus(i)
	if S.modal then
		if S.modal.kind == "confirm" then
			local n = #S.modal.choices
			S.modal.sel = ((i - 1) % n) + 1
		elseif S.modal.kind == "settings" then
			local n = #SET.categories[S.modal.cat].rows
			S.modal.sel = ((i - 1) % n) + 1
		end
	elseif S.open then
		local n = #blade_items()
		if n < 1 then
			n = 1
		end
		S.open.sub = ((i - 1) % n) + 1
	else
		local n = #page_items()
		if n == 0 then
			S.focus = 1
		elseif CFG.wrap then
			S.focus = ((i - 1) % n) + 1
		else
			S.focus = (i < 1 and 1) or (i > n and n) or i
		end -- clamp when wrap off
	end
end
function move_focus(d)
	if S.moving then
		move_held(d)
		return
	end
	if S.modal then
		if S.modal.kind == "confirm" then
			set_focus(S.modal.sel + d)
		elseif S.modal.kind == "settings" then
			if S.modal.adjust then
				local row = SET.categories[S.modal.cat].rows[S.modal.sel]
				settings_changed(SET.act(row, d)) -- live-edit the focused value
			else
				set_focus(S.modal.sel + d)
			end
		elseif S.modal.kind == "help" and S.modal.onboarding then
			S.modal.page = math.max(1, math.min(#HELP_PAGES, S.modal.page + d))
		end
	elseif S.open then
		set_focus(S.open.sub + d)
	else
		set_focus(S.focus + d)
	end
end
function activate()
	if S.moving then
		commit_move()
		return
	end
	if S.modal then
		if S.modal.kind == "confirm" then
			modal_confirm()
		elseif S.modal.kind == "bridge" and S.modal.phase >= 4 then
			S.modal = nil
			reload_patches()
			toast("Synced - " .. #PM.list .. " patches", "ok")
		elseif S.modal.kind == "settings" then
			local row = SET.categories[S.modal.cat].rows[S.modal.sel]
			if row.type == "toggle" then
				settings_changed(SET.act(row, 1))
			elseif row.type == "action" then
				SET.act(row, 1)
				SET.apply_theme(COL, CFG.theme) -- e.g. Reset re-themes
			elseif row.type == "choice" or row.type == "slider" then
				S.modal.adjust = not S.modal.adjust
			end
		elseif S.modal.kind == "help" then
			if S.modal.onboarding then
				if S.modal.page < #HELP_PAGES then
					S.modal.page = S.modal.page + 1
				else
					finish_onboarding()
				end
			else
				S.modal = nil
			end
		elseif S.modal.kind == "text" then
			S.modal = nil
		end
		return
	end
	if not S.open then
		if S.page >= 2 then -- patch page: open the patch detail blade
			local gi = patch_index(S.focus)
			if PM.list[gi] then
				S.open = { kind = "patch", pidx = gi, t = 0, sub = 1, opening = true }
			end
			return
		end
		S.open = { kind = "channel", idx = S.focus, t = 0, sub = 1, opening = true }
		return
	end
	-- activating a blade item: flash, then act
	S.open.flash = 1
	if S.open.kind == "patch" then -- patch blade: Launch / Uninstall
		local p = PM.list[S.open.pidx]
		local act = p and patch_actions(p)[S.open.sub]
		if not act then
			return
		end
		if act.act == "launch" then
			launch_patch(p)
		elseif act.act == "reorder" then
			begin_move(S.open.pidx)
		elseif act.act == "uninstall" then
			open_uninstall(p)
		end
		return
	end
	local ch = CHANNELS[S.open.idx]
	local it = ch.items[S.open.sub]
	if open_inshell(ch, it) then
		return
	end -- SYSTEM Power / MARKETPLACE bridge
	local L = ch.launch
	if not L then
		return
	end -- decorative item (no target yet)
	if L.probe and not exists(L.probe) then -- target missing → honest persistent state
		S.open.not_installed = true
		S.open.not_installed_msg = ch.name .. " — NOT INSTALLED"
		return
	end
	local cmd = L.cmd
	if it and it.screen then
		cmd = "DEMOD_DSP_SCREEN=" .. it.screen .. " " .. cmd
	end
	if it and it.sysstep then
		cmd = "DEMOD_SYS_STEP=" .. it.sysstep .. " " .. cmd
	end
	if it and it.lesson then
		cmd = "DEMOD_LEARN_LESSON=" .. it.lesson .. " " .. cmd
	end
	S.launching = { name = ch.name, accent = ch.accent, t = 0 } -- launch hand-off card
	launch_now(cmd)
end
function back()
	if S.moving then
		cancel_move()
		return
	end
	if S.modal then
		if S.modal.kind == "settings" then
			if S.modal.adjust then
				S.modal.adjust = false
				return
			end -- exit value edit first
			SET.save(CFG_PATH)
			S.modal = nil
			return -- persist on close
		end
		if S.modal.kind == "help" then
			if S.modal.onboarding then
				finish_onboarding()
			else
				S.modal = nil
			end
			return
		end
		local wasbridge = (S.modal.kind == "bridge")
		S.modal = nil
		if wasbridge then -- pick up patches synced this session
			reload_patches()
			toast("Synced - " .. #PM.list .. " patches", "ok")
			if #PM.errors > 0 then
				toast(#PM.errors .. " index errors", "warn")
			end
		end
	elseif S.open then
		S.open = nil
	end
end

-- ── Input funnel ───────────────────────────────────────────────────────
-- Every source — keyboard, USB serial encoder, Arduino, dm.nav() — arrives
-- here as one of four semantic actions. One focus field, every input.
function on_nav(action)
	if CFG.invert_enc then -- customization: invert encoder
		if action == "next" then
			action = "prev"
		elseif action == "prev" then
			action = "next"
		end
	end
	if action == "next" then
		move_focus(1)
	elseif action == "prev" then
		move_focus(-1)
	elseif action == "activate" then
		activate()
	elseif action == "back" then
		back()
	elseif action == "page" or action == "tab" or action == "tab_prev" then
		flip_page()
	elseif action == "cs_toggle" then -- a controller button mapped to "Control Surface"
		if CS then
			local on = CS.toggle_enabled()
			CFG.cs_enabled = on
			SET.save(CFG_PATH)
			toast("Control Surface " .. (on and "ON" or "OFF"), on and "ok" or "info")
		end
	elseif action == "param_up" and MOD and MOD.perf() then
		MOD.perf_apply(1) -- gamepad sweeps the macro/morph perf focus from Home too
	elseif action == "param_down" and MOD and MOD.perf() then
		MOD.perf_apply(-1)
	elseif action == "param_toggle" and MOD and MOD.perf() then
		MOD.perf_toggle()
	end
	dm.redraw()
end

-- demod5 hardware (i2c buttons + AS5600 encoder) → on_input. Without this the
-- home shell never received input on the actual board (only on_nav reaches it
-- from keyboard / serial encoder). NAV_LEFT/RIGHT flip pages.
function on_input(evt, btn, val)
	local fwd = CFG.invert_enc and -1 or 1 -- customization: invert encoder
	if evt == "ENC_CW" or evt == "ENC_ACCEL_CW" then
		move_focus(fwd)
	elseif evt == "ENC_CCW" or evt == "ENC_ACCEL_CCW" then
		move_focus(-fwd)
	elseif evt == "DOWN" then
		if btn == "NAV_RIGHT" or btn == "NAV_LEFT" then
			flip_page()
		elseif btn == "NAV_DOWN" then
			move_focus(1)
		elseif btn == "NAV_UP" then
			move_focus(-1)
		elseif btn == "NAV_SELECT" or btn == "ENC_PUSH" then
			activate()
		elseif btn == "NAV_BACK" then
			back()
		end
	end
	dm.redraw()
end

-- ── Hit buttons ────────────────────────────────────────────────────────
-- One pool, sized for the largest page (channels = 6; patches up to MAX_CARDS).
local hit = {}
local sub_hit = {}
local MAX_SUB = 8 -- System blade has 7 items (incl. Help); headroom
local MAX_CARDS = 12
local root = dm.root()
for i = 1, MAX_CARDS do
	local b = dm.button("hit" .. i, "")
	b:set_bg(0, 0, 0, 0)
	b:set_bounds(-200, -200, 1, 1)
	b:on_click(function()
		set_focus(i)
		activate()
	end)
	root:add_child(b)
	hit[i] = b
end
for i = 1, MAX_SUB do
	local b = dm.button("sub" .. i, "")
	b:set_bg(0, 0, 0, 0)
	b:set_bounds(-200, -200, 1, 1)
	b:on_click(function()
		if S.open then
			S.open.sub = i
			activate()
		end
	end)
	root:add_child(b)
	sub_hit[i] = b
end
local back_btn = dm.button("backbtn", "")
back_btn:set_bg(0, 0, 0, 0)
back_btn:set_bounds(-200, -200, 1, 1)
back_btn:on_click(function()
	back()
end)
root:add_child(back_btn)

-- modal hit buttons (confirm choices; settings rows; bridge press-to-close)
local MAX_MODAL = 8
local modal_hit = {}
for i = 1, MAX_MODAL do
	local b = dm.button("modal" .. i, "")
	b:set_bg(0, 0, 0, 0)
	b:set_bounds(-200, -200, 1, 1)
	b:on_click(function()
		if not S.modal then
			return
		end
		if S.modal.kind == "confirm" then
			S.modal.sel = i
			activate()
		elseif S.modal.kind == "bridge" or S.modal.kind == "help" or S.modal.kind == "text" then
			activate()
		elseif S.modal.kind == "settings" then
			S.modal.sel = i
			local row = SET.categories[S.modal.cat].rows[i]
			if row then -- click = cycle/toggle/step/run
				if row.type == "action" then
					SET.act(row, 1)
					SET.apply_theme(COL, CFG.theme)
				elseif row.type ~= "info" then
					settings_changed(SET.act(row, 1))
				end
			end
		end
	end)
	root:add_child(b)
	modal_hit[i] = b
end

-- ── Modal geometry (shared by update hit-testing + draw) ───────────────
local function confirm_geom(W, H)
	local m = S.modal
	local n = #m.choices
	local titleH, rowH, pad = 56, 40, 18
	local bw = math.min(W * 0.7, 380)
	local bh = titleH + n * rowH + pad
	return W / 2 - bw / 2, H / 2 - bh / 2, bw, bh, rowH, titleH, pad
end
local function settings_geom(W, H)
	local n = #SET.categories[S.modal.cat].rows
	local titleH, rowH, pad = 52, 36, 18
	local bw = math.min(W * 0.82, 460)
	local bh = titleH + n * rowH + pad
	return W / 2 - bw / 2, H / 2 - bh / 2, bw, bh, rowH, titleH, pad
end

-- ── Update ────────────────────────────────────────────────────────────
function on_update(dt)
	if dt > 0.05 then
		dt = 0.05
	end
	midi.update(dt) -- drive the MIDI subsystem (clock timing + hotplug reconnect)
	if MOD then
		MOD.update(dt) -- run persisted LFO/macro modulation in the background shell
	end
	if STEAM_ED then
		STEAM.run_callbacks() -- pump Steamworks events (DLC/overlay); no-op without the SDK
	end
	local W, H = dm.width(), dm.height()
	S.mode = pick_mode(W, H)
	S.t = S.t + dt
	S.pulse = S.pulse + dt
	S.boot = math.min(1, S.boot + dt / 1.6)
	local tgtLevel = 0.3 + 0.25 * math.sin(S.t * 1.7) + 0.15 * math.sin(S.t * 4.3)
	S.level = S.level + (tgtLevel - S.level) * 0.08

	-- poll the take recorder (~2 Hz) for the REC badge
	if REC then
		S._rec = S._rec or { on = false, elapsed = 0, t = 0 }
		S._rec.t = S._rec.t + dt
		if S._rec.t > 0.5 then
			S._rec.t = 0
			local rs = REC.status()
			S._rec.on = rs.recording
			S._rec.elapsed = rs.elapsed or 0
		end
	end

	-- refresh the live-patch set (~1 Hz) so card LIVE badges track background loads/stops
	S._live_t = (S._live_t or 0) + dt
	if S._live_t > 1.0 then
		S._live_t = 0
		refresh_live_ids()
		cs_refresh_targets() -- keep control-surface targets/shadow in sync with the live rack
	end

	if S.open then
		S.open.t = math.min(1, S.open.t + dt / 0.4)
		if S.open.opening and S.open.t >= 1 then
			S.open.opening = false
		end
		if S.open.flash then
			S.open.flash = S.open.flash - dt * 3
			if S.open.flash <= 0 then
				S.open.flash = nil
			end
		end
	end

	-- launch hand-off card fades after ~1.5s (all other feedback uses toasts)
	if S.launching then
		S.launching.t = S.launching.t + dt
		if S.launching.t > 1.5 then
			S.launching = nil
		end
	end

	-- toasts: advance + expire
	for i = #S.toasts, 1, -1 do
		local tt = S.toasts[i]
		tt.t = tt.t + dt
		if tt.t > 2.5 then
			table.remove(S.toasts, i)
		end
	end

	-- live realtime status from the orchestrator param bus (throttled; -- if absent)
	S._rt_t = (S._rt_t or 0) + dt
	if S._rt_t > 0.5 then
		S._rt_t = 0
		local p = dm.params_read and dm.params_read()
		S.rt = p and { present = true, pitch = p.pitch_hz, bpm = p.bpm } or { present = false }
	end

	-- live patch refresh: reload when the installer rewrites the patch index
	S._idx_t = (S._idx_t or 0) + dt
	if S._idx_t > 1.5 and not S.moving then -- defer the live refresh while reordering
		S._idx_t = 0
		local cur = index_raw()
		if cur ~= last_index_raw then
			last_index_raw = cur
			reload_patches()
			local n = #PM.list
			if S.page >= 2 then
				-- a shrunken library may drop pages; clamp the page, then focus-in-page
				if S.page > total_pages() then
					S.page = total_pages()
				end
				local pn = #page_items()
				S.focus = (pn == 0) and 1 or math.min(S.focus, pn)
			end
			toast("Patches updated - " .. n, "ok")
		end
	end

	-- first-boot flow (once, after boot): onboarding → adopt prompt; report index errors
	if S.boot >= 1 and not S._first_done and not S.modal and not S.open then
		S._first_done = true
		if not INTEG.ok then
			toast("INTEGRITY: build modified - " .. (INTEG.problems and INTEG.problems[1] or "verify failed"), "err")
		end
		if #PM.errors > 0 then
			toast(#PM.errors .. " patch index errors", "warn")
		end
		-- verified install deep-link: jump to the patch if installed, else point at the Marketplace
		if PENDING_INSTALL then
			local gi
			for i, p in ipairs(PM.list) do
				if p.id == PENDING_INSTALL then
					gi = i
					break
				end
			end
			if gi then
				move_to(gi)
				toast("Install link: " .. PENDING_INSTALL, "ok")
			else
				toast("Install " .. PENDING_INSTALL .. " - open Marketplace", "ok")
				if MARKET and dm.exec then
					dm.exec(MARKET)
				end
			end
			PENDING_INSTALL = nil
		end
		if not CFG.seen_intro then
			onboarding()
		elseif ACCOUNT and PM.adopt_plan(ACCOUNT).mode ~= "same" then
			adopt_modal(ACCOUNT)
		end
	end

	-- bridge sync animation: connect → handshake → stream patch blocks → ready
	if S.modal then
		local m = S.modal
		m.t = (m.t or 0) + dt
		if m.kind == "bridge" then
			if m.phase == 1 and m.t > 0.9 then
				m.phase = 2
			end
			if m.phase == 2 and m.t > 1.8 then
				m.phase = 3
			end
			if m.phase == 3 then
				m.prog = math.min(1, m.prog + dt * 0.34)
				m.done_blocks = floor(m.prog * m.total)
				duck_anim.update(dt, nil)
				if m.prog >= 1 then
					m.phase = 4
					m.t = 0
				end
			end
		end
	end

	local np = #page_items() -- cards on the active page

	-- hover -> focus (home cards) — suspended while reordering (focus tracks the held card)
	if S.boot >= 1 and not S.open and not S.modal and not S.moving and CFG.hover_focus then
		local mx, my = dm.mouse_x(), dm.mouse_y()
		for i = 1, np do
			local c = S.cards[i]
			if
				c
				and c.alpha > 0.5
				and math.abs(mx - c.x) < c.w * c.scale / 2
				and math.abs(my - c.y) < c.h * c.scale / 2
			then
				set_focus(i)
				break
			end
		end
	end

	-- lerp cards
	local tg = targets(W, H)
	local k = 1 - 0.0015 ^ dt
	for i = 1, np do
		local a = S.cards[i]
		if not a then
			a = {}
			for key, v in pairs(tg[i]) do
				a[key] = v
			end
			S.cards[i] = a
		end
		local b = tg[i]
		a.x = lerp(a.x, b.x, k)
		a.y = lerp(a.y, b.y, k)
		a.w = lerp(a.w, b.w, k)
		a.h = lerp(a.h, b.h, k)
		a.alpha = lerp(a.alpha, b.alpha, k)
		a.scale = lerp(a.scale, b.scale, k)
	end

	-- place home hit buttons (parked beyond the active page's card count)
	for i = 1, MAX_CARDS do
		local c = S.cards[i]
		if (not S.open) and not S.moving and i <= np and c and c.alpha > 0.5 then
			local w, h = c.w * c.scale, c.h * c.scale
			hit[i]:set_bounds(floor(c.x - w / 2), floor(c.y - h / 2), floor(w), floor(h))
		else
			hit[i]:set_bounds(-200, -200, 1, 1)
		end
	end

	-- place sub-menu hit buttons + back (parked while a modal is up)
	if S.open and not S.open.opening and not S.modal then
		local items = blade_items()
		local px, _, pw, listY, rowH = blade_list_geom(W, H)
		for i = 1, MAX_SUB do
			if items[i] then
				sub_hit[i]:set_bounds(floor(px + 20), floor(listY + (i - 1) * rowH), floor(pw - 40), rowH - 6)
			else
				sub_hit[i]:set_bounds(-200, -200, 1, 1)
			end
		end
		back_btn:set_bounds(0, 0, floor(px), H) -- click left of blade = back
	else
		for i = 1, MAX_SUB do
			sub_hit[i]:set_bounds(-200, -200, 1, 1)
		end
		back_btn:set_bounds(-200, -200, 1, 1)
	end

	-- place modal hit buttons (confirm choices / bridge press-to-close)
	if S.modal and S.modal.kind == "confirm" then
		local bx, by, bw, _, rowH, titleH, pad = confirm_geom(W, H)
		for i = 1, MAX_MODAL do
			if S.modal.choices[i] then
				modal_hit[i]:set_bounds(
					floor(bx + pad),
					floor(by + titleH + (i - 1) * rowH),
					floor(bw - 2 * pad),
					floor(rowH - 6)
				)
			else
				modal_hit[i]:set_bounds(-200, -200, 1, 1)
			end
		end
	elseif S.modal and S.modal.kind == "settings" then
		local rows = SET.categories[S.modal.cat].rows
		local bx, by, bw, _, rowH, titleH, pad = settings_geom(W, H)
		for i = 1, MAX_MODAL do
			if rows[i] then
				modal_hit[i]:set_bounds(
					floor(bx + pad),
					floor(by + titleH + (i - 1) * rowH),
					floor(bw - 2 * pad),
					floor(rowH - 6)
				)
			else
				modal_hit[i]:set_bounds(-200, -200, 1, 1)
			end
		end
	elseif
		S.modal
		and ((S.modal.kind == "bridge" and S.modal.phase >= 4) or S.modal.kind == "help" or S.modal.kind == "text")
	then
		modal_hit[1]:set_bounds(0, floor(H * 0.5), W, floor(H * 0.5)) -- press lower half to advance/close
		for i = 2, MAX_MODAL do
			modal_hit[i]:set_bounds(-200, -200, 1, 1)
		end
	else
		for i = 1, MAX_MODAL do
			modal_hit[i]:set_bounds(-200, -200, 1, 1)
		end
	end

	-- sub hover -> focus
	if S.open and not S.open.opening then
		local mx, my = dm.mouse_x(), dm.mouse_y()
		local items = blade_items()
		local px, _, pw, listY, rowH = blade_list_geom(W, H)
		for i = 1, #items do
			if mx > px + 20 and mx < px + pw - 20 and my > listY + (i - 1) * rowH and my < listY + i * rowH then
				S.open.sub = i
				break
			end
		end
	end

	dm.redraw()
end

-- ── Blade geometry (right-side detail panel) ───────────────────────────
function blade_geom(W, H)
	local pw = math.min(W * 0.46, 460)
	local px = W - pw
	local py = 0
	return px, py, pw
end

-- ── Background ──────────────────────────────────────────────────────────
local function draw_background(W, H)
	rect(0, 0, W, H, COL.bg)
	-- faint Sierpinski lattice
	local s = math.min(W, H) * 0.9
	dm.draw.sierpinski(
		floor(W / 2),
		floor(H * 0.1),
		floor(W / 2 - s / 2),
		floor(H * 0.9),
		floor(W / 2 + s / 2),
		floor(H * 0.9),
		3,
		{ 0, 0, 0, 0 },
		{ COL.turq[1], COL.turq[2], COL.turq[3], 8 }
	)
	-- reactive phosphor horizon — a soft oscilloscope baseline glow across centre
	-- (intensity = the Background Pulse setting × live engine level). No hard orb.
	if CFG.pulse > 0 then
		local cy = floor(H * 0.52)
		local lvl = CFG.reduce_motion and 0.5 or (0.5 + 0.5 * S.level)
		local spread = floor(8 + 30 * CFG.pulse)
		local st = rstep(H)
		for j = -spread, spread, st do
			local f = 1 - math.abs(j) / spread
			local a = floor(15 * f * f * CFG.pulse * (0.7 + 0.6 * lvl))
			if a > 0 then
				line(0, cy + j, W, cy + j, COL.turq, a)
			end
		end
	end
	-- travelling scanline band (settings: scanlines + reduce-motion)
	if CFG.scanlines and not CFG.reduce_motion then
		local band = (S.t * 60) % (H + 80) - 40
		for j = 0, 6 do
			line(0, band + j, W, band + j, COL.turq, floor(8 * (1 - j / 6)))
		end
	end

	-- vignette — darken top/bottom edges for depth
	if CFG.vignette then
		local vh = math.floor(H * 0.18)
		local st = rstep(H)
		for j = 0, vh, st do
			local a = floor(60 * (1 - j / vh))
			line(0, j, W, j, COL.bg, a)
			line(0, H - j, W, H - j, COL.bg, a)
		end
	end

	-- console corner brackets — a quiet oscilloscope frame around the whole screen
	local m, cl = 12, 18
	tline(m, m, m + cl, m, 2, COL.turq, 45)
	tline(m, m, m, m + cl, 2, COL.turq, 45)
	tline(W - m, m, W - m - cl, m, 2, COL.turq, 45)
	tline(W - m, m, W - m, m + cl, 2, COL.turq, 45)
	tline(m, H - m, m + cl, H - m, 2, COL.turq, 45)
	tline(m, H - m, m, H - m - cl, 2, COL.turq, 45)
	tline(W - m, H - m, W - m - cl, H - m, 2, COL.turq, 45)
	tline(W - m, H - m, W - m, H - m - cl, 2, COL.turq, 45)
end

-- ── Mini previews ───────────────────────────────────────────────────────
local function draw_preview(ch, sx, sy, a, t)
	if ch.preview == "dsp" then
		for k = 0, 3 do
			local h = 4 + math.abs(math.sin(t * 3 + k)) * 8
			rect(sx + k * 5, sy - h, 3, h, ch.accent, a)
		end
	elseif ch.preview == "lyrics" then
		for k = 0, 2 do
			line(sx, sy + k * 4, sx + 18 - k * 3, sy + k * 4, COL.violet, floor(a * (1 - k * 0.3)))
		end
	elseif ch.preview == "ferro" then
		circle(sx + 8, sy, 3 + math.sin(t * 4) * 2, COL.green, a)
		circle(sx + 8, sy, 7, COL.green, floor(a * 0.4))
	elseif ch.preview == "market" then
		rect(sx, sy - 6, 16, 12, COL.yellow, floor(a * 0.5))
	elseif ch.preview == "systems" then
		dm.draw.sierpinski(
			floor(sx),
			floor(sy - 8),
			floor(sx - 7),
			floor(sy + 6),
			floor(sx + 7),
			floor(sy + 6),
			2,
			{ 0, 0, 0, 0 },
			{ ch.accent[1], ch.accent[2], ch.accent[3], a }
		)
	elseif ch.preview == "learn" then
		-- a rising scale: ascending bars (notes climbing) = learning music
		for k = 0, 4 do
			local h = 3 + k * 2
			rect(sx + k * 4, sy + 6 - h, 3, h, ch.accent, floor(a * (0.5 + k * 0.12)))
		end
	elseif ch.preview == "settings" then
		circle(sx + 8, sy, 6, COL.red, floor(a * 0.6))
		circle(sx + 8, sy, 2, COL.red, a)
	elseif ch.preview == "program" then
		-- a framed app glyph with an inner Sierpinski (a patch = packaged code)
		rect(sx, sy - 7, 16, 14, ch.accent, floor(a * 0.22))
		dm.draw.sierpinski(
			floor(sx + 8),
			floor(sy - 6),
			floor(sx + 1),
			floor(sy + 6),
			floor(sx + 15),
			floor(sy + 6),
			2,
			{ 0, 0, 0, 0 },
			{ ch.accent[1], ch.accent[2], ch.accent[3], a }
		)
	elseif ch.preview == "fx" then
		-- a live waveform glyph (synth/fx patch that runs in the engine)
		local prev
		for k = 0, 16 do
			local xx = sx + k
			local yy = sy + math.sin((k / 16) * 6.2832 + t * 3) * 5
			if prev then
				line(prev[1], prev[2], xx, yy, ch.accent, a)
			end
			prev = { xx, yy }
		end
	end
end

-- ── Card ────────────────────────────────────────────────────────────────
local function draw_card(ch, c, focused, t)
	if c.alpha <= 0.02 then
		return
	end
	local x, y, w, h = c.x, c.y, c.w * c.scale, c.h * c.scale
	local a = floor(c.alpha * 255)
	local l, top = x - w / 2, y - h / 2

	-- focused card floats on a soft accent halo (stacked low-alpha rings)
	if focused then
		for j = 4, 1, -1 do
			local g = j * 4
			rect(l - g, top - g, w + g * 2, h + g * 2, ch.accent, floor(a * 0.05))
		end
	end

	-- the held card while reordering: a bright pulsing yellow lift, so it reads as "grabbed"
	if S.moving and focused then
		local pulse = 0.5 + 0.5 * math.sin(S.t * 8)
		for j = 6, 1, -1 do
			local g = j * 3
			rect(l - g, top - g, w + g * 2, h + g * 2, COL.yellow, floor(a * 0.07 * pulse))
		end
		text(l + 6, top - 16, "[ MOVING ]", COL.yellow, a)
	end

	-- solid body
	gradient_v(l, top, w, h, COL.panel_hi, COL.panel)
	rect(l, top, w, h, COL.border, floor(a * 0.10))

	-- inner scanline texture on the focused card (alive, not flat)
	if focused and CFG.scanlines then
		local off = CFG.reduce_motion and 0 or (t * 10) % 5
		for yy = top + 4, top + h - 4, 5 do
			line(l + 3, yy + off, l + w - 3, yy + off, ch.accent, floor(a * 0.05))
		end
	end

	-- top + bottom accent rails frame it
	tline(l + 2, top + 2, x + w / 2 - 2, top + 2, 2, ch.accent, floor(a * 0.9))
	tline(l + 2, top + h - 2, x + w / 2 - 2, top + h - 2, 2, ch.accent, floor(a * (focused and 0.7 or 0.25)))

	text(x - #ch.name * 4, y - 10, ch.name, COL.white, a)
	text(x - #ch.tag * 3, y + 8, ch.tag, COL.dim, floor(a * 0.8))
	draw_preview(ch, x + w / 2 - 30, top + 22, a, t)

	-- paid-patch badge (top-left): a small "$" lock so licensed items read at a glance
	if PM.is_paid(ch) then
		rect(l + 6, top + 6, 16, 13, COL.yellow, floor(a * 0.55))
		text(l + 10, top + 6, "$", COL.bg, a)
	end
	-- "running in the background engine" badge (top-right): a turquoise LIVE pill
	if ch.id and LIVE_IDS[tostring(ch.id)] then
		local bw = 36
		local bx = x + w / 2 - bw - 6
		rect(bx, top + 6, bw, 13, COL.turq, floor(a * 0.55))
		text(bx + 5, top + 6, "LIVE", COL.bg, a)
	end
end

-- ── Focus ring ──────────────────────────────────────────────────────────
local function draw_ring(W, H)
	if S.open then
		return
	end
	local c = S.cards[S.focus]
	if not c or c.alpha < 0.3 then
		return
	end
	local x, y, w, h = c.x, c.y, c.w * c.scale, c.h * c.scale
	local r = 5 + math.sin(S.t * 6) * 1.5
	local cl = 14
	-- corner trace accents
	tline(x - w / 2 - r, y - h / 2 - r, x - w / 2 - r + cl, y - h / 2 - r, 2, COL.turq, 200)
	tline(x - w / 2 - r, y - h / 2 - r, x - w / 2 - r, y - h / 2 - r + cl, 2, COL.turq, 200)
	tline(x + w / 2 + r, y - h / 2 - r, x + w / 2 + r - cl, y - h / 2 - r, 2, COL.turq, 200)
	tline(x + w / 2 + r, y - h / 2 - r, x + w / 2 + r, y - h / 2 - r + cl, 2, COL.turq, 200)
	tline(x - w / 2 - r, y + h / 2 + r, x - w / 2 - r + cl, y + h / 2 + r, 2, COL.turq, 200)
	tline(x - w / 2 - r, y + h / 2 + r, x - w / 2 - r, y + h / 2 + r - cl, 2, COL.turq, 200)
	tline(x + w / 2 + r, y + h / 2 + r, x + w / 2 + r - cl, y + h / 2 + r, 2, COL.turq, 200)
	tline(x + w / 2 + r, y + h / 2 + r, x + w / 2 + r, y + h / 2 + r - cl, 2, COL.turq, 200)

	-- oscilloscope sweep — a bright dot tracing the perimeter (skipped by reduce-motion)
	if not CFG.reduce_motion then
		local L, T, R2, B = x - w / 2 - r, y - h / 2 - r, x + w / 2 + r, y + h / 2 + r
		local pw2, ph2 = R2 - L, B - T
		local per = 2 * (pw2 + ph2)
		local d = ((S.t * 0.5) % 1) * per
		local sx, sy
		if d < pw2 then
			sx, sy = L + d, T
		elseif d < pw2 + ph2 then
			sx, sy = R2, T + (d - pw2)
		elseif d < 2 * pw2 + ph2 then
			sx, sy = R2 - (d - pw2 - ph2), B
		else
			sx, sy = L, B - (d - 2 * pw2 - ph2)
		end
		circle(sx, sy, 3, COL.turq, 230)
		circle(sx, sy, 6, COL.turq, 70)
	end
end

-- ── Blade interior pattern (opaque, moving — never see-through) ─────────
-- Software framebuffer has no GPU blur, so the blade gets its own living
-- phosphor field: an opaque base, a slow drifting accent gradient band, soft
-- scanlines, and a faint Sierpinski watermark. All bounded to [ox..ox+pw].
local function draw_blade_field(ox, py, pw, H, ch, a)
	-- 1. fully opaque base — solid surface, lifted from the panel tones
	gradient_v(ox, py, pw, H, COL.panel_hi, COL.panel)
	rect(ox, py, pw, H, COL.panel) -- guarantee full opacity
	-- subtle accent veil so it owns the channel's colour
	rect(ox, py, pw, H, ch.accent, 10)

	-- 2. drifting accent band — soft "glow" faked by stacked low-alpha lines
	local bandC = py + (H * 0.5) + math.sin(S.t * 0.6) * (H * 0.42)
	for j = -26, 26 do
		local f = 1 - math.abs(j) / 26
		line(ox, bandC + j, ox + pw, bandC + j, ch.accent, floor(a * 0.10 * f * f))
	end

	-- 3. drifting fine scanlines (the "moving pattern")
	local sl = 6 * rstep(H)
	local off = (S.t * 14) % sl
	for yy = py, H, sl do
		line(ox, yy + off, ox + pw, yy + off, COL.bg, floor(a * 0.22))
	end

	-- 4. faint Sierpinski watermark, slow vertical drift, clipped by math to blade
	local wm = math.min(pw, H) * 0.7
	local wx = ox + pw * 0.5
	local wy = py + H * 0.5 + math.sin(S.t * 0.4) * 18
	dm.draw.sierpinski(
		floor(wx),
		floor(wy - wm * 0.55),
		floor(wx - wm * 0.55),
		floor(wy + wm * 0.45),
		floor(wx + wm * 0.55),
		floor(wy + wm * 0.45),
		3,
		{ 0, 0, 0, 0 },
		{ ch.accent[1], ch.accent[2], ch.accent[3], floor(a * 0.05) }
	)

	-- 5. crisp leading edge + faux-soft bloom inward
	tline(ox, py, ox, H, 3, ch.accent, a)
	for j = 1, 5 do
		line(ox + j, py, ox + j, H, ch.accent, floor(a * 0.16 * (1 - j / 6)))
	end
end

-- patch metadata panel (drawn inside the blade above the action list)
local function draw_patch_meta(ox, py, pw, listY, p, a)
	local mx, my = ox + 24, py + 96
	local paid = PM.is_paid(p)
	local btxt = paid and ("PAID  $" .. (p.price or 0)) or "FREE"
	local bcol = paid and COL.yellow or COL.green
	rect(mx, my, #btxt * 8 + 12, 18, bcol, 36)
	text(mx + 6, my + 2, btxt, bcol, a)
	text(mx, my + 30, "VER   " .. (p.version or "-") .. "   " .. (p.category or ""), COL.dim, floor(a * 0.9))
	text(mx, my + 48, "BY    " .. (p.author or "unknown"), COL.dim, floor(a * 0.9))
	text(mx, my + 66, "SIZE  " .. (p.size or "-") .. "   " .. (p.type or ""):upper(), COL.dim, floor(a * 0.9))
	if paid and p.account then
		text(mx, my + 84, "LIC   " .. p.account, COL.dim, floor(a * 0.7))
	end
	if p.desc and #p.desc > 0 then
		text(mx, my + 106, p.desc:sub(1, math.max(8, math.floor((pw - 48) / 8))), COL.white, floor(a * 0.8))
	end
	line(ox + 24, listY - 12, ox + pw - 24, listY - 12, COL.border, floor(a * 0.6))
end

-- ── Blade (right-side detail panel: channel sub-menu OR patch detail) ────
local function draw_blade(W, H)
	if not S.open then
		return
	end
	local ch = blade_subject()
	if not ch then
		S.open = nil
		return
	end
	local px, py, pw = blade_geom(W, H)
	local p = S.open.t
	local ox = px + (1 - p) * pw -- slide-in from right
	local a = floor(p * 255)

	rect(0, 0, ox, H, COL.bg, floor(p * 150)) -- dim home behind
	draw_blade_field(ox, py, pw, H, ch, a) -- opaque moving-pattern interior

	-- header
	text(ox + 24, py + 30, ch.name, ch.accent, a)
	text(ox + 24, py + 52, ch.tag or "", COL.dim, floor(a * 0.8))
	line(ox + 24, py + 76, ox + pw - 24, py + 76, COL.border, a)
	draw_preview(ch, ox + pw - 70, py + 44, a, S.t)

	if S.open.opening then
		return
	end

	local _, _, _, listY, rowH = blade_list_geom(W, H)
	if S.open.kind == "patch" then
		draw_patch_meta(ox, py, pw, listY, ch, a)
	end

	-- item / action list
	for i, it in ipairs(blade_items()) do
		local ry = listY + (i - 1) * rowH
		local sel = (S.open.sub == i)
		if sel then
			gradient_v(ox + 16, ry, pw - 32, rowH - 6, COL.panel_hi, COL.panel)
			rect(ox + 16, ry, pw - 32, rowH - 6, ch.accent, 46)
			tline(ox + 16, ry, ox + 16, ry + rowH - 6, 3, ch.accent, a)
			local sw = ox + 16 + ((S.t * 0.5) % 1) * (pw - 32)
			tline(sw, ry, sw, ry + rowH - 6, 1, ch.accent, floor(a * 0.5))
			if S.open.flash then
				rect(ox + 16, ry, pw - 32, rowH - 6, COL.white, floor(S.open.flash * 120))
			end
		end
		if S.open.not_installed then
			text(ox + 32, ry + 10, it.label, COL.dim, floor(a * 0.5))
		else
			text(ox + 32, ry + 10, it.label, sel and COL.white or COL.dim, a)
		end
		local meta = it.meta or ""
		text(ox + pw - #meta * 8 - 32, ry + 12, meta, COL.dim, floor(a * 0.7))
	end

	if S.open.not_installed then
		local msg = S.open.not_installed_msg or "NOT INSTALLED"
		text(ox + 24, H - 42, msg, COL.red, a)
		text(ox + 24, H - 30, "[ back to return ]", COL.dim, floor(a * 0.6))
	else
		text(ox + 24, H - 30, "[ click left / back to return ]", COL.dim, floor(a * 0.6))
	end
end

-- ── Chrome ──────────────────────────────────────────────────────────────
local function draw_chrome(W, H)
	text(20, 22, "TERMINUS", COL.turq, 220)
	text(20 + 9 * 8 + 8, 22, "DeMoD HOME", COL.dim, 140)
	local items = page_items()
	local cur = (S.open and blade_subject() and blade_subject().name)
		or (S.page >= 2 and string.format("PATCHES %d/%d", S.page - 1, patch_page_count()))
		or (items[S.focus] and items[S.focus].name)
		or "HOME"
	text(W - #cur * 8 - 20, 22, cur, COL.white, 160)

	-- page dots (centred under the wordmark): 1 = channels, 2.. = patch pages
	local pages = total_pages()
	local gap = 14
	local dx0 = W / 2 - ((pages - 1) * gap) / 2
	for i = 1, pages do
		local on = (i == S.page)
		circle(dx0 + (i - 1) * gap, 18, on and 4 or 2, on and COL.turq or COL.border, on and 230 or 150)
	end

	-- ownership indicator + (on the patches page) a count legend
	local own = PM.owner and ("OWNED " .. (PM.owner.name or PM.owner.account)) or "UNADOPTED"
	text(20, 40, own, PM.owner and COL.green or COL.yellow, 150)
	if S.page >= 2 then
		local c = PM.counts()
		local leg = string.format("%d PATCH  %d app  %d fx  %d paid", c.total, c.app, c.fx, c.paid)
		text(W - #leg * 8 - 20, 40, leg, COL.dim, 140)
	end

	-- bottom status strip (honest: live where we can read it, neutral otherwise)
	local sy = H - 26
	line(0, H - 40, W, H - 40, COL.border, 120)
	-- realtime engine: live pitch from the param bus when present, else "--"
	local rt = S.rt or {}
	text(20, sy, "RT", rt.present and COL.green or COL.dim, 200)
	circle(20 + 22, sy + 6, 3, rt.present and COL.green or COL.border, 220)
	text(70, sy, rt.present and string.format("%.0fHz", rt.pitch or 0) or "--", COL.dim, 140)
	-- USB-C bridge (the device has no wireless): linked once adopted/owned
	local linked = PM.owner ~= nil
	text(160, sy, "BRIDGE", linked and COL.turq or COL.dim, 200)
	circle(160 + 50, sy + 6, 3, linked and COL.turq or COL.border, 220)
	-- MIDI: lit turquoise while a controller is sending (same honest-status idiom)
	local mact = midi.activity()
	text(330, sy, "MIDI", mact > 0.05 and COL.turq or COL.dim, 200)
	circle(330 + 34, sy + 6, 3, mact > 0.05 and COL.turq or COL.border, 220)
	-- position: global patch index over the whole library on patch pages, else in-page
	local n = #page_items()
	if n > 0 then
		local pos, tot = S.focus, n
		if S.page >= 2 then
			pos, tot = patch_index(S.focus), #PM.list
		end
		text(250, sy, string.format("%d/%d", pos, tot), COL.dim, 140)
	end
	-- clock + mode/res badge (right)
	local badge = string.format("%s %dx%d", S.mode:upper(), W, H)
	local bbx = W - #badge * 8 - 20
	text(bbx, sy, badge, COL.dim, 120)
	local clk = os.date("%H:%M")
	text(bbx - #clk * 8 - 16, sy, clk, COL.white, 160)
end

-- ── Modals: Power confirm + USB-C bridge sync ──────────────────────────
local function ctext(cx, y, s, c, a)
	text(cx - #s * 4, y, s, c, a)
end -- centred text

local function draw_confirm(W, H)
	local m = S.modal
	rect(0, 0, W, H, COL.bg, floor(180 * clamp(m.t * 8, 0, 1)))
	local bx, by, bw, bh, rowH, titleH, pad = confirm_geom(W, H)
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	rect(bx, by, bw, bh, COL.panel) -- opaque surface
	tline(bx, by, bx + bw, by, 2, m.accent, 255)
	tline(bx, by + bh, bx + bw, by + bh, 2, m.accent, 255)
	text(bx + pad, by + 18, m.title, m.accent, 255)
	line(bx + pad, by + titleH - 10, bx + bw - pad, by + titleH - 10, COL.border, 180)
	for i, c in ipairs(m.choices) do
		local ry = by + titleH + (i - 1) * rowH
		local sel = (i == m.sel)
		local danger = (c.cmd ~= nil) -- restart / shut down
		local hue = danger and COL.red or (c.quit and COL.yellow or COL.white)
		if sel then
			gradient_v(bx + pad, ry, bw - 2 * pad, rowH - 6, COL.panel_hi, COL.panel)
			rect(bx + pad, ry, bw - 2 * pad, rowH - 6, danger and COL.red or m.accent, 44)
			tline(bx + pad, ry, bx + pad, ry + rowH - 6, 3, danger and COL.red or m.accent, 255)
		end
		text(bx + pad + 14, ry + (rowH - 6) / 2 - 8, c.label, sel and hue or COL.dim, sel and 255 or 170)
	end
	ctext(W / 2, by + bh + 14, "[ turn: choose   press: confirm   back: cancel ]", COL.dim, 150)
end

local function draw_bridge(W, H)
	local m = S.modal
	rect(0, 0, W, H, COL.bg, floor(195 * clamp(m.t * 6, 0, 1)))
	local accent = CHANNELS[S.open and S.open.idx or 4].accent
	local bw = math.min(W * 0.82, 560)
	local bh = math.min(H * 0.66, 360)
	local bx, by = W / 2 - bw / 2, H / 2 - bh / 2
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	rect(bx, by, bw, bh, COL.panel)
	tline(bx, by, bx + bw, by, 2, accent, 255)
	tline(bx, by + bh, bx + bw, by + bh, 2, accent, 255)
	text(bx + 20, by + 16, "USB-C BRIDGE", accent, 255)
	text(bx + bw - #"StreamDB" * 8 - 20, by + 16, "StreamDB", COL.turq, 200)

	local midY = by + bh * 0.40
	local srcX, dstX = bx + 78, bx + bw - 96

	-- companion endpoint (left) with USB-C plug
	rect(srcX - 30, midY - 20, 26, 40, COL.dim, 70)
	rect(srcX - 30, midY - 20, 26, 40, accent, 40)
	rect(srcX - 6, midY - 6, 12, 12, accent, 220)
	ctext(srcX - 16, midY + 30, "COMPANION", COL.dim, 150)

	-- cable
	line(srcX, midY, dstX, midY, COL.border, 160)

	-- StreamDB reverse-trie endpoint (right) — a phosphor Sierpinski branch
	local tg = (m.phase >= 3) and 150 or 70
	dm.draw.sierpinski(
		floor(dstX + 24),
		floor(midY - 28),
		floor(dstX),
		floor(midY + 22),
		floor(dstX + 48),
		floor(midY + 22),
		3,
		{ 0, 0, 0, 0 },
		{ COL.turq[1], COL.turq[2], COL.turq[3], tg }
	)
	ctext(dstX + 24, midY + 30, "REVERSE TRIE", COL.dim, 150)

	-- travelling duck
	if m.phase == 3 then
		local duck_x = srcX + (dstX - srcX) * m.prog
		local duck_y = midY + math.sin(m.prog * 30) * 6
		duck_anim.draw(floor(duck_x - 24), floor(duck_y - 24), 48, 48, 220)
	end

	-- phase line (with animated working dots)
	local PHASE = { "DETECTING USB-C", "HANDSHAKE  .  StreamDB index ready", "SYNCING PATCHES", "" }
	if m.phase < 4 then
		local dots = string.rep(".", (floor(m.t * 3) % 4))
		text(bx + 20, by + bh - 80, (PHASE[m.phase] or "") .. dots, accent, 230)
	end

	-- progress bar
	local pbx, pby, pbw = bx + 20, by + bh - 56, bw - 40
	rect(pbx, pby, pbw, 8, COL.border, 160)
	rect(pbx, pby, pbw * m.prog, 8, (m.phase >= 4) and COL.green or accent, 230)
	text(
		pbx,
		pby + 14,
		string.format("%d / %d blocks    %d%%", m.done_blocks, m.total, floor(m.prog * 100)),
		COL.dim,
		160
	)

	if m.phase >= 4 then
		local pulse = 0.5 + 0.5 * math.sin(m.t * 4)
		text(bx + 20, by + bh - 80, "[OK] SAFE TO DISCONNECT", COL.green, floor(150 + 105 * pulse))
		text(bx + bw - #"press to close" * 8 - 20, by + bh - 22, "press to close", COL.dim, 170)
		-- gentle bloom ring around the trie to draw the eye to "done"
		circle(dstX + 24, midY, 22 + pulse * 6, COL.green, floor(40 * pulse))
	end
end

local function draw_settings(W, H)
	local m = S.modal
	rect(0, 0, W, H, COL.bg, floor(180 * clamp(m.t * 8, 0, 1)))
	local cat = SET.categories[m.cat]
	local bx, by, bw, bh, rowH, titleH, pad = settings_geom(W, H)
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	rect(bx, by, bw, bh, COL.panel)
	tline(bx, by, bx + bw, by, 2, COL.turq, 255)
	tline(bx, by + bh, bx + bw, by + bh, 2, COL.turq, 255)
	text(bx + pad, by + 16, cat.name, COL.turq, 255)
	text(bx + bw - #"SETTINGS" * 8 - pad, by + 16, "SETTINGS", COL.dim, 150)
	line(bx + pad, by + titleH - 10, bx + bw - pad, by + titleH - 10, COL.border, 180)
	for i, row in ipairs(cat.rows) do
		local ry = by + titleH + (i - 1) * rowH
		local sel = (i == m.sel)
		local editing = sel and m.adjust
		if sel then
			gradient_v(bx + pad, ry, bw - 2 * pad, rowH - 6, COL.panel_hi, COL.panel)
			rect(bx + pad, ry, bw - 2 * pad, rowH - 6, COL.turq, editing and 60 or 32)
			tline(bx + pad, ry, bx + pad, ry + rowH - 6, 3, COL.turq, 255)
		end
		local lcol = (row.type == "info") and COL.dim or (sel and COL.white or COL.dim)
		text(bx + pad + 12, ry + (rowH - 6) / 2 - 8, row.label, lcol, sel and 255 or 180)
		local val = SET.display(row)
		local vcol = editing and COL.turq or (sel and COL.white or COL.dim)
		text(bx + bw - pad - #val * 8, ry + (rowH - 6) / 2 - 8, val, vcol, 230)
		-- a mini value bar for the selected slider
		if row.type == "slider" and sel then
			local v = SET.values[row.key]
			local frac = (v - row.min) / math.max(1e-6, (row.max - row.min))
			local bw2 = 60
			local bx2 = bx + bw - pad - #val * 8 - bw2 - 12
			rect(bx2, ry + (rowH - 6) / 2 - 2, bw2, 4, COL.border, 160)
			rect(bx2, ry + (rowH - 6) / 2 - 2, floor(bw2 * frac), 4, COL.turq, 230)
		end
	end
	local hint = m.adjust and "[ turn: adjust   sel / back: done ]"
		or "[ turn: select   sel: edit / toggle   back: save ]"
	ctext(W / 2, by + bh + 14, hint, COL.dim, 150)
end

local function draw_help(W, H)
	local m = S.modal
	rect(0, 0, W, H, COL.bg, floor(190 * clamp(m.t * 8, 0, 1)))
	local lines, title = {}, "CONTROLS"
	if m.onboarding then
		local pg = HELP_PAGES[m.page]
		title = pg.title
		lines = pg.lines
	else
		for _, p in ipairs(HELP_PAGES) do
			for _, l in ipairs(p.lines) do
				lines[#lines + 1] = l
			end
		end
	end
	local bw = math.min(W * 0.82, 470)
	local bh = 52 + #lines * 20 + 34
	local bx, by = W / 2 - bw / 2, H / 2 - bh / 2
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	rect(bx, by, bw, bh, COL.panel)
	tline(bx, by, bx + bw, by, 2, COL.turq, 255)
	tline(bx, by + bh, bx + bw, by + bh, 2, COL.turq, 255)
	text(bx + 20, by + 16, m.onboarding and ("WELCOME  " .. title) or title, COL.turq, 255)
	if m.onboarding then
		text(bx + bw - #"TERMINUS" * 8 - 20, by + 16, "TERMINUS", COL.dim, 150)
	end
	line(bx + 20, by + 40, bx + bw - 20, by + 40, COL.border, 180)
	for i, l in ipairs(lines) do
		text(bx + 24, by + 50 + (i - 1) * 20, l, COL.white, 220)
	end
	if m.onboarding then
		local n = #HELP_PAGES
		local gx = bx + bw / 2 - (n - 1) * 7
		for i = 1, n do
			circle(
				gx + (i - 1) * 14,
				by + bh - 20,
				i == m.page and 4 or 2,
				i == m.page and COL.turq or COL.border,
				i == m.page and 230 or 150
			)
		end
		ctext(
			W / 2,
			by + bh + 12,
			(m.page < n) and "[ turn: page   press: next   back: skip ]" or "[ press: done   back: skip ]",
			COL.dim,
			150
		)
	else
		ctext(W / 2, by + bh + 12, "[ press / back: close ]", COL.dim, 150)
	end
end

local function wrap_modal_lines(body, max_chars, max_lines)
	local out = {}
	body = tostring(body or ""):gsub("\r", "")
	if body == "" then
		body = "(no output)"
	end
	for raw in (body .. "\n"):gmatch("([^\n]*)\n") do
		local line0 = raw == "" and " " or raw
		while #line0 > max_chars do
			local chunk = line0:sub(1, max_chars)
			local sp = chunk:match(".*()%s")
			local cut = (sp and sp > 14) and (sp - 1) or max_chars
			out[#out + 1] = line0:sub(1, cut)
			line0 = line0:sub(cut + 1):gsub("^%s+", "")
			if #out >= max_lines then
				out[#out] = out[#out]:sub(1, math.max(1, max_chars - 3)) .. "..."
				return out
			end
		end
		out[#out + 1] = line0
		if #out >= max_lines then
			return out
		end
	end
	return out
end

local function draw_text_modal(W, H)
	local m = S.modal
	rect(0, 0, W, H, COL.bg, floor(190 * clamp(m.t * 8, 0, 1)))
	local bw = math.min(W * 0.84, 560)
	local max_chars = math.max(18, floor((bw - 44) / 8))
	local lines = wrap_modal_lines(m.body, max_chars, math.max(4, floor((H * 0.68 - 90) / 20)))
	local bh = math.min(H * 0.78, 58 + #lines * 20 + 36)
	local bx, by = W / 2 - bw / 2, H / 2 - bh / 2
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	rect(bx, by, bw, bh, COL.panel)
	tline(bx, by, bx + bw, by, 2, m.accent, 255)
	tline(bx, by + bh, bx + bw, by + bh, 2, m.accent, 255)
	text(bx + 20, by + 16, m.title or "STATUS", m.accent, 255)
	line(bx + 20, by + 42, bx + bw - 20, by + 42, COL.border, 180)
	for i, l in ipairs(lines) do
		text(bx + 24, by + 54 + (i - 1) * 20, l, l == " " and COL.dim or COL.white, 220)
	end
	ctext(W / 2, by + bh + 12, "[ press / back: close ]", COL.dim, 150)
end

local function draw_modal(W, H)
	if not S.modal then
		return
	end
	if S.modal.kind == "confirm" then
		draw_confirm(W, H)
	elseif S.modal.kind == "settings" then
		draw_settings(W, H)
	elseif S.modal.kind == "help" then
		draw_help(W, H)
	elseif S.modal.kind == "text" then
		draw_text_modal(W, H)
	elseif S.modal.kind == "bridge" then
		draw_bridge(W, H)
	end
end

-- ── Launch hand-off card (only for actually launching an app) ──────────
local function draw_launch(W, H)
	if not S.launching then
		return
	end
	local Lc = S.launching
	local a = floor(255 * clamp(math.min(Lc.t * 6, (1.5 - Lc.t) * 4, 1), 0, 1))
	rect(0, 0, W, H, COL.bg, floor(a * 0.7))
	local bw, bh = math.min(W * 0.7, 420), 96
	local bx, by = W / 2 - bw / 2, H / 2 - bh / 2
	gradient_v(bx, by, bw, bh, COL.panel_hi, COL.panel)
	local accent = Lc.accent
	tline(bx, by, bx + bw, by, 2, accent, a)
	tline(bx, by + bh, bx + bw, by + bh, 2, accent, a)
	local msg = "LAUNCHING"
	text(W / 2 - #msg * 4, H / 2 - 18, msg, COL.dim, a)
	text(W / 2 - #Lc.name * 4, H / 2 + 2, Lc.name, accent, a)
	local sw = bx + 20 + ((S.t * 0.8) % 1) * (bw - 40)
	circle(sw, by + bh - 12, 2, accent, a)
end

-- ── Toasts (transient feedback, stacked bottom-right) ──────────────────
local TOAST_COL = { info = COL.turq, ok = COL.green, warn = COL.yellow, err = COL.red }
local function draw_toasts(W, H)
	local n = #S.toasts
	if n == 0 then
		return
	end
	for i = 1, n do
		local tt = S.toasts[i]
		local col = TOAST_COL[tt.kind] or COL.turq
		local a = floor(255 * clamp(math.min(tt.t * 8, (2.5 - tt.t) * 4, 1), 0, 1))
		local tw = #tt.msg * 8 + 28
		local slide = CFG.reduce_motion and 0 or floor((1 - clamp(tt.t * 8, 0, 1)) * 16)
		local bx = W - tw - 18 + slide
		local by = H - 70 - (n - i) * 30
		gradient_v(bx, by, tw, 24, COL.panel_hi, COL.panel)
		rect(bx, by, tw, 24, col, floor(a * 0.14))
		tline(bx, by, bx, by + 24, 3, col, a)
		text(bx + 12, by + 4, tt.msg, col, a)
	end
end

-- ── Boot ────────────────────────────────────────────────────────────────
local function draw_boot(W, H)
	local p = S.boot
	local a = floor((1 - p) * 255)
	rect(0, 0, W, H, COL.bg, a)
	local s = math.min(W, H) * 0.4 * (0.5 + p * 0.5)
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
		{ COL.turq[1], COL.turq[2], COL.turq[3], floor(a * 0.8) },
		{ COL.turq[1], COL.turq[2], COL.turq[3], a },
		8
	)
	text(cx - 32, cy + s * 0.6 + 10, "TERMINUS", COL.turq, a)
end

-- ── Empty patches page ─────────────────────────────────────────────────
local function draw_empty_patches(W, H)
	local cw, ch = math.min(W * 0.7, 380), 124
	local cx, cy = W / 2, H / 2
	local l, top = cx - cw / 2, cy - ch / 2
	gradient_v(l, top, cw, ch, COL.panel_hi, COL.panel)
	rect(l, top, cw, ch, COL.panel)
	tline(l, top, l + cw, top, 2, COL.yellow, 200)
	tline(l, top + ch, l + cw, top + ch, 2, COL.yellow, 90)
	-- a faint program glyph
	dm.draw.sierpinski(
		floor(cx),
		floor(cy - 44),
		floor(cx - 22),
		floor(cy - 8),
		floor(cx + 22),
		floor(cy - 8),
		2,
		{ 0, 0, 0, 0 },
		{ COL.yellow[1], COL.yellow[2], COL.yellow[3], 90 }
	)
	ctext(cx, cy + 2, "NO PATCHES YET", COL.white, 220)
	ctext(cx, cy + 22, "Sync programs via Marketplace", COL.dim, 180)
	ctext(cx, cy + 42, "[ page back . open MARKETPLACE ]", COL.dim, 140)
end

-- ── Frame ─────────────────────────────────────────────────────────────
function on_draw()
	local W, H = dm.width(), dm.height()
	draw_background(W, H)
	local items = page_items()
	if S.page >= 2 and #items == 0 then
		draw_empty_patches(W, H)
	else
		local n = #items
		for off = n - 1, 0, -1 do
			for i = 1, n do
				if math.abs(i - S.focus) == off and S.cards[i] then
					draw_card(items[i], S.cards[i], i == S.focus, S.t)
				end
			end
		end
	end
	draw_ring(W, H)
	draw_blade(W, H)
	draw_modal(W, H)
	draw_toasts(W, H)
	draw_chrome(W, H)
	draw_launch(W, H)
	-- recording badge (recorder runs detached; visible from anywhere while a take runs)
	if S._rec and S._rec.on then
		local secs = floor(S._rec.elapsed or 0)
		local label = string.format("REC  %02d:%02d", floor(secs / 60), secs % 60)
		local bw = 8 * #label + 36
		local bx = floor(W / 2 - bw / 2)
		rect(bx, 8, bw, 22, COL.bg, 205)
		tline(bx, 8, bx + bw, 8, 2, COL.red, 220)
		tline(bx, 30, bx + bw, 30, 1, COL.red, 120)
		local pulse = 0.5 + 0.5 * math.sin(S.t * 4)
		circle(bx + 15, 19, 5, COL.red, floor(120 + 135 * pulse))
		text(bx + 28, 12, label, COL.red, 245)
	end
	if S.boot < 1 then
		draw_boot(W, H)
	end
end
