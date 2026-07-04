<!-- SPDX-License-Identifier: MPL-2.0 -->
# DeMoD MCP server

A [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI agent
**work with the DeMoD system**: build it, render it headless (and *see* the screenshot), run
its test harnesses, and drive a **live engine** over the orchestrator control socket.

It's a single pure-standard-library Python file — no pip/npm deps — speaking MCP over stdio
(newline-delimited JSON-RPC 2.0, protocol `2024-11-05`). It's thin glue: tools shell out to the
repo's own binaries/harnesses (`nix`, the `bridge/test/*.sh` scripts, the `DEMOD_SHOT` headless
render) and speak the control socket directly, reusing the JSON-lines pattern from
`audio-stack/bridge/test/control_probe.py`.

## Install

Point it at your working tree (the tools build/test/render *this* repo):

```bash
claude mcp add demod -- python3 /path/to/DeMoD/mcp/demod_mcp_server.py
```

Or, from the repo root, `nix run .#mcp`. `codex`/other MCP clients: run the same command as an
stdio server. Set `DEMOD_REPO` to override the repo path if you don't launch from the tree.

**Requirements:** `nix` on `PATH` for the build/test/render tools. The engine tools need a running
orchestrator control socket — `$DEMOD_CONTROL_SOCK` or `/run/demod/control.sock` (bring one up with
`nix run`/the harnesses; see `audio-stack/bridge/test/README.md`).

## Tools

| Tool | What it does |
|------|--------------|
| `demod_build` | `nix build .#<pkg>` (demod-ui, demod-rt, demod-orchestrator, demod-remote-bridge, dcf-ws-bridge, demod-ui-dcf) |
| `demod_render` | Render an example UI headless (`DEMOD_SHOT`) and return a **PNG** the agent can see |
| `demod_smoke` | Boot an example headless and confirm no Lua errors |
| `demod_test` | Run a bridge harness (`loopback` / `ws_loopback` / `engine_e2e`) → PASS/FAIL/SKIP |
| `demod_engine_health` | A live orchestrator's `get_health` (demod-rt liveness, callbacks, xruns, children) |
| `demod_engine_list_slots` | The engine's FX/synth slot table |
| `demod_engine_op` | Send one control op — `set_bpm`, `set_param`, `load_fx`, `bypass_fx`, `synth.*`, `set_slot_*` — and return the reply |

**Resources:** `demod://skill` (the `SKILL.md` `dm.*` API reference) and `demod://control-ops`
(the control-socket op vocabulary), so an agent writing Lua or issuing ops has the reference inline.

Engine writes are whitelisted; unknown ops are refused. The server never spawns the RT engine
itself (that needs JACK + RT privileges — use `nix run`/`engine_e2e.sh`); it drives one that's
already running.
