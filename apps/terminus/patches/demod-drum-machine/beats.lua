-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
--[[ ============================================================================
  patches/demod-drum-machine/beats.lua — the saved-beats library (file-backed).

  Saved beats ARE Standard MIDI Files in a beats directory, so the library and
  "load a .mid" are the same thing: saving exports the current bank to
  <dir>/<name>.mid (usable in any DAW); dropping a .mid into <dir> makes it
  appear in the list; loading imports it back onto the grid.

      B.init(SMF, voices)
      B.dir()                      -> the beats directory (created on save)
      B.list()                     -> { name, ... } sorted (no extension)
      B.save_new(pattern)          -> name        (auto-named BEAT-NN.mid)
      B.save(name, pattern)        -> ok, err
      B.load(name)                 -> ok, res     (res = { bpm, hits })  [via SMF]
      B.delete(name)               -> ok
      B.import_file(path)          -> ok, res     (load any .mid by path)

  Directory: $DEMOD_BEATS_DIR, else <DEMOD_CONFIG dir>/beats, else
  ~/.config/demod/beats. dm-free (io/os only).

  © 2026 DeMoD LLC. Private.
============================================================================ ]]
local B = {}
local SMF, VOICES -- injected

function B.init(smf, voices)
	SMF, VOICES = smf, voices
end

local function shq(s) -- POSIX single-quote (SECURITY.md F-7)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

function B.dir()
	local d = os.getenv("DEMOD_BEATS_DIR")
	if d and #d > 0 then
		return d
	end
	local cfg = os.getenv("DEMOD_CONFIG")
	if cfg and #cfg > 0 then
		return (cfg:match("(.*/)") or "./") .. "beats"
	end
	return (os.getenv("HOME") or ".") .. "/.config/demod/beats"
end

local function ensure_dir()
	os.execute("mkdir -p " .. shq(B.dir()) .. " 2>/dev/null")
end

local function safe_name(name)
	return tostring(name):gsub("[^%w%-_]", "_")
end

function B.path(name)
	return B.dir() .. "/" .. safe_name(name) .. ".mid"
end

function B.list()
	local out = {}
	local p = io.popen("ls -1 " .. shq(B.dir()) .. " 2>/dev/null")
	if p then
		for line in p:lines() do
			local n = line:match("^(.+)%.mid$") or line:match("^(.+)%.MID$")
			if n then
				out[#out + 1] = n
			end
		end
		p:close()
	end
	table.sort(out)
	return out
end

function B.exists(name)
	local f = io.open(B.path(name), "rb")
	if f then
		f:close()
		return true
	end
	return false
end

function B.save(name, pattern)
	ensure_dir()
	return SMF.export(B.path(name), pattern, VOICES)
end

-- auto-name BEAT-01, BEAT-02, … (first free), then save
function B.save_new(pattern)
	ensure_dir()
	local i = 1
	while B.exists(string.format("BEAT-%02d", i)) and i < 1000 do
		i = i + 1
	end
	local name = string.format("BEAT-%02d", i)
	local ok = B.save(name, pattern)
	return ok and name or nil
end

function B.load(name)
	return SMF.import(B.path(name), VOICES)
end

function B.import_file(path)
	return SMF.import(path, VOICES)
end

function B.delete(name)
	return os.remove(B.path(name)) and true or false
end

return B
