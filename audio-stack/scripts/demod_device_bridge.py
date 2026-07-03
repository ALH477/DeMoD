#!/usr/bin/env python3
"""HTTP bridge between storefront clients and the local DeMoD runtime."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse


DEFAULT_HOST = os.environ.get("DEMOD_DEVICE_BRIDGE_HOST", "127.0.0.1")
DEFAULT_PORT = int(os.environ.get("DEMOD_DEVICE_BRIDGE_PORT", "7635"))
DEFAULT_CONTROL_SOCKET = os.environ.get(
    "DEMOD_CONTROL_SOCKET", "/run/demod/control.sock"
)
DEFAULT_DATA_DIR = os.environ.get("DEMOD_DATA_DIR", "/var/lib/demod")
DEFAULT_LIBRARY_DIR = os.environ.get(
    "DEMOD_LIBRARY_DIR", "/var/lib/demod/library"
)
DEFAULT_QUEUE_DIR = os.environ.get(
    "DEMOD_FAUST_QUEUE_DIR", "/var/lib/demod/market/incoming"
)
DEFAULT_MANIFEST_PATH = os.environ.get("DEMOD_INSTALL_MANIFEST")
DEFAULT_CLIENT_TOKEN_STORE = os.environ.get("DEMOD_DEVICE_BRIDGE_TOKEN_STORE")
DEFAULT_PAIRING_CODE_FILE = os.environ.get("DEMOD_DEVICE_BRIDGE_PAIRING_CODE_FILE")
DEFAULT_EVENT_LOG = os.environ.get("DEMOD_DEVICE_BRIDGE_EVENT_LOG")
DEFAULT_MESH_STATE = os.environ.get("DEMOD_MESH_STATE")
DEFAULT_COMPILER = os.environ.get("DEMOD_FAUST_COMPILE_BIN", "demod-faust-compile")
DEFAULT_MAX_SOURCE_BYTES = int(
    os.environ.get("DEMOD_DEVICE_BRIDGE_MAX_SOURCE_BYTES", str(2 * 1024 * 1024))
)
DEFAULT_COMPILE_TIMEOUT = int(
    os.environ.get("DEMOD_DEVICE_BRIDGE_COMPILE_TIMEOUT_SECONDS", "90")
)
# Browser-reachability defense (CORS + anti-DNS-rebinding). A localhost service is
# reachable by any web page the user visits, and read_json_body() ignores Content-Type
# so a "simple" no-preflight POST is enough to drive install/compile/load. We therefore
# enforce an Origin allowlist + a Host-header allowlist server-side (not just CORS
# headers). Native clients (curl, the desktop autoloader using urllib) send no Origin
# header and are allowed through. Override the lists via env / CLI for LAN/mDNS access.
DEFAULT_CORS_ORIGIN = os.environ.get(
    "DEMOD_DEVICE_BRIDGE_CORS_ORIGIN",
    "tauri://localhost,http://tauri.localhost,https://tauri.localhost,"
    "http://localhost:8080,http://127.0.0.1:8080",
)
DEFAULT_ALLOW_HOSTS = os.environ.get("DEMOD_DEVICE_BRIDGE_ALLOW_HOSTS", "")

# Environment variables stripped before the Faust compile subprocess. The compiler is a
# bash script that invokes faust + cc, so an inherited (tainted) env is a build-time code
# execution surface: the dynamic loader (LD_PRELOAD/LD_AUDIT/LD_LIBRARY_PATH), bash startup
# (BASH_ENV/ENV/BASH_FUNC_*), and gcc flag/search-path vars (CFLAGS/CPATH/LIBRARY_PATH…) all
# let a caller run their own code or link their own libraries. We DENYLIST these rather than
# allowlist, so the Nix cc-wrapper's NIX_* vars (and PATH/HOME/TMPDIR/CC/FAUST/DEMOD_*) still
# reach the toolchain. See SECURITY.md F-15.
COMPILE_ENV_DENYLIST = frozenset({
    # dynamic linker / loader injection
    "LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH", "LD_PROFILE", "LD_DEBUG_OUTPUT",
    "LD_ORIGIN_PATH", "LD_DYNAMIC_WEAK",
    # bash startup-file / parsing injection (the compiler is a bash script)
    "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS", "CDPATH", "GLOBIGNORE",
    "PROMPT_COMMAND", "PS4",
    # gcc/cc flag + search-path injection
    "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LDLIBS", "CPATH", "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "GCC_EXEC_PREFIX", "COMPILER_PATH",
    "DEPENDENCIES_OUTPUT", "SUNPRO_DEPENDENCIES",
    # interpreter module-path injection
    "PYTHONPATH", "PYTHONSTARTUP", "PERL5LIB", "PERLLIB", "RUBYLIB", "NODE_OPTIONS",
})


def sanitized_subprocess_env(overrides: dict[str, str]) -> dict[str, str]:
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in COMPILE_ENV_DENYLIST and not k.startswith("BASH_FUNC_")
    }
    env.update(overrides)
    return env


def is_loopback_host(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def split_csv(raw: str | None) -> list[str]:
    return [item.strip() for item in (raw or "").split(",") if item.strip()]


def header_hostname(host_header: str | None) -> str:
    """The hostname from a Host/Origin authority, minus any port (and IPv6 brackets)."""
    value = (host_header or "").strip()
    if not value:
        return ""
    if value.startswith("["):  # [::1]:7635
        return value[1:].split("]", 1)[0]
    return value.split(":", 1)[0]


def load_token(token: str | None, token_file: str | None) -> str | None:
    if token:
        return token.strip()
    if token_file:
        try:
            return pathlib.Path(token_file).read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return None
    return None


def safe_dsp_name(name: str) -> str:
    leaf = pathlib.PurePath(name).name
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", leaf).strip(".")
    if not cleaned:
        raise ValueError("fileName is empty after sanitization")
    if not cleaned.endswith(".dsp"):
        cleaned = f"{cleaned}.dsp"
    return cleaned


def unique_path(directory: pathlib.Path, file_name: str) -> pathlib.Path:
    candidate = directory / file_name
    if not candidate.exists():
        return candidate
    stem = pathlib.Path(file_name).stem
    suffix = pathlib.Path(file_name).suffix
    stamp = int(time.time())
    return directory / f"{stem}-{stamp}{suffix}"


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_json_body(
    handler: BaseHTTPRequestHandler, max_source_bytes: int
) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        return {}
    if length > max_source_bytes + 65536:
        raise ValueError("request body is too large")
    raw = handler.rfile.read(length)
    try:
        value = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("request body must be a JSON object")
    return value


def control_request(socket_path: str, request: dict[str, Any]) -> dict[str, Any]:
    encoded = json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(socket_path)
        sock.sendall(encoded)
        with sock.makefile("rb") as fh:
            line = fh.readline(DEFAULT_MAX_SOURCE_BYTES)
    if not line:
        raise RuntimeError("control socket returned an empty response")
    response = json.loads(line.decode("utf-8"))
    if not isinstance(response, dict):
        raise RuntimeError("control socket returned a non-object response")
    return response


def ok_response(request_id: str, data: dict[str, Any]) -> dict[str, Any]:
    return {"v": 1, "id": request_id, "ok": True, "data": data}


def err_response(request_id: str, message: str) -> dict[str, Any]:
    return {"v": 1, "id": request_id, "ok": False, "err": message}


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_sha256(expected: Any, data: bytes) -> str:
    actual = sha256_hex(data)
    if expected is None:
        return actual
    if not isinstance(expected, str):
        raise ValueError("sha256 must be a string")
    normalized = expected.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise ValueError("sha256 must be a 64-character hex digest")
    if normalized != actual:
        raise ValueError("sha256 mismatch")
    return actual


def token_hash(token: str) -> str:
    return sha256_hex(token.encode("utf-8"))


def public_client_record(record: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in record.items()
        if key not in {"tokenHash"} and value is not None
    }


def decode_source_from_body(body: dict[str, Any]) -> str:
    source = body.get("source")
    if source is not None:
        if not isinstance(source, str) or not source:
            raise ValueError("source must be a non-empty string")
        return source

    encoded = body.get("bytesBase64")
    if not isinstance(encoded, str) or not encoded:
        raise ValueError("source or bytesBase64 is required for faust-source install")
    try:
        return base64.b64decode(encoded, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError) as exc:
        raise ValueError("bytesBase64 must contain UTF-8 Faust source") from exc


def optional_target_slot(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("targetSlot must be an integer")
    if value < 0:
        raise ValueError("targetSlot must be >= 0")
    return value


class InstallManifest:
    """Small JSON manifest for storefront-visible install state."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.lock = threading.Lock()

    def empty(self) -> dict[str, Any]:
        return {
            "v": 1,
            "updatedAt": utc_now(),
            "artifacts": [],
        }

    def read(self) -> dict[str, Any]:
        with self.lock:
            return self._read_unlocked()

    def upsert(self, record_id: str, updates: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            manifest = self._read_unlocked()
            artifacts = manifest.setdefault("artifacts", [])
            if not isinstance(artifacts, list):
                artifacts = []
                manifest["artifacts"] = artifacts

            record = None
            for item in artifacts:
                if isinstance(item, dict) and item.get("id") == record_id:
                    record = item
                    break

            now = utc_now()
            if record is None:
                record = {"id": record_id, "installedAt": now}
                artifacts.append(record)

            record.update(updates)
            record["updatedAt"] = now
            manifest["updatedAt"] = now
            self._write_unlocked(manifest)
            return record

    def mark_loaded(self, library_path: str, slot: int) -> dict[str, Any] | None:
        with self.lock:
            manifest = self._read_unlocked()
            changed: dict[str, Any] | None = None
            now = utc_now()
            for item in manifest.get("artifacts", []):
                if not isinstance(item, dict):
                    continue
                if item.get("libraryPath") != library_path:
                    continue
                item.update(
                    {
                        "loaded": True,
                        "targetSlot": slot,
                        "status": "loaded",
                        "updatedAt": now,
                    }
                )
                changed = item
            if changed is not None:
                manifest["updatedAt"] = now
                self._write_unlocked(manifest)
            return changed

    def mark_unloaded(self, slot: int) -> None:
        with self.lock:
            manifest = self._read_unlocked()
            changed = False
            now = utc_now()
            for item in manifest.get("artifacts", []):
                if not isinstance(item, dict):
                    continue
                if item.get("targetSlot") != slot or not item.get("loaded"):
                    continue
                item.update(
                    {
                        "loaded": False,
                        "status": "compiled" if item.get("libraryPath") else "queued",
                        "updatedAt": now,
                    }
                )
                changed = True
            if changed:
                manifest["updatedAt"] = now
                self._write_unlocked(manifest)

    def _read_unlocked(self) -> dict[str, Any]:
        if not self.path.exists():
            return self.empty()
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            value = self.empty()
            value["warning"] = "previous manifest was unreadable and was ignored"
            return value
        if not isinstance(value, dict):
            return self.empty()
        value.setdefault("v", 1)
        value.setdefault("updatedAt", utc_now())
        value.setdefault("artifacts", [])
        return value

    def _write_unlocked(self, manifest: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_suffix(f"{self.path.suffix}.tmp")
        tmp_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        tmp_path.replace(self.path)


class MeshState:
    """HydraMesh peer state, written as a small JSON status file the on-device UI
    reads live (peerCount/linked) and served over HTTP for the companion. The
    HydraMesh daemon POSTs peer updates; the bridge owns the file + API."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.lock = threading.Lock()

    def empty(self) -> dict[str, Any]:
        return {"v": 1, "updatedAt": utc_now(), "linked": False, "peerCount": 0, "peers": []}

    def read(self) -> dict[str, Any]:
        with self.lock:
            return self._read_unlocked()

    def update(self, peers: list[Any], self_id: str | None = None) -> dict[str, Any]:
        with self.lock:
            clean: list[dict[str, Any]] = []
            for p in peers or []:
                if isinstance(p, dict) and p.get("id"):
                    clean.append({
                        "id": str(p["id"])[:64],
                        "name": str(p.get("name", "peer"))[:64],
                        "rssi": p.get("rssi"),
                        "since": str(p.get("since") or utc_now()),
                    })
            state = {
                "v": 1,
                "updatedAt": utc_now(),
                "linked": len(clean) > 0,
                "peerCount": len(clean),
                "peers": clean,
            }
            if self_id:
                state["selfId"] = str(self_id)[:64]
            self._write_unlocked(state)
            return state

    def ensure_file(self) -> None:
        with self.lock:
            if not self.path.exists():
                self._write_unlocked(self.empty())

    def _read_unlocked(self) -> dict[str, Any]:
        if not self.path.exists():
            return self.empty()
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return self.empty()
        if not isinstance(value, dict):
            return self.empty()
        value.setdefault("v", 1)
        value.setdefault("peerCount", 0)
        value.setdefault("linked", False)
        value.setdefault("peers", [])
        return value

    def _write_unlocked(self, state: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_suffix(f"{self.path.suffix}.tmp")
        tmp_path.write_text(
            json.dumps(state, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        tmp_path.replace(self.path)


class ClientTokenStore:
    """Revocable per-client bearer tokens for paired bridge clients."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.lock = threading.Lock()

    def ensure_parent(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def empty(self) -> dict[str, Any]:
        return {
            "v": 1,
            "updatedAt": utc_now(),
            "clients": [],
        }

    def list_public(self) -> list[dict[str, Any]]:
        with self.lock:
            store = self._read_unlocked()
            return [
                public_client_record(client)
                for client in store.get("clients", [])
                if isinstance(client, dict)
            ]

    def active_count(self) -> int:
        return sum(1 for item in self.list_public() if not item.get("revokedAt"))

    def issue(self, client_name: str | None) -> dict[str, Any]:
        name = (client_name or "Paired client").strip()[:80] or "Paired client"
        token = "demod_" + secrets.token_urlsafe(32)
        now = utc_now()
        record = {
            "id": "client_" + secrets.token_urlsafe(12),
            "name": name,
            "tokenHash": token_hash(token),
            "createdAt": now,
            "lastUsedAt": None,
            "revokedAt": None,
        }
        with self.lock:
            store = self._read_unlocked()
            clients = store.setdefault("clients", [])
            if not isinstance(clients, list):
                clients = []
                store["clients"] = clients
            clients.append(record)
            store["updatedAt"] = now
            self._write_unlocked(store)
        return {
            "client": public_client_record(record),
            "token": token,
        }

    def validate(self, token: str) -> bool:
        digest = token_hash(token)
        with self.lock:
            store = self._read_unlocked()
            changed = False
            now = utc_now()
            for client in store.get("clients", []):
                if not isinstance(client, dict) or client.get("revokedAt"):
                    continue
                expected = client.get("tokenHash")
                if isinstance(expected, str) and hmac.compare_digest(expected, digest):
                    client["lastUsedAt"] = now
                    store["updatedAt"] = now
                    changed = True
                    break
            else:
                return False
            if changed:
                self._write_unlocked(store)
            return True

    def revoke(self, client_id: str) -> dict[str, Any] | None:
        with self.lock:
            store = self._read_unlocked()
            now = utc_now()
            for client in store.get("clients", []):
                if not isinstance(client, dict) or client.get("id") != client_id:
                    continue
                client["revokedAt"] = now
                store["updatedAt"] = now
                self._write_unlocked(store)
                return public_client_record(client)
        return None

    def _read_unlocked(self) -> dict[str, Any]:
        if not self.path.exists():
            return self.empty()
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            value = self.empty()
            value["warning"] = "previous token store was unreadable and ignored"
            return value
        if not isinstance(value, dict):
            return self.empty()
        value.setdefault("v", 1)
        value.setdefault("updatedAt", utc_now())
        value.setdefault("clients", [])
        return value

    def _write_unlocked(self, store: dict[str, Any]) -> None:
        self.ensure_parent()
        tmp_path = self.path.with_suffix(f"{self.path.suffix}.tmp")
        tmp_path.write_text(
            json.dumps(store, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.chmod(tmp_path, 0o600)
        tmp_path.replace(self.path)


class EventLog:
    """Small bounded event log for progress polling and SSE snapshots."""

    def __init__(self, path: pathlib.Path, max_events: int = 500) -> None:
        self.path = path
        self.max_events = max_events
        self.lock = threading.Lock()

    def ensure_parent(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def empty(self) -> dict[str, Any]:
        return {
            "v": 1,
            "updatedAt": utc_now(),
            "nextSeq": 1,
            "events": [],
        }

    def append(self, event_type: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.lock:
            store = self._read_unlocked()
            events = store.setdefault("events", [])
            if not isinstance(events, list):
                events = []
                store["events"] = events
            seq = store.get("nextSeq")
            if not isinstance(seq, int) or seq < 1:
                seq = 1
            event = {
                "seq": seq,
                "ts": utc_now(),
                "type": event_type,
                "data": data or {},
            }
            events.append(event)
            if len(events) > self.max_events:
                del events[0 : len(events) - self.max_events]
            store["nextSeq"] = seq + 1
            store["updatedAt"] = event["ts"]
            self._write_unlocked(store)
            return event

    def read(self, since: int = 0, limit: int = 100) -> dict[str, Any]:
        with self.lock:
            store = self._read_unlocked()
            events = [
                event
                for event in store.get("events", [])
                if isinstance(event, dict)
                and isinstance(event.get("seq"), int)
                and event["seq"] > since
            ]
            limit = max(1, min(limit, self.max_events))
            return {
                "v": 1,
                "updatedAt": store.get("updatedAt", utc_now()),
                "nextSeq": store.get("nextSeq", 1),
                "events": events[-limit:],
            }

    def _read_unlocked(self) -> dict[str, Any]:
        if not self.path.exists():
            return self.empty()
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            value = self.empty()
            value["warning"] = "previous event log was unreadable and ignored"
            return value
        if not isinstance(value, dict):
            return self.empty()
        value.setdefault("v", 1)
        value.setdefault("updatedAt", utc_now())
        value.setdefault("nextSeq", 1)
        value.setdefault("events", [])
        return value

    def _write_unlocked(self, store: dict[str, Any]) -> None:
        self.ensure_parent()
        tmp_path = self.path.with_suffix(f"{self.path.suffix}.tmp")
        tmp_path.write_text(
            json.dumps(store, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        tmp_path.replace(self.path)


class PairingCodeStore:
    """Short-lived physical pairing code file consumed by new clients."""

    def __init__(self, path: pathlib.Path | None) -> None:
        self.path = path
        self.lock = threading.Lock()

    def status(self) -> dict[str, Any]:
        payload = self._read()
        active = self._is_active(payload)
        return {
            "configured": self.path is not None,
            "active": active,
            "expiresAt": payload.get("expiresAt") if active else None,
            "oneTime": True,
        }

    def claim(self, code: str) -> bool:
        if not code or self.path is None:
            return False
        with self.lock:
            payload = self._read()
            if not self._is_active(payload):
                return False
            if not self._matches(payload, code.strip()):
                return False
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass
            return True

    def _read(self) -> dict[str, Any]:
        if self.path is None or not self.path.exists():
            return {}
        raw = self.path.read_text(encoding="utf-8").strip()
        if not raw:
            return {}
        if raw.startswith("{"):
            try:
                value = json.loads(raw)
            except json.JSONDecodeError:
                return {}
            return value if isinstance(value, dict) else {}
        return {"code": raw}

    def _is_active(self, payload: dict[str, Any]) -> bool:
        if not payload:
            return False
        expires_at_epoch = payload.get("expiresAtEpoch")
        if isinstance(expires_at_epoch, (int, float)) and time.time() > expires_at_epoch:
            return False
        return bool(payload.get("code") or payload.get("codeHash"))

    def _matches(self, payload: dict[str, Any], code: str) -> bool:
        stored_code = payload.get("code")
        if isinstance(stored_code, str):
            return hmac.compare_digest(stored_code.strip(), code)
        stored_hash = payload.get("codeHash")
        if isinstance(stored_hash, str):
            return hmac.compare_digest(stored_hash, token_hash(code))
        return False


class BridgeState:
    def __init__(self, args: argparse.Namespace, token: str | None) -> None:
        self.control_socket = args.control_socket
        self.data_dir = pathlib.Path(args.data_dir)
        self.library_dir = pathlib.Path(args.library_dir)
        self.queue_dir = pathlib.Path(args.faust_queue_dir)
        self.bridge_source_dir = self.data_dir / "faust" / "bridge"
        manifest_path = args.install_manifest or DEFAULT_MANIFEST_PATH
        self.manifest = InstallManifest(
            pathlib.Path(manifest_path)
            if manifest_path
            else self.data_dir / "market" / "install-manifest.json"
        )
        token_store_path = args.client_token_store or DEFAULT_CLIENT_TOKEN_STORE
        self.client_tokens = ClientTokenStore(
            pathlib.Path(token_store_path)
            if token_store_path
            else self.data_dir / "market" / "client-tokens.json"
        )
        event_log_path = args.event_log or DEFAULT_EVENT_LOG
        self.events = EventLog(
            pathlib.Path(event_log_path)
            if event_log_path
            else self.data_dir / "market" / "events.json"
        )
        pairing_code_path = args.pairing_code_file or DEFAULT_PAIRING_CODE_FILE
        self.pairing_codes = PairingCodeStore(
            pathlib.Path(pairing_code_path) if pairing_code_path else None
        )
        mesh_state_path = getattr(args, "mesh_state", None) or DEFAULT_MESH_STATE
        self.mesh = MeshState(
            pathlib.Path(mesh_state_path) if mesh_state_path else self.data_dir / "mesh.json"
        )
        self.compiler = args.faust_compiler
        self.compile_timeout = args.compile_timeout
        self.max_source_bytes = args.max_source_bytes
        self.token = token
        self.host = args.host
        self.cors_origins = split_csv(args.cors_origin)
        self.cors_allow_all = "*" in self.cors_origins
        # Host-header allowlist (anti-DNS-rebinding): loopback names + the bind address +
        # any operator-configured hostnames (e.g. demod.local for mDNS LAN access).
        self.allowed_hostnames = {"127.0.0.1", "::1", "localhost"}
        bind_host = header_hostname(args.host)
        if bind_host:
            self.allowed_hostnames.add(bind_host)
        self.allowed_hostnames.update(
            header_hostname(h) for h in split_csv(getattr(args, "allow_hosts", "") or "")
        )
        self.require_auth = bool(token) or not is_loopback_host(args.host)
        # D4: device identity for entitlement binding (/etc/machine-id or persisted UUID).
        # Matches the desktop derivation in scripts/demod-desktop.sh.
        self.device_id: str = ""
        _did = os.environ.get("DEMOD_DEVICE_ID", "").strip()
        if not _did:
            for _mp in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
                try:
                    _did = pathlib.Path(_mp).read_text().strip()
                    if _did:
                        break
                except OSError:
                    pass
        if not _did:
            _config_dir = pathlib.Path(os.environ.get("DEMOD_CONFIG", "") or pathlib.Path.home() / ".config" / "demod")
            _did_path = _config_dir / "device-id"
            try:
                _did = _did_path.read_text().strip()
            except OSError:
                pass
        if not _did:
            import uuid as _uuid
            _did = _uuid.uuid4().hex
            try:
                _did_path.parent.mkdir(parents=True, exist_ok=True)
                _did_path.write_text(_did)
            except OSError:
                pass
        self.device_id = _did
        # Install-link anti-spam (in-memory): single-use jti replay cache + a sliding-window
        # rate limit on installs per client IP. The signed deep-link is verified client-side;
        # the bridge caps abuse of the install endpoint. Dep-free (no crypto needed here).
        self._seen_jti: dict[str, float] = {}
        self._install_events: dict[str, list[float]] = {}              # per-IP event lists (D8b)
        self._install_rate_max = int(os.environ.get("DEMOD_INSTALL_RATE_MAX", "20"))
        self._install_rate_window = float(os.environ.get("DEMOD_INSTALL_RATE_WINDOW", "60"))
        self._jti_ttl = float(os.environ.get("DEMOD_INSTALL_JTI_TTL", "900"))  # 15 min

    def note_install_jti(self, jti: str | None) -> None:
        """Record a single-use install-link jti; raise on replay. No-op if jti is absent."""
        if jti is None:
            return
        if not isinstance(jti, str) or not jti or len(jti) > 128:
            raise ValueError("invalid jti")
        now = time.time()
        self._seen_jti = {k: v for k, v in self._seen_jti.items() if v > now}
        if jti in self._seen_jti:
            raise ValueError("install link already used")
        self._seen_jti[jti] = now + self._jti_ttl

    def install_rate_ok(self, client_ip: str = "") -> bool:
        """Sliding-window rate limit on installs per client IP; True if under the cap."""
        now = time.time()
        key = client_ip or "unknown"
        events = self._install_events.get(key, [])
        events = [t for t in events if t > now - self._install_rate_window]
        if len(events) >= self._install_rate_max:
            self._install_events[key] = events
            return False
        events.append(now)
        self._install_events[key] = events
        return True

    def is_origin_allowed(self, origin: str | None) -> bool:
        if origin is None:
            return True  # native client (curl / autoloader): no browser context
        if self.cors_allow_all:
            return True
        return origin in self.cors_origins

    def cors_value_for(self, origin: str | None) -> str | None:
        if self.cors_allow_all:
            return "*"
        if origin and origin in self.cors_origins:
            return origin
        return None

    def is_host_allowed(self, host_header: str | None) -> bool:
        # An empty Host is HTTP/1.0 / a non-browser tool; allow it (Origin guard still
        # applies). A DNS-rebinding attack arrives with the attacker's hostname here.
        hostname = header_hostname(host_header)
        if not hostname:
            return True
        return hostname in self.allowed_hostnames

    def ensure_dirs(self) -> None:
        self.library_dir.mkdir(parents=True, exist_ok=True)
        self.queue_dir.mkdir(parents=True, exist_ok=True)
        self.bridge_source_dir.mkdir(parents=True, exist_ok=True)
        self.manifest.path.parent.mkdir(parents=True, exist_ok=True)
        self.client_tokens.ensure_parent()
        self.events.ensure_parent()
        self.mesh.ensure_file()

    def capabilities(self) -> dict[str, Any]:
        return {
            "bridgeVersion": "0.2",
            "protocolVersion": 1,
            "deviceId": self.device_id,
            "controlSocket": self.control_socket,
            "libraryDir": str(self.library_dir),
            "faustQueueDir": str(self.queue_dir),
            "installManifest": str(self.manifest.path),
            "clientTokenStore": str(self.client_tokens.path),
            "eventLog": str(self.events.path),
            "meshState": str(self.mesh.path),
            "maxSourceBytes": self.max_source_bytes,
            "auth": {
                "required": self.require_auth,
                "bootstrapTokenConfigured": bool(self.token),
                "pairedClientCount": self.client_tokens.active_count(),
                "pairing": self.pairing_codes.status(),
            },
            "artifactKinds": {
                "faust-source": {
                    "install": True,
                    "compileOnDevice": True,
                    "loadIntoRtSlot": True,
                },
                "faust-library": {
                    "install": False,
                    "compileOnDevice": False,
                    "loadIntoRtSlot": False,
                },
                "vst3-bundle": {
                    "install": False,
                    "compileOnDevice": False,
                    "loadIntoRtSlot": False,
                },
                "clap-plugin": {
                    "install": False,
                    "compileOnDevice": False,
                    "loadIntoRtSlot": False,
                },
                "sample-pack": {
                    "install": False,
                    "compileOnDevice": False,
                    "loadIntoRtSlot": False,
                },
            },
            "endpoints": [
                "GET /v1/capabilities",
                "GET /v1/health",
                "GET /v1/slots",
                "GET /v1/effects/manifest",
                "GET /v1/events",
                "GET /v1/events/stream",
                "GET /v1/mesh",
                "GET /v1/pairing/status",
                "GET /v1/pairing/tokens",
                "POST /v1/control",
                "POST /v1/mesh",
                "POST /v1/effects/faust",
                "POST /v1/effects/install",
                "POST /v1/entitlement",
                "POST /v1/pairing/claim",
                "POST /v1/pairing/tokens",
                "POST /v1/slots/:slot/load",
                "DELETE /v1/pairing/tokens/:clientId",
                "DELETE /v1/slots/:slot",
            ],
        }

    def pairing_status(self) -> dict[str, Any]:
        return {
            "authRequired": self.require_auth,
            "bootstrapTokenConfigured": bool(self.token),
            "pairedClientCount": self.client_tokens.active_count(),
            "pairing": self.pairing_codes.status(),
        }

    def emit_event(self, event_type: str, **data: Any) -> dict[str, Any]:
        return self.events.append(event_type, data)

    def queue_source(self, file_name: str, source: str) -> dict[str, Any]:
        data = source.encode("utf-8")
        if len(data) > self.max_source_bytes:
            raise ValueError(
                f"Faust source exceeds {self.max_source_bytes} byte limit"
            )
        safe_name = safe_dsp_name(file_name)
        target = unique_path(self.queue_dir, safe_name)
        target.write_bytes(data)
        return {
            "path": str(target),
            "file_name": target.name,
            "bytes": len(data),
            "sha256": sha256_hex(data),
        }

    def compile_source(
        self, file_name: str, source: str, target_slot: int | None, load: bool
    ) -> dict[str, Any]:
        data = source.encode("utf-8")
        if len(data) > self.max_source_bytes:
            raise ValueError(
                f"Faust source exceeds {self.max_source_bytes} byte limit"
            )
        safe_name = safe_dsp_name(file_name)
        source_path = unique_path(self.bridge_source_dir, safe_name)
        source_path.write_bytes(data)
        library_path = self.library_dir / f"{source_path.stem}.so"

        compiler = shutil.which(self.compiler) or self.compiler
        env = sanitized_subprocess_env({
            "DEMOD_DATA_DIR": str(self.data_dir),
            "DEMOD_LIBRARY_DIR": str(self.library_dir),
            "DEMOD_FAUST_QUEUE_DIR": str(self.queue_dir),
        })
        result = subprocess.run(
            [compiler, "--source", str(source_path)],
            env=env,
            capture_output=True,
            text=True,
            timeout=self.compile_timeout,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(
                "Faust compile failed: "
                + (result.stderr.strip() or result.stdout.strip() or "unknown error")
            )
        if not library_path.exists():
            raise RuntimeError(f"compiler did not produce {library_path}")

        payload: dict[str, Any] = {
            "queued": {
                "path": str(source_path),
                "file_name": source_path.name,
                "bytes": len(data),
                "sha256": sha256_hex(data),
            },
            "libraryPath": str(library_path),
            "targetSlot": target_slot,
            "loaded": False,
        }
        if load:
            if target_slot is None:
                raise ValueError("loadAfterCompile requires targetSlot")
            load_response = control_request(
                self.control_socket,
                {
                    "v": 1,
                    "id": "bridge-load-after-compile",
                    "op": "load_fx",
                    "slot": target_slot,
                    "path": str(library_path),
                },
            )
            if not load_response.get("ok"):
                raise RuntimeError(load_response.get("err", "load_fx failed"))
            payload["loaded"] = True
            payload["loadResponse"] = load_response.get("data")
        return payload

    def artifact_record_id(
        self, body: dict[str, Any], kind: str, safe_file_name: str
    ) -> str:
        artifact_id = body.get("artifactId")
        product_id = body.get("productId")
        if isinstance(artifact_id, str) and artifact_id:
            return artifact_id
        if isinstance(product_id, str) and product_id:
            return f"{product_id}:{safe_file_name}"
        return f"{kind}:{safe_file_name}"

    def manifest_updates(
        self,
        body: dict[str, Any],
        kind: str,
        safe_file_name: str,
        status: str,
        source_sha256: str,
        source_bytes: int,
        target_slot: int | None,
        loaded: bool,
        queued: dict[str, Any] | None = None,
        library_path: str | None = None,
        error: str | None = None,
    ) -> dict[str, Any]:
        product_id = body.get("productId")
        artifact_id = body.get("artifactId")
        updates: dict[str, Any] = {
            "kind": kind,
            "fileName": safe_file_name,
            "status": status,
            "sha256": source_sha256,
            "bytes": source_bytes,
            "targetSlot": target_slot,
            "loaded": loaded,
            "lastError": error,
        }
        if isinstance(product_id, str) and product_id:
            updates["productId"] = product_id
        if isinstance(artifact_id, str) and artifact_id:
            updates["artifactId"] = artifact_id
        if queued:
            updates["sourcePath"] = queued.get("path")
        if library_path:
            updates["libraryPath"] = library_path
        return updates


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "demod-device-bridge/0.1"

    @property
    def state(self) -> BridgeState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[device-bridge] " + fmt % args + "\n")

    def end_headers(self) -> None:
        allow_origin = self.state.cors_value_for(self.headers.get("Origin"))
        if allow_origin is not None:
            self.send_header("Access-Control-Allow-Origin", allow_origin)
        self.send_header("Vary", "Origin")
        self.send_header(
            "Access-Control-Allow-Headers",
            "authorization,content-type,x-demod-token",
        )
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def browser_guard_failed(self) -> bool:
        """Reject browser-originated cross-site requests and DNS-rebinding before any
        endpoint logic runs. Native clients (no Origin header) pass through. See F-1/F-2
        in unified-UI/SECURITY.md."""
        if not self.state.is_host_allowed(self.headers.get("Host")):
            self.send_json(403, err_response("", "forbidden_host"))
            return True
        if not self.state.is_origin_allowed(self.headers.get("Origin")):
            self.send_json(403, err_response("", "forbidden_origin"))
            return True
        return False

    def request_token(self) -> str | None:
        bearer = self.headers.get("Authorization", "")
        if bearer.startswith("Bearer "):
            return bearer.removeprefix("Bearer ").strip()
        header_token = self.headers.get("X-Demod-Token", "")
        return header_token.strip() or None

    def authorized(self) -> bool:
        if not self.state.require_auth and not self.state.token:
            return True
        candidate = self.request_token()
        if not candidate:
            return False
        if self.state.token and hmac.compare_digest(candidate, self.state.token):
            return True
        return self.state.client_tokens.validate(candidate)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def send_sse_snapshot(self, payload: dict[str, Any]) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in payload.get("events", []):
            event_name = str(event.get("type", "message"))
            event_id = str(event.get("seq", ""))
            data = json.dumps(event, separators=(",", ":"))
            self.wfile.write(f"id: {event_id}\n".encode("utf-8"))
            self.wfile.write(f"event: {event_name}\n".encode("utf-8"))
            self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
        self.wfile.flush()

    def event_query(self) -> dict[str, int]:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        try:
            since = int(query.get("since", ["0"])[0])
        except ValueError:
            since = 0
        try:
            limit = int(query.get("limit", ["100"])[0])
        except ValueError:
            limit = 100
        return {"since": max(0, since), "limit": max(1, limit)}

    def reject_if_unauthorized(self) -> bool:
        if self.authorized():
            return False
        self.send_json(401, err_response("", "unauthorized"))
        return True

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.browser_guard_failed():
            return
        path = urlparse(self.path).path
        try:
            if path == "/v1/pairing/status":
                self.send_json(
                    200,
                    ok_response("bridge-pairing-status", self.state.pairing_status()),
                )
                return

            if self.reject_if_unauthorized():
                return

            if path == "/v1/capabilities":
                self.send_json(
                    200,
                    ok_response("bridge-capabilities", self.state.capabilities()),
                )
                return
            if path == "/v1/health":
                response = control_request(
                    self.state.control_socket,
                    {"v": 1, "id": "bridge-health", "op": "get_health"},
                )
                self.send_json(200, response)
                return
            if path == "/v1/slots":
                response = control_request(
                    self.state.control_socket,
                    {"v": 1, "id": "bridge-slots", "op": "list_slots"},
                )
                self.send_json(200, response)
                return
            if path == "/v1/effects/manifest":
                self.send_json(
                    200,
                    ok_response("bridge-manifest", self.state.manifest.read()),
                )
                return
            if path == "/v1/mesh":
                self.send_json(200, ok_response("bridge-mesh", self.state.mesh.read()))
                return
            if path == "/v1/events":
                event_query = self.event_query()
                self.send_json(
                    200,
                    ok_response(
                        "bridge-events",
                        self.state.events.read(
                            since=event_query["since"],
                            limit=event_query["limit"],
                        ),
                    ),
                )
                return
            if path == "/v1/events/stream":
                event_query = self.event_query()
                self.send_sse_snapshot(
                    self.state.events.read(
                        since=event_query["since"],
                        limit=event_query["limit"],
                    )
                )
                return
            if path == "/v1/pairing/tokens":
                self.send_json(
                    200,
                    ok_response(
                        "bridge-pairing-tokens",
                        {"clients": self.state.client_tokens.list_public()},
                    ),
                )
                return
            self.send_json(404, err_response("", "not found"))
        except Exception as exc:  # noqa: BLE001
            self.send_json(502, err_response("", str(exc)))

    def do_POST(self) -> None:  # noqa: N802
        if self.browser_guard_failed():
            return
        path = urlparse(self.path).path
        try:
            body = read_json_body(self, self.state.max_source_bytes)
            if path == "/v1/pairing/claim":
                self.handle_pairing_claim(body)
                return

            if self.reject_if_unauthorized():
                return

            if path == "/v1/pairing/tokens":
                self.handle_pairing_token_issue(body)
                return
            if path == "/v1/control":
                response = control_request(self.state.control_socket, body)
                self.update_manifest_from_control(body, response)
                self.send_json(200, response)
                return
            if path == "/v1/effects/faust":
                self.handle_faust(body)
                return
            if path == "/v1/effects/install":
                self.handle_install(body)
                return
            if path == "/v1/mesh":
                peers = body.get("peers")
                if not isinstance(peers, list):
                    raise ValueError("peers (list) is required")
                state = self.state.mesh.update(peers, body.get("selfId"))
                self.state.emit_event("mesh.updated", peerCount=state["peerCount"])
                self.send_json(200, ok_response("bridge-mesh", state))
                return
            if path == "/v1/entitlement":
                self.handle_entitlement(body)
                return
            slot_match = re.fullmatch(r"/v1/slots/([0-9]+)/load", path)
            if slot_match:
                slot = int(slot_match.group(1))
                fx_path = body.get("path")
                if not isinstance(fx_path, str) or not fx_path:
                    raise ValueError("path is required")
                response = control_request(
                    self.state.control_socket,
                    {
                        "v": 1,
                        "id": "bridge-load-slot",
                        "op": "load_fx",
                        "slot": slot,
                        "path": fx_path,
                    },
                )
                if response.get("ok"):
                    self.state.manifest.mark_loaded(fx_path, slot)
                    self.state.emit_event(
                        "effect.loaded",
                        slot=slot,
                        path=fx_path,
                        source="slot-endpoint",
                    )
                self.send_json(200, response)
                return
            self.send_json(404, err_response("", "not found"))
        except ValueError as exc:
            self.send_json(400, err_response("", str(exc)))
        except Exception as exc:  # noqa: BLE001
            self.send_json(502, err_response("", str(exc)))

    def do_DELETE(self) -> None:  # noqa: N802
        if self.browser_guard_failed():
            return
        if self.reject_if_unauthorized():
            return
        path = urlparse(self.path).path
        try:
            token_match = re.fullmatch(r"/v1/pairing/tokens/([A-Za-z0-9_-]+)", path)
            if token_match:
                revoked = self.state.client_tokens.revoke(token_match.group(1))
                if revoked is None:
                    self.send_json(404, err_response("bridge-revoke-token", "not found"))
                    return
                self.state.emit_event(
                    "pairing.token_revoked",
                    client=revoked,
                )
                self.send_json(
                    200,
                    ok_response("bridge-revoke-token", {"client": revoked}),
                )
                return

            slot_match = re.fullmatch(r"/v1/slots/([0-9]+)", path)
            if not slot_match:
                self.send_json(404, err_response("", "not found"))
                return
            response = control_request(
                self.state.control_socket,
                {
                    "v": 1,
                    "id": "bridge-unload-slot",
                    "op": "unload_fx",
                    "slot": int(slot_match.group(1)),
                },
            )
            if response.get("ok"):
                self.state.manifest.mark_unloaded(int(slot_match.group(1)))
                self.state.emit_event(
                    "effect.unloaded",
                    slot=int(slot_match.group(1)),
                    source="slot-endpoint",
                )
            self.send_json(200, response)
        except Exception as exc:  # noqa: BLE001
            self.send_json(502, err_response("", str(exc)))

    def handle_pairing_claim(self, body: dict[str, Any]) -> None:
        code = body.get("pairingCode")
        if not isinstance(code, str) or not code.strip():
            raise ValueError("pairingCode is required")
        if not self.state.pairing_codes.claim(code):
            self.send_json(403, err_response("bridge-pairing-claim", "invalid pairing code"))
            return
        client_name = body.get("clientName")
        issued = self.state.client_tokens.issue(
            client_name if isinstance(client_name, str) else None
        )
        self.state.emit_event(
            "pairing.claimed",
            client=issued["client"],
        )
        self.send_json(201, ok_response("bridge-pairing-claim", issued))

    def handle_pairing_token_issue(self, body: dict[str, Any]) -> None:
        client_name = body.get("clientName")
        issued = self.state.client_tokens.issue(
            client_name if isinstance(client_name, str) else None
        )
        self.state.emit_event(
            "pairing.token_issued",
            client=issued["client"],
        )
        self.send_json(201, ok_response("bridge-pairing-token", issued))

    def update_manifest_from_control(
        self, request: dict[str, Any], response: dict[str, Any]
    ) -> None:
        if not response.get("ok"):
            return
        op = request.get("op")
        if op == "load_fx":
            slot = request.get("slot")
            fx_path = request.get("path")
            if isinstance(slot, int) and isinstance(fx_path, str):
                self.state.manifest.mark_loaded(fx_path, slot)
                self.state.emit_event(
                    "effect.loaded",
                    slot=slot,
                    path=fx_path,
                    source="control-proxy",
                )
        if op == "unload_fx":
            slot = request.get("slot")
            if isinstance(slot, int):
                self.state.manifest.mark_unloaded(slot)
                self.state.emit_event(
                    "effect.unloaded",
                    slot=slot,
                    source="control-proxy",
                )

    def handle_faust(self, body: dict[str, Any]) -> None:
        file_name = body.get("fileName")
        source = body.get("source")
        if not isinstance(file_name, str) or not file_name:
            raise ValueError("fileName is required")
        if not isinstance(source, str) or not source:
            raise ValueError("source is required")
        source_bytes = source.encode("utf-8")
        source_sha256 = verify_sha256(body.get("sha256"), source_bytes)
        safe_name = safe_dsp_name(file_name)
        record_id = self.state.artifact_record_id(body, "faust-source", safe_name)
        target_slot = optional_target_slot(body.get("targetSlot"))
        load_after = bool(body.get("loadAfterCompile", False))
        compile_now = load_after or bool(body.get("compileNow", False))

        if compile_now:
            self.state.emit_event(
                "effect.compile_started",
                artifactId=body.get("artifactId"),
                productId=body.get("productId"),
                fileName=safe_name,
                targetSlot=target_slot,
            )
            try:
                data = self.state.compile_source(
                    file_name, source, target_slot, load_after
                )
            except Exception as exc:  # noqa: BLE001
                self.state.manifest.upsert(
                    record_id,
                    self.state.manifest_updates(
                        body=body,
                        kind="faust-source",
                        safe_file_name=safe_name,
                        status="failed",
                        source_sha256=source_sha256,
                        source_bytes=len(source_bytes),
                        target_slot=target_slot,
                        loaded=False,
                        error=str(exc),
                    ),
                )
                self.state.emit_event(
                    "effect.failed",
                    artifactId=body.get("artifactId"),
                    productId=body.get("productId"),
                    fileName=safe_name,
                    targetSlot=target_slot,
                    error=str(exc),
                )
                raise
            status = "loaded" if data.get("loaded") else "compiled"
            record = self.state.manifest.upsert(
                record_id,
                self.state.manifest_updates(
                    body=body,
                    kind="faust-source",
                    safe_file_name=safe_name,
                    status=status,
                    source_sha256=source_sha256,
                    source_bytes=len(source_bytes),
                    target_slot=target_slot,
                    loaded=bool(data.get("loaded")),
                    queued=data.get("queued"),
                    library_path=data.get("libraryPath"),
                ),
            )
            data["manifestRecord"] = record
            self.state.emit_event(
                "effect.loaded" if data.get("loaded") else "effect.compiled",
                artifactId=body.get("artifactId"),
                productId=body.get("productId"),
                fileName=safe_name,
                libraryPath=data.get("libraryPath"),
                targetSlot=target_slot,
            )
            self.send_json(200, ok_response("bridge-faust", data))
            return

        queued = self.state.queue_source(file_name, source)
        record = self.state.manifest.upsert(
            record_id,
            self.state.manifest_updates(
                body=body,
                kind="faust-source",
                safe_file_name=safe_name,
                status="queued",
                source_sha256=source_sha256,
                source_bytes=len(source_bytes),
                target_slot=target_slot,
                loaded=False,
                queued=queued,
            ),
        )
        self.state.emit_event(
            "effect.queued",
            artifactId=body.get("artifactId"),
            productId=body.get("productId"),
            fileName=safe_name,
            queued=queued,
            targetSlot=target_slot,
        )
        self.send_json(
            202,
            ok_response(
                "bridge-faust",
                {
                    "queued": queued,
                    "targetSlot": target_slot,
                    "loaded": False,
                    "manifestRecord": record,
                },
            ),
        )

    def handle_entitlement(self, body: dict[str, Any]) -> None:
        # Store the marketplace-signed device entitlement (a Lua `return {...}` blob) where
        # the client reads it ($DEMOD_ENTITLEMENTS → market/entitlements.lua). The bridge does
        # NOT need to trust it: the client verifies the Ed25519 signature with its embedded
        # public key, so a bogus file is simply rejected. We only guard size + shape.
        lua = body.get("lua")
        if not isinstance(lua, str) or not lua.lstrip().startswith("return"):
            raise ValueError("lua (signed entitlement 'return {...}') is required")
        if len(lua.encode("utf-8")) > 16384:
            raise ValueError("entitlement too large")
        dest = self.state.data_dir / "market" / "entitlements.lua"
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".lua.tmp")
        tmp.write_text(lua, encoding="utf-8")
        os.chmod(tmp, 0o644)
        tmp.replace(dest)
        self.state.emit_event("entitlement.updated")
        self.send_json(200, ok_response("bridge-entitlement", {"written": True}))

    def handle_install(self, body: dict[str, Any]) -> None:
        # Anti-spam for install (incl. deep-link redemptions): rate-limit + single-use jti.
        client_ip = self.client_address[0] if hasattr(self, 'client_address') else ""
        if not self.state.install_rate_ok(client_ip):
            self.send_json(429, err_response("bridge-install", "install rate limit exceeded"))
            return
        self.state.note_install_jti(body.get("jti"))  # raises (→400) on replay
        kind = body.get("kind")
        file_name = body.get("fileName")
        target_slot = optional_target_slot(body.get("targetSlot"))
        load_after = bool(body.get("loadAfterInstall", False))
        if kind != "faust-source":
            raise ValueError("only faust-source install is supported by this bridge version")
        if not isinstance(file_name, str) or not file_name:
            raise ValueError("fileName is required")

        source = decode_source_from_body(body)
        source_bytes = source.encode("utf-8")
        source_sha256 = verify_sha256(body.get("sha256"), source_bytes)
        safe_name = safe_dsp_name(file_name)
        record_id = self.state.artifact_record_id(body, kind, safe_name)

        if load_after:
            self.state.emit_event(
                "effect.compile_started",
                artifactId=body.get("artifactId"),
                productId=body.get("productId"),
                fileName=safe_name,
                targetSlot=target_slot,
            )
            try:
                data = self.state.compile_source(file_name, source, target_slot, True)
            except Exception as exc:  # noqa: BLE001
                self.state.manifest.upsert(
                    record_id,
                    self.state.manifest_updates(
                        body=body,
                        kind=kind,
                        safe_file_name=safe_name,
                        status="failed",
                        source_sha256=source_sha256,
                        source_bytes=len(source_bytes),
                        target_slot=target_slot,
                        loaded=False,
                        error=str(exc),
                    ),
                )
                self.state.emit_event(
                    "effect.failed",
                    artifactId=body.get("artifactId"),
                    productId=body.get("productId"),
                    fileName=safe_name,
                    targetSlot=target_slot,
                    error=str(exc),
                )
                raise
            data["installed"] = True
            record = self.state.manifest.upsert(
                record_id,
                self.state.manifest_updates(
                    body=body,
                    kind=kind,
                    safe_file_name=safe_name,
                    status="loaded",
                    source_sha256=source_sha256,
                    source_bytes=len(source_bytes),
                    target_slot=target_slot,
                    loaded=True,
                    queued=data.get("queued"),
                    library_path=data.get("libraryPath"),
                ),
            )
            data["manifestRecord"] = record
            self.state.emit_event(
                "effect.loaded",
                artifactId=body.get("artifactId"),
                productId=body.get("productId"),
                fileName=safe_name,
                libraryPath=data.get("libraryPath"),
                targetSlot=target_slot,
            )
            self.send_json(200, ok_response("bridge-install", data))
            return

        queued = self.state.queue_source(file_name, source)
        record = self.state.manifest.upsert(
            record_id,
            self.state.manifest_updates(
                body=body,
                kind=kind,
                safe_file_name=safe_name,
                status="queued",
                source_sha256=source_sha256,
                source_bytes=len(source_bytes),
                target_slot=target_slot,
                loaded=False,
                queued=queued,
            ),
        )
        self.state.emit_event(
            "effect.queued",
            artifactId=body.get("artifactId"),
            productId=body.get("productId"),
            fileName=safe_name,
            queued=queued,
            targetSlot=target_slot,
        )
        self.send_json(
            202,
            ok_response(
                "bridge-install",
                {
                    "queued": queued,
                    "installed": True,
                    "loaded": False,
                    "manifestRecord": record,
                },
            ),
        )


class BridgeServer(ThreadingHTTPServer):
    def __init__(self, address: tuple[str, int], state: BridgeState) -> None:
        super().__init__(address, BridgeHandler)
        self.state = state


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="DeMoD HTTP device bridge")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--control-socket", default=DEFAULT_CONTROL_SOCKET)
    parser.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    parser.add_argument("--library-dir", default=DEFAULT_LIBRARY_DIR)
    parser.add_argument("--faust-queue-dir", default=DEFAULT_QUEUE_DIR)
    parser.add_argument(
        "--install-manifest",
        default=DEFAULT_MANIFEST_PATH,
        help="path to the storefront-visible install manifest JSON",
    )
    parser.add_argument(
        "--client-token-store",
        default=DEFAULT_CLIENT_TOKEN_STORE,
        help="path to paired client token store JSON",
    )
    parser.add_argument(
        "--event-log",
        default=DEFAULT_EVENT_LOG,
        help="path to bridge progress/event log JSON",
    )
    parser.add_argument(
        "--pairing-code-file",
        default=DEFAULT_PAIRING_CODE_FILE,
        help="path to a one-time physical pairing code JSON file",
    )
    parser.add_argument("--mesh-state", default=DEFAULT_MESH_STATE)
    parser.add_argument("--faust-compiler", default=DEFAULT_COMPILER)
    parser.add_argument("--token", default=os.environ.get("DEMOD_DEVICE_BRIDGE_TOKEN"))
    parser.add_argument(
        "--token-file",
        default=os.environ.get("DEMOD_DEVICE_BRIDGE_TOKEN_FILE"),
    )
    parser.add_argument(
        "--cors-origin",
        default=DEFAULT_CORS_ORIGIN,
        help="comma-separated Origin allowlist for browser clients ('*' disables the "
        "check — not recommended for a localhost service)",
    )
    parser.add_argument(
        "--allow-host",
        dest="allow_hosts",
        default=DEFAULT_ALLOW_HOSTS,
        help="comma-separated extra Host-header hostnames to accept (anti-DNS-rebinding); "
        "loopback names and the bind address are always allowed",
    )
    parser.add_argument("--max-source-bytes", type=int, default=DEFAULT_MAX_SOURCE_BYTES)
    parser.add_argument("--compile-timeout", type=int, default=DEFAULT_COMPILE_TIMEOUT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = load_token(args.token, args.token_file)
    has_pairing_lifecycle = bool(args.client_token_store and args.pairing_code_file)
    if not is_loopback_host(args.host) and not token and not has_pairing_lifecycle:
        print(
            "Refusing to bind a non-loopback device bridge without a token "
            "or pairing token lifecycle",
            file=sys.stderr,
        )
        return 2

    state = BridgeState(args, token)
    state.ensure_dirs()
    server = BridgeServer((args.host, args.port), state)
    if token:
        auth_mode = "bootstrap-token"
    elif state.require_auth:
        auth_mode = "paired-token"
    else:
        auth_mode = "loopback-only"
    cors_desc = "*(open)" if state.cors_allow_all else ",".join(state.cors_origins) or "(none)"
    print(
        f"[device-bridge] listening on http://{args.host}:{args.port} ({auth_mode}; "
        f"origins={cors_desc}; hosts={','.join(sorted(state.allowed_hostnames))})",
        file=sys.stderr,
    )
    if state.cors_allow_all:
        print(
            "[device-bridge] WARNING: Origin check disabled (--cors-origin '*'); any web "
            "page can reach this bridge. See SECURITY.md F-1/F-2.",
            file=sys.stderr,
        )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
