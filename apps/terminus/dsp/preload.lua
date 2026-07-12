-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  dsp/preload.lua — boot-time FX-chain loader.

  Pushes the default effect chain into the demod-rt engine so effects are audible
  the moment the device boots, before the user opens DSP Studio. Run headlessly by
  the desktop launcher (scripts/demod-desktop.sh) right after the control socket is
  ready. It simply instantiates the DSP backend: the orchestrator backend's new()
  is the single source of truth and emits load_fx + set_param + wet for the default
  layout. The launcher then exports DEMOD_DSP_CHAIN_LOADED=1 so DSP Studio skips its
  own startup load and avoids reloading the chain.

  Copyright (c) 2026 DeMoD LLC. All rights reserved. Private — not for public distribution.
============================================================================ ]]

local BASE = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*)/[^/]*$") or "."

local ok, sel = pcall(dofile, BASE .. "/backend/select.lua")
if ok and sel and sel.select then
	local ok2, _, name = pcall(sel.select, BASE)
	io.stderr:write(
		"[dsp-preload] default chain pushed (backend=" .. tostring(name) .. ", ok=" .. tostring(ok2) .. ")\n"
	)
else
	io.stderr:write("[dsp-preload] could not load backend selector\n")
end

-- Headless one-shot: the chain is now pushed to the engine, so terminate at once.
-- dm.quit() only *requests* loop exit, but the orchestrator backend holds a live
-- dm.ctl control-socket connection and the event-driven main loop parks in a frame
-- sleep under SDL_VIDEODRIVER=dummy, so the quit flag is never serviced and the
-- process hangs — which blocks the launcher (scripts/demod-desktop.sh step 6c runs
-- this in the foreground before TERMINUS opens). os.exit() guarantees termination
-- regardless of backend/loop state. The chain push already completed synchronously
-- above (see the [dsp-preload] line), so nothing is lost by exiting hard here.
if dm and dm.quit then
	dm.quit()
end
os.exit(0)
