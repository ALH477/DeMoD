#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 DeMoD LLC.
"""
demod_mcp_server.py — a Model Context Protocol server for working with the DeMoD
system: build it, render it headless (and see the screenshot), run its test
harnesses, and drive a live engine over the orchestrator control socket.

Pure Python standard library — no pip/npm deps. Speaks MCP over stdio
(newline-delimited JSON-RPC 2.0, protocol 2024-11-05). It is thin glue: tools
shell out to the repo's existing binaries/harnesses (nix, the bridge test
scripts, the DEMOD_SHOT headless render) and speak the control socket directly,
reusing the JSON-lines pattern from audio-stack/bridge/test/control_probe.py.

Install (points at your working tree so the tools can build/test it):
    claude mcp add demod -- python3 /path/to/DeMoD/mcp/demod_mcp_server.py
Requires `nix` on PATH for the build/test/render tools. Engine tools need a
running orchestrator control socket ($DEMOD_CONTROL_SOCK or /run/demod/control.sock).
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import zlib

SERVER_NAME = "demod"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

# The repo is the parent of this mcp/ dir; override with DEMOD_REPO. Tools run
# against the working tree (they build/test/render it), not a store copy.
REPO = os.environ.get("DEMOD_REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAX_OUT = 6000          # cap tool text output so it can't flood the agent
RENDER_MAX_W = 720      # downscale screenshots to keep the base64 small

# Examples safe to build/run (plain, non-DCF unless noted).
EXAMPLES = ["dsp_studio", "systems_viz", "hello", "dsp_panel", "card_launcher"]
# Flake packages the build tool will nix-build.
PACKAGES = ["demod-ui", "demod-rt", "demod-orchestrator", "demod-ui-dcf",
            "demod-remote-bridge", "dcf-ws-bridge"]
# Test harnesses (bridge/test).
HARNESSES = {"loopback": "loopback.sh", "ws_loopback": "ws_loopback.sh",
             "engine_e2e": "engine_e2e.sh"}
# Control-socket ops an agent may issue (everything read-only + the safe writes).
ENGINE_OPS = {
    "ping", "get_health", "list_slots",
    "set_bpm", "set_gain", "set_param", "bypass_fx", "load_fx", "unload_fx",
    "synth.load", "synth.unload", "synth.mode", "synth.gain",
    "synth.note_on", "synth.note_off", "synth.all_notes_off",
    "set_slot_gain", "set_slot_pan", "set_slot_mute", "set_slot_solo",
}


# ── helpers ─────────────────────────────────────────────────────────────────
def _tail(s, n=MAX_OUT):
    s = s or ""
    return s if len(s) <= n else "…(truncated)…\n" + s[-n:]


def run(cmd, timeout=300, env=None, cwd=REPO):
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, timeout=timeout, env=e,
                           capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as ex:
        return 124, (ex.stdout or ""), (ex.stderr or "") + "\n[timed out]"
    except FileNotFoundError as ex:
        return 127, "", str(ex)


def control_request(sock_path, obj, timeout=3.0):
    """One JSON-lines request/reply on the orchestrator control socket."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    if not buf:
        raise RuntimeError("no reply from control socket")
    return json.loads(buf.split(b"\n", 1)[0].decode())


def control_path(arg):
    return arg or os.environ.get("DEMOD_CONTROL_SOCK") or "/run/demod/control.sock"


# ── PPM(P6) -> PNG, pure stdlib (zlib), with nearest-neighbour downscale ─────
def _read_ppm(data):
    if data[:2] != b"P6":
        raise ValueError("not a P6 PPM")
    i, toks = 2, []
    while len(toks) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while i < len(data) and data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        toks.append(data[i:j])
        i = j
    w, h, _mx = int(toks[0]), int(toks[1]), int(toks[2])
    i += 1  # single whitespace after maxval
    return w, h, data[i:i + w * h * 3]


def _downscale(w, h, rgb, max_w):
    if w <= max_w:
        return w, h, rgb
    nw = max_w
    nh = max(1, h * max_w // w)
    out = bytearray(nw * nh * 3)
    for y in range(nh):
        sy = (y * h // nh) * w
        row = y * nw
        for x in range(nw):
            si = (sy + x * w // nw) * 3
            di = (row + x) * 3
            out[di:di + 3] = rgb[si:si + 3]
    return nw, nh, bytes(out)


def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))


def rgb_to_png(w, h, rgb):
    raw = bytearray()
    stride = w * 3
    for y in range(h):
        raw.append(0)                       # filter type 0 (none)
        raw += rgb[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"IDAT", comp) + _png_chunk(b"IEND", b""))


# ── tools ────────────────────────────────────────────────────────────────────
def text(s):
    return {"content": [{"type": "text", "text": _tail(s)}]}


def err(s):
    return {"content": [{"type": "text", "text": _tail(s)}], "isError": True}


