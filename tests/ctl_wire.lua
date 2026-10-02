-- SPDX-License-Identifier: MPL-2.0
-- ctl_wire.lua — headless: drive the dm.ctl_* helpers at the control socket
-- named by DEMOD_CONTROL_SOCK (tests/fake_orchestrator.py) and exit 0 only if
-- the engine accepted every one. Run by tests/ctl_wire.sh.
local fails = 0
local function check(name, ok)
  print((ok and "PASS: " or "FAIL: ") .. name)
  if not ok then
    fails = fails + 1
  end
end

check("dm.ctl_set_param accepted", dm.ctl_set_param(1, 2, 0.25))
check("dm.ctl_bypass accepted", dm.ctl_bypass(3, true))
check("dm.ctl_bpm accepted", dm.ctl_bpm(128))
check("dm.ctl_gain accepted", dm.ctl_gain(0.8))

local ok, reply = dm.ctl_request('{"v":1,"id":"h1","op":"get_health"}')
check(
  "dm.ctl_request returns the reply line",
  ok and reply:find('"id":"h1"', 1, true) ~= nil and reply:find('"alive":true', 1, true) ~= nil
)
local bad, breply = dm.ctl_request('{"id":"probe","cmd":"set_gain","gain":1}')
check(
  "a request without an op is refused, with the engine's reason",
  (not bad) and breply:find("missing op", 1, true) ~= nil
)

os.exit(fails == 0 and 0 or 1)
