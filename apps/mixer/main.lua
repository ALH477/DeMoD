-- SPDX-License-Identifier: MPL-2.0
-- DeMoD Mixer — a touch-first channel-strip surface for the DeMoD audio engine,
-- on the companion-shell SDK. A rack unit's front panel, a kiosk, a laptop
-- window: the same script. The engine is local (control socket), remote (DCF,
-- e.g. the Oligarchy DSP VM) or absent (a labelled simulator); see backend.lua
-- and README.md. MPL-2.0. Copyright (c) 2026 DeMoD LLC.
local APP = os.getenv("DEMOD_MIXER_DIR") or (debug.getinfo(1, "S").source:match("^@(.*/)")) or "./"
local SHELL = os.getenv("DEMOD_SHELL_DIR") or (APP:gsub("apps/mixer/?$", "") .. "shell/")
local function aload(f)
  return dofile(APP .. f)
end

local json = aload("json.lua")
local taper = aload("taper.lua")
local input = aload("input.lua")
local deps = { json = json, taper = taper, input = input }
local mixer = aload("surfaces/mixer.lua")(deps)
local engine = aload("surfaces/engine.lua")(deps)
input.load(mixer.layout)

local backend = aload("backend.lua").new(json)
-- the shell's provider contract: update / read / status
function backend:read()
  return {}
end
function backend:status()
  return self:label()
end

-- Headless test hook: replay DEMOD_MIXER_GESTURES, then print what the strips
-- show and exit. Never active without that variable.
local function test_tick()
  if not input.scripted() then
    return
  end
  if input.frame >= input.last_frame() + 30 then
    local st = mixer.readback(backend)
    for i = 1, 16 do
      print(
        string.format(
          "READBACK slot=%d gain=%.4f pan=%.2f mute=%d solo=%d",
          i - 1,
          st.gain[i],
          st.pan[i],
          (st.mute >> (i - 1)) & 1,
          (st.solo >> (i - 1)) & 1
        )
      )
    end
    print(
      string.format(
        "READBACK backend=%s sent=%d refused=%d",
        backend.kind,
        backend.sent,
        backend.refused
      )
    )
    os.exit(backend.refused == 0 and 0 or 3)
  end
end

local shell = dofile(SHELL .. "shell.lua")
shell.run({
  title = "DeMoD Mixer",
  palettes = aload("theme.lua"),
  config = {
    path = os.getenv("DEMOD_MIXER_CONFIG")
      or ((os.getenv("HOME") or "/tmp") .. "/.config/demod/mixer.lua"),
    keys = { "theme" },
    defaults = { theme = "night" },
  },
  provider = backend,
  surfaces = { mixer, engine },
  status = function(c)
    return c.provider:label()
  end,
})

-- The shell owns on_update; wrap it to count frames for the input replay.
local shell_update = on_update
function on_update(dt)
  input.tick()
  shell_update(dt)
  test_tick()
end