def tool_build(a):
    pkg = a.get("package", "demod-ui")
    if pkg not in PACKAGES:
        return err("unknown package %r; choose one of: %s" % (pkg, ", ".join(PACKAGES)))
    rc, out, e = run(["nix", "build", ".#" + pkg, "-L", "--no-link"], timeout=1200)
    head = "nix build .#%s -> %s\n" % (pkg, "OK" if rc == 0 else "FAIL (rc=%d)" % rc)
    return (text if rc == 0 else err)(head + _tail(e or out))


def tool_test(a):
    which = a.get("harness", "loopback")
    if which not in HARNESSES:
        return err("unknown harness %r; choose: %s" % (which, ", ".join(HARNESSES)))
    rc, out, e = run(["bash", "audio-stack/bridge/test/" + HARNESSES[which]], timeout=600)
    body = out + ("\n" + e if e else "")
    verdict = "SKIP" if "SKIP:" in body else ("PASS" if rc == 0 else "FAIL")
    return (text if rc == 0 else err)("%s: %s\n%s" % (HARNESSES[which], verdict, _tail(body)))


def tool_render(a):
    ex = a.get("example", "dsp_studio")
    frame = int(a.get("frame", 90))
    if ex not in EXAMPLES:
        return err("unknown example %r; choose: %s" % (ex, ", ".join(EXAMPLES)))
    shot = "/tmp/demod_mcp_shot.ppm"
    try:
        os.path.exists(shot) and os.remove(shot)
    except OSError:
        pass
    inner = ("make >/dev/null 2>&1; SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "
             "DEMOD_SHOT=%s DEMOD_SHOT_FRAME=%d timeout 25 ./demod-ui examples/%s.lua"
             % (shot, frame, ex))
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=400)
    if not os.path.exists(shot):
        return err("no frame produced for %s (rc=%d)\n%s" % (ex, rc, _tail(e or out)))
    with open(shot, "rb") as f:
        w, h, rgb = _read_ppm(f.read())
    w, h, rgb = _downscale(w, h, rgb, RENDER_MAX_W)
    png = rgb_to_png(w, h, rgb)
    return {"content": [
        {"type": "text", "text": "rendered examples/%s.lua at frame %d (%dx%d)" % (ex, frame, w, h)},
        {"type": "image", "data": base64.b64encode(png).decode(), "mimeType": "image/png"},
    ]}


def tool_smoke(a):
    ex = a.get("example", "dsp_studio")
    if ex not in EXAMPLES:
        return err("unknown example %r; choose: %s" % (ex, ", ".join(EXAMPLES)))
    inner = ("make >/dev/null 2>&1; SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "
             "DEMOD_SHOT=/tmp/demod_smoke.ppm DEMOD_SHOT_FRAME=60 timeout 15 ./demod-ui examples/%s.lua" % ex)
    rc, out, e = run(["nix", "develop", "--command", "bash", "-c", inner], timeout=300)
    body = (out + "\n" + e)
    bad = [ln for ln in body.splitlines()
           if any(k in ln.lower() for k in ("error", "attempt to", "traceback", "stack traceback"))]
    if rc == 0 and not bad:
        return text("smoke OK: examples/%s.lua ran headless with no Lua errors" % ex)
    return err("smoke FAIL (rc=%d) for %s:\n%s" % (rc, ex, _tail("\n".join(bad) or body)))


def tool_engine_health(a):
    try:
        r = control_request(control_path(a.get("socket")), {"v": 1, "id": "h", "op": "get_health"})
    except Exception as ex:  # noqa: BLE001 — surface any connect/parse failure to the agent
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    return text(json.dumps(r, indent=2))


def tool_engine_list_slots(a):
    try:
        r = control_request(control_path(a.get("socket")), {"v": 1, "id": "s", "op": "list_slots"})
    except Exception as ex:  # noqa: BLE001
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    return text(json.dumps(r, indent=2))


def tool_engine_op(a):
    op = a.get("op", "")
    if op not in ENGINE_OPS:
        return err("op %r not allowed; choose one of: %s" % (op, ", ".join(sorted(ENGINE_OPS))))
    req = {"v": 1, "id": "op", "op": op}
    params = a.get("params") or {}
    if isinstance(params, dict):
        req.update(params)
    try:
        r = control_request(control_path(a.get("socket")), req)
    except Exception as ex:  # noqa: BLE001
        return err("engine unreachable at %s: %s" % (control_path(a.get("socket")), ex))
    out = json.dumps(r, indent=2)
    return err(out) if r.get("ok") is False else text(out)


