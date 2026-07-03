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

## Why the split is clean

The framework (MPL) and the audio stack (GPLv3) are **separate programs** communicating
over IPC — GPLv3 "mere aggregation" applies, and MPL-2.0 is one-way compatible with
GPLv3 — so distributing them together in one repository does not relicense either. The
shared-memory struct layout is intentionally duplicated: `include/demod/demod_rt_meters.h`
(framework copy, MPL) and `audio-stack/ipc/include/demod_rt_meters.h` (engine copy, GPL)
are byte-identical in layout but each carries its own license; they are deliberately not
deduplicated, to keep the boundary clean.

## Third-party / vendored components

See `THIRD_PARTY_LICENSES.md`. Notably: SDL2 (zlib), Lua (MIT), monocypher (CC0/BSD-2),
StreamDB (LGPL-2.1-or-later), and GNU Unifont glyph data (OFL-1.1, fetched by `make font`,
not committed). The DeMoD/TERMINUS marks and trade dress are reserved — see `TRADEMARK.md`.

## SPDX summary

| Path | SPDX |
|------|------|
| root framework (`src/`, `include/`, `examples/`, `tools/`, `tests/`, Lua) | `MPL-2.0` |
| `audio-stack/**` | `GPL-3.0-only` (or commercial) |
| `src/crypto/monocypher*` | `CC0-1.0 OR BSD-2-Clause` |
| `src/db/streamdb.*` | `LGPL-2.1-or-later` |
