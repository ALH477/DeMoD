# Vendored HydraMesh / DCF codec headers

These are header-only, dependency-free codec headers vendored verbatim from the
**HydraMesh** project (the DCF protocol) so the DCF remote-transport support
(`src/ipc/dm_dcf.c`, `audio-stack/bridge/`) builds offline.

- **Upstream:** https://github.com/ALH477/HydraMesh
- **Pinned commit:** `25de6d90fd400199b07ab5984ebdb12cb2c2fa9b`
- **License:** LGPL-3.0-only (each file carries its own `SPDX-License-Identifier`).
  See `LICENSING.md` and `THIRD_PARTY_LICENSES.md`.

Files:
- `demod_frame.h` — the 17-byte `DeModFrame` wire quantum (encode/decode/CRC).
- `demod_text.h`  — DCF-Text framing (carries JSON control ops, ≤4092 B/msg).
- `demod_audio.h` — DCF-Audio L2 framing (≤124 B blocks); reused for telemetry.

Do not edit these here — update the pinned commit and re-copy from upstream so the
cross-language golden-vector certification stays valid.