TOOLS = [
    {"name": "demod_build", "description": "Build a DeMoD component with nix (demod-ui, demod-rt, demod-orchestrator, demod-remote-bridge, dcf-ws-bridge, demod-ui-dcf).",
     "inputSchema": {"type": "object", "properties": {"package": {"type": "string", "enum": PACKAGES}}},
     "_fn": tool_build},
    {"name": "demod_test", "description": "Run a bridge/transport test harness and report PASS/FAIL/SKIP. engine_e2e drives the real orchestrator+demod-rt (self-skips without JACK/RT).",
     "inputSchema": {"type": "object", "properties": {"harness": {"type": "string", "enum": list(HARNESSES)}}},
     "_fn": tool_test},
    {"name": "demod_render", "description": "Render an example UI headless (DEMOD_SHOT) and return a PNG screenshot you can see.",
     "inputSchema": {"type": "object", "properties": {"example": {"type": "string", "enum": EXAMPLES}, "frame": {"type": "integer"}}},
     "_fn": tool_render},
    {"name": "demod_smoke", "description": "Run an example headless for a moment and confirm it boots with no Lua errors.",
     "inputSchema": {"type": "object", "properties": {"example": {"type": "string", "enum": EXAMPLES}}},
     "_fn": tool_smoke},
    {"name": "demod_engine_health", "description": "Query a live orchestrator's get_health over its control socket (demod-rt liveness, callbacks, xruns, children).",
     "inputSchema": {"type": "object", "properties": {"socket": {"type": "string", "description": "control socket path; defaults to $DEMOD_CONTROL_SOCK or /run/demod/control.sock"}}},
     "_fn": tool_engine_health},
    {"name": "demod_engine_list_slots", "description": "List the engine's FX/synth slots (loaded/path/bypassed) over the control socket.",
     "inputSchema": {"type": "object", "properties": {"socket": {"type": "string"}}},
     "_fn": tool_engine_list_slots},
    {"name": "demod_engine_op", "description": "Send one control op to a live engine (set_bpm, set_param, load_fx, bypass_fx, synth.*, set_slot_*). Returns the orchestrator's reply.",
     "inputSchema": {"type": "object",
                     "properties": {"op": {"type": "string", "enum": sorted(ENGINE_OPS)},
                                    "params": {"type": "object", "description": "op args, e.g. {\"bpm\":128} or {\"slot\":0,\"idx\":1,\"value\":0.5}"},
                                    "socket": {"type": "string"}},
                     "required": ["op"]},
     "_fn": tool_engine_op},
]
TOOL_BY_NAME = {t["name"]: t for t in TOOLS}

RESOURCES = [
    {"uri": "demod://skill", "name": "SKILL.md — dm.* Lua API reference",
     "description": "The authoritative dm.* API + 'common mistakes' for writing DeMoD Lua.",
     "mimeType": "text/markdown", "_path": "SKILL.md"},
    {"uri": "demod://control-ops", "name": "Control-socket op vocabulary",
     "description": "The JSON-lines ops the orchestrator accepts.",
     "mimeType": "text/markdown", "_gen": lambda: "# Control-socket ops\n\n" +
     "\n".join("- `%s`" % o for o in sorted(ENGINE_OPS)) +
     "\n\nEnvelope: `{\"v\":1,\"op\":\"<op>\", ...args}`\\n per line over the AF_UNIX socket."},
]


# ── JSON-RPC / MCP dispatch ──────────────────────────────────────────────────
def handle(req):
    method = req.get("method")
    rid = req.get("id")
    if method == "initialize":
        return ok(rid, {"protocolVersion": PROTOCOL_VERSION,
                        "capabilities": {"tools": {}, "resources": {}},
                        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}})
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None  # notification: no response
    if method == "ping":
        return ok(rid, {})
    if method == "tools/list":
        return ok(rid, {"tools": [{k: t[k] for k in ("name", "description", "inputSchema")} for t in TOOLS]})
    if method == "tools/call":
        p = req.get("params") or {}
        name = p.get("name")
        t = TOOL_BY_NAME.get(name)
        if not t:
            return jerr(rid, -32602, "unknown tool: %s" % name)
        try:
            return ok(rid, t["_fn"](p.get("arguments") or {}))
        except Exception as ex:  # noqa: BLE001 — never crash the server on a tool error
            return ok(rid, err("%s failed: %s" % (name, ex)))
    if method == "resources/list":
        return ok(rid, {"resources": [{k: r[k] for k in ("uri", "name", "description", "mimeType")} for r in RESOURCES]})
    if method == "resources/read":
        uri = (req.get("params") or {}).get("uri")
        for r in RESOURCES:
            if r["uri"] == uri:
                body = r["_gen"]() if "_gen" in r else _read_file(r["_path"])
                return ok(rid, {"contents": [{"uri": uri, "mimeType": r["mimeType"], "text": body}]})
        return jerr(rid, -32602, "unknown resource: %s" % uri)
    return jerr(rid, -32601, "method not found: %s" % method)


def _read_file(rel):
    try:
        with open(os.path.join(REPO, rel), "r") as f:
            return f.read()
    except OSError as ex:
        return "(unavailable: %s)" % ex


def ok(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def jerr(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        resp = handle(req)
        if resp is not None:
            out.write(json.dumps(resp) + "\n")
            out.flush()


if __name__ == "__main__":
    main()
