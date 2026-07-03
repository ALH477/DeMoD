#!/usr/bin/env python3
"""Fixture tests for the DeMoD HTTP device bridge."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import pathlib
import tempfile
import threading
import time
import unittest
from typing import Any

from demod_device_bridge import BridgeServer, BridgeState


class BridgeFixture:
    def __init__(self, *, remote_auth: bool = False, pairing_code: str | None = None):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="demod-bridge-test-"))
        pairing_code_file = self.root / "pairing-code.json"
        if pairing_code:
            pairing_code_file.write_text(
                json.dumps(
                    {
                        "v": 1,
                        "expiresAt": "2099-01-01T00:00:00Z",
                        "expiresAtEpoch": int(time.time()) + 600,
                        "codeHash": hashlib.sha256(
                            pairing_code.encode("utf-8")
                        ).hexdigest(),
                    }
                )
            )
        args = argparse.Namespace(
            host="0.0.0.0" if remote_auth else "127.0.0.1",
            control_socket=str(self.root / "control.sock"),
            data_dir=str(self.root / "data"),
            library_dir=str(self.root / "library"),
            faust_queue_dir=str(self.root / "incoming"),
            install_manifest=str(self.root / "install-manifest.json"),
            client_token_store=str(self.root / "client-tokens.json"),
            event_log=str(self.root / "events.json"),
            pairing_code_file=str(pairing_code_file),
            faust_compiler="false",
            compile_timeout=2,
            max_source_bytes=2 * 1024 * 1024,
            cors_origin="*",
        )
        self.state = BridgeState(args, token=None)
        self.state.ensure_dirs()
        self.server = BridgeServer(("127.0.0.1", 0), self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        token: str | None = None,
    ) -> tuple[int, dict[str, Any]]:
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        conn.request(
            method,
            path,
            body=json.dumps(body).encode("utf-8") if body is not None else None,
            headers=headers,
        )
        response = conn.getresponse()
        payload = json.loads(response.read().decode("utf-8"))
        conn.close()
        return response.status, payload


class DeviceBridgeTests(unittest.TestCase):
    def test_pairing_claim_issues_revocable_token(self) -> None:
        fixture = BridgeFixture(remote_auth=True, pairing_code="123456")
        self.addCleanup(fixture.close)

        status, payload = fixture.request("GET", "/v1/capabilities")
        self.assertEqual(status, 401)
        self.assertFalse(payload["ok"])

        status, payload = fixture.request(
            "POST",
            "/v1/pairing/claim",
            {"pairingCode": "123456", "clientName": "browser"},
        )
        self.assertEqual(status, 201)
        token = payload["data"]["token"]
        client_id = payload["data"]["client"]["id"]

        status, payload = fixture.request("GET", "/v1/capabilities", token=token)
        self.assertEqual(status, 200)
        self.assertTrue(payload["data"]["auth"]["required"])
        self.assertEqual(payload["data"]["auth"]["pairedClientCount"], 1)

        status, payload = fixture.request("GET", "/v1/events", token=token)
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["events"][0]["type"], "pairing.claimed")

        status, payload = fixture.request(
            "DELETE", f"/v1/pairing/tokens/{client_id}", token=token
        )
        self.assertEqual(status, 200)
        self.assertTrue(payload["data"]["client"]["revokedAt"].startswith("20"))

        status, payload = fixture.request("GET", "/v1/capabilities", token=token)
        self.assertEqual(status, 401)
        self.assertFalse(payload["ok"])

    def test_faust_queue_records_manifest_and_hash(self) -> None:
        fixture = BridgeFixture()
        self.addCleanup(fixture.close)
        source = 'import("stdfaust.lib"); process = _;'
        source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()

        status, payload = fixture.request(
            "POST",
            "/v1/effects/faust",
            {
                "productId": "prod_smoke",
                "artifactId": "art_smoke",
                "fileName": "../Smoke Chorus",
                "source": source,
                "sha256": source_hash,
            },
        )
        self.assertEqual(status, 202)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["data"]["queued"]["file_name"], "Smoke_Chorus.dsp")

        status, payload = fixture.request("GET", "/v1/effects/manifest")
        self.assertEqual(status, 200)
        record = payload["data"]["artifacts"][0]
        self.assertEqual(record["id"], "art_smoke")
        self.assertEqual(record["status"], "queued")
        self.assertEqual(record["sha256"], source_hash)

        status, payload = fixture.request("GET", "/v1/events")
        self.assertEqual(status, 200)
        self.assertEqual(payload["data"]["events"][0]["type"], "effect.queued")

        conn = http.client.HTTPConnection("127.0.0.1", fixture.port, timeout=3)
        conn.request("GET", "/v1/events/stream")
        response = conn.getresponse()
        self.assertEqual(response.status, 200)
        self.assertIn("event: effect.queued", response.read().decode("utf-8"))
        conn.close()

    def test_hash_mismatch_is_rejected(self) -> None:
        fixture = BridgeFixture()
        self.addCleanup(fixture.close)
        status, payload = fixture.request(
            "POST",
            "/v1/effects/faust",
            {
                "fileName": "bad.dsp",
                "source": "process = _;",
                "sha256": "0" * 64,
            },
        )
        self.assertEqual(status, 400)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["err"], "sha256 mismatch")


if __name__ == "__main__":
    unittest.main()
