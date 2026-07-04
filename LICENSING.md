# Licensing

This repository contains **two independently-licensed parts**. They are separate
programs that talk to each other only over a Unix socket and shared memory — there is
no build dependency in either direction — so you can take one without the other.

## The framework — MPL-2.0

Everything at the repository root **except `audio-stack/`** is the **DeMoD UI
framebuffer GUI framework**, licensed under the **Mozilla Public License 2.0**
(`LICENSE`, SPDX `MPL-2.0`):

```
src/  include/  examples/  tools/  tests/  Makefile  flake.nix  *.lua  *.md (root)
```

MPL is file-level copyleft: you can build a larger proprietary or differently-licensed
work on top of the framework (a "Larger Work", MPL §3.3) as long as modifications to the
MPL files themselves stay MPL. **Using only the framework never involves the GPL below.**

## The audio stack — GPLv3-only OR commercial (dual)

Everything under **`audio-stack/`** — the `demod-rt` engine, the `demod-orchestrator`
Haskell daemon, and their IPC contract — is the **DeMoD audio stack**, dual-licensed
under the **DEMOD DUAL LICENSE** (`audio-stack/LICENSE`):

- **Option 1 — GPLv3 (version 3 only)**, SPDX `GPL-3.0-only`, for open-source, personal,
  educational, and non-commercial use.
- **Option 2 — Commercial**, for closed-source / commercial hardware use.

Every source file under `audio-stack/` carries `SPDX-License-Identifier: GPL-3.0-only`.

## The quanta compiler — GPLv3-only OR commercial (dual)

Everything under **`quanta/`** — the **DeMoD Quanta** analysis-to-synthesis codec
(`quanta-analyzer` / `-render` / `-freeze` and the QSC score format) — is dual-licensed
under the same **DEMOD DUAL LICENSE** (`quanta/LICENSE`):

- **Option 1 — GPLv3 (version 3 only)**, SPDX `GPL-3.0-only`, for open-source, personal,
  educational, and non-commercial use.
- **Option 2 — Commercial**, for closed-source / commercial use.

Every C source under `quanta/` carries `SPDX-License-Identifier: GPL-3.0-only`. The one
exception is the framework-facing browser panel **`quanta/ui/quanta_panel.lua`**, which is
**MPL-2.0** (UI layer, one-way compatible into the MPL framework). A generated frozen `.dsp`
is the property of the score owner. Like the audio stack, quanta is a **separate program**
from the framework — the framework has no build dependency on it.

## Why the split is clean

The framework (MPL) and the audio stack (GPLv3) are **separate programs** communicating
over IPC — GPLv3 "mere aggregation" applies, and MPL-2.0 is one-way compatible with
GPLv3 — so distributing them together in one repository does not relicense either. The
shared-memory struct layout is intentionally duplicated: `include/demod/demod_rt_meters.h`
(framework copy, MPL) and `audio-stack/ipc/include/demod_rt_meters.h` (engine copy, GPL)
are byte-identical in layout but each carries its own license; they are deliberately not
deduplicated, to keep the boundary clean.

## DCF remote transport (optional, LGPL-3.0)

The optional DCF (HydraMesh/UDP) transport — which lets the engine run on another
machine and talk to the UI over UDP — is **LGPL-3.0-only**, matching the HydraMesh
codec headers it links:

- `src/ipc/dm_dcf.c` — the `dm.dcf` framework binding, compiled **only** with `make DCF=1`
  (`#ifdef DEMOD_DCF`). The default `demod-ui` build does not include it and stays MPL-2.0.
- `audio-stack/bridge/**` — `demod-remote-bridge`, a standalone engine-side relay (separate binary).
- `web/bridge/**` — `dcf-ws-bridge`, the stateless WebSocket↔UDP relay for the browser (WASM)
  client (vendored from HydraMesh; its Rust deps are fetched at build time via `Cargo.lock`,
  not committed). The wasm build itself (`src/ipc/dm_dcf.c`'s `__EMSCRIPTEN__` branch) is the
  same LGPL-3.0 file.
- `third_party/hydramesh/*.h` — vendored header-only DCF codecs (LGPL-3.0, see that dir's README).

LGPL-3.0 links cleanly into both the MPL framework (file-level) and the GPLv3 engine
(LGPL-3.0 is GPL-3.0-compatible). Flake outputs: `demod-ui-dcf`, `demod-remote-bridge`,
`dcf-ws-bridge`.

## Third-party / vendored components

See `THIRD_PARTY_LICENSES.md`. Notably: SDL2 (zlib), Lua (MIT), monocypher (CC0/BSD-2),
StreamDB (LGPL-2.1-or-later), GNU Unifont glyph data (OFL-1.1, fetched by `make font`,
not committed), and the HydraMesh DCF codec headers (LGPL-3.0, vendored in
`third_party/hydramesh/`). The DeMoD/TERMINUS marks and trade dress are reserved — see `TRADEMARK.md`.

## SPDX summary

| Path | SPDX |
|------|------|
| root framework (`src/`, `include/`, `examples/`, `tools/`, `tests/`, Lua) | `MPL-2.0` |
| `audio-stack/**` (engine + orchestrator) | `GPL-3.0-only` (or commercial) |
| `quanta/**` (analyzer/render/freeze + QSC) | `GPL-3.0-only` (or commercial) |
| `quanta/ui/quanta_panel.lua` (framework panel) | `MPL-2.0` |
| `src/ipc/dm_dcf.c`, `audio-stack/bridge/**`, `third_party/hydramesh/**` (DCF, opt-in) | `LGPL-3.0-only` |
| `src/crypto/monocypher*` | `CC0-1.0 OR BSD-2-Clause` |
| `src/db/streamdb.*` | `LGPL-2.1-or-later` |
