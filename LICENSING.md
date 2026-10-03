# Licensing

DeMoD LLC holds the copyright in all project-authored work in this repository. The repository
contains **five independently-licensed layers** under four licences — MPL-2.0, LGPL-3.0-only,
the DEMOD DUAL LICENSE (GPLv3-only or a commercial licence) and PolyForm Shield 1.0.0 — plus
third-party components that keep their own licences.

The framework, the audio stack and the quanta codec are separate programs: the framework talks
to the audio stack only over a Unix socket and shared memory, and it has no build dependency on
either of them, nor they on it. The DCF transport is compiled into the framework only with
`make DCF=1`; TERMINUS is a set of Lua applications and patches that the framework runs. You can
take any one layer without the others.

Licence texts are in `LICENSES/`.

## The framework — MPL-2.0

Everything at the repository root **except `audio-stack/`, `quanta/`, `apps/terminus/`** and the
DCF, `nixos/` and third-party files listed below is the **DeMoD UI framebuffer GUI framework**,
licensed under the **Mozilla Public License 2.0** (`LICENSE`, SPDX `MPL-2.0`):

```
src/  include/  examples/  tools/  tests/  shell/  auto/ dash/ gcs/ rov/  apps/mixer/  Makefile  flake.nix  *.lua  *.md (root)
```

MPL is file-level copyleft: you can build a larger proprietary or differently-licensed
work on top of the framework (a "Larger Work", MPL §3.3) as long as modifications to the
MPL files themselves stay MPL. **Using only the framework never involves the GPL below.**

## The dual-licensed engines — GPLv3-only OR commercial

Two layers are offered under the **DEMOD DUAL LICENSE**. It is ordinary dual licensing: the
same code is available under either of two licences, and you pick one.

- **Option 1 — GPLv3 (version 3 only)**, SPDX `GPL-3.0-only`, open to **anyone** who accepts its
  terms, for **any purpose, commercial use included**. GPLv3 is not a non-commercial licence: you
  may sell a device or a product that contains the engine. What it requires is that whoever
  distributes the code, or a work based on it, licenses that work under GPLv3 and provides its
  complete corresponding source (with the installation information GPLv3 §6 requires for a
  consumer product).
- **Option 2 — Commercial licence** from DeMoD LLC, for anyone who does **not** want those
  obligations, for example to ship proprietary firmware or plugins. Terms: **$249 one-time per
  developer (perpetual), plus 3% of hardware device sales revenue** for physical devices;
  software and plugin revenue is not shared. Full terms are in the `LICENSE` file of each layer;
  to buy, email **alh477@proton.me**.

Source files carry the SPDX tag `GPL-3.0-only` or `GPL-3.0-only OR LicenseRef-DeMoD-Commercial`.
Both describe the same offer: the public licence is GPLv3-only, and the commercial licence is
bought from DeMoD LLC (`LICENSES/LicenseRef-DeMoD-Commercial.txt`).

### The audio stack

Everything under **`audio-stack/`** — the `demod-rt` engine, the `demod-orchestrator` Haskell
daemon, and their IPC contract (`audio-stack/LICENSE`, and the same text in
`audio-stack/orchestrator/LICENSE`) — except the LGPL DCF bridge in `audio-stack/bridge/`
(below). `audio-stack/bridge/demod-dcf-audiocast.c` links libjack and the engine, so it stays
under the dual licence.

The NixOS modules that deploy the engine for DCF-Snake, **`nixos/modules/snake-*.nix`**, carry
the same dual licence.

### The quanta compiler

Everything under **`quanta/`** — the **DeMoD Quanta** analysis-to-synthesis codec
(`quanta-analyzer` / `-render` / `-freeze` and the QSC score format) — is dual-licensed under
the same terms (`quanta/LICENSE`; component table in `quanta/LICENSING.md`).

The one exception is the framework-facing browser panel **`quanta/ui/quanta_panel.lua`**, which
is **MPL-2.0** (UI layer, one-way compatible into the MPL framework). A generated frozen `.dsp`
is the property of the score owner. Like the audio stack, quanta is a **separate program**
from the framework — the framework has no build dependency on it.

## TERMINUS — PolyForm Shield 1.0.0 (source-available)

Everything under **`apps/terminus/`** — the flagship home shell + DSP Studio with its full
control surface, modulation matrix, DAW-style mixer/sequencer, and example patches — is
licensed under **PolyForm Shield 1.0.0** (`apps/terminus/LICENSE`, SPDX
`LicenseRef-PolyForm-Shield-1.0.0`), except as listed below:

- Shield permits **any use, commercial use included** — run it, change it, build on it,
  distribute it, sell products that contain it — with **no fee and no revenue share**.
- The one restriction: you may not use it to provide a product that **competes** with TERMINUS
  or with any product DeMoD LLC (or an affiliate) provides using it. `apps/terminus/LICENSE`
  states DeMoD's line of business ("DeMoD TERMINUS — guitar/audio device UI shell, DSP studio,
  and DSP-patch marketplace client"), so that restriction keeps covering that line of business
  even where DeMoD stops offering a particular product.
- Recipients of your copies must get the licence terms (or their URL) and the `Required
  Notice:` line in `apps/terminus/LICENSE`. For a use Shield does not permit, email
  **alh477@proton.me**.

Exceptions inside `apps/terminus/`:

- `patches/demod-jam/{dcf_audio,dcf_superpack,dcf_fec,selftest}.lua` and `dcf_pm_codec.dsp` are
  **LGPL-3.0-only**, byte-identical copies of HydraMesh's Lua DCF framework (see that patch's
  `README.md`).
- `patches/demod-vox/DeMoD_Vox.dsp` is **MIT**, from DeMoD-Vox.
- Several patch `.dsp` files name a licence in their Faust metadata (`declare license`) other
  than Shield: `"GPL-3.0"` in fifteen, `"MIT"` in two, and
  `"DeMoD Commercial Source License / BSD-3 (community)"` in `ocarina.dsp`. Those declarations
  shipped with the files and are not withdrawn here: each such file is available under Shield
  **or** the licence it declares.

TERMINUS is **not MPL** — do not copy its code into the open framework or the audio stack. The
framework and shells remain MPL; TERMINUS is a separate application layer on top.

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
  `examples/dcf_loopback.lua` drives it and is LGPL-3.0-only as well.
- `audio-stack/bridge/**` — `demod-remote-bridge`, a standalone engine-side relay (separate
  binary), except `demod-dcf-audiocast.c` (dual-licensed, above).
- `web/bridge/**` — `dcf-ws-bridge`, the stateless WebSocket↔UDP relay for the browser (WASM)
  client (vendored from HydraMesh; its Rust deps are fetched at build time via `Cargo.lock`,
  not committed). The wasm build itself (`src/ipc/dm_dcf.c`'s `__EMSCRIPTEN__` branch) is the
  same LGPL-3.0 file.
- `web/bridge/custos/custos.gen.c` — the datagram gate both bridges link: C **emitted by the
  Exsecutor compiler** (`exsc --emitte c`) from three GPL-3.0-or-later Exsecutor source files
  (the entry-23 `DeModFrame` declaration and codec, and `examples/custos/custos.exsc`). Shipping
  it here under LGPL-3.0-only rests on two permissions, one for each work it is based on.
  The compiler's part: Exsecutor's `LICENSE.EXCEPTION` Exception A says compiler output is not
  a work based on the *compiler*. The program's part: Exception A does not release the output
  from the licence of the *program compiled*, so Exsecutor's root `LICENSE.GRANTS`, in which
  DeMoD LLC additionally licenses those three files, and every earlier version of each, under
  LGPL-3.0-only, supplies it. **No Exsecutor source is copied in.** Provenance (command,
  commit, sha256) in `web/bridge/custos/PROVENANCE.md`.
- `third_party/hydramesh/*.h` — vendored header-only DCF codecs (LGPL-3.0-only, see that dir's
  README and `THIRD_PARTY_LICENSES.md`).

LGPL-3.0 links cleanly into both the MPL framework (file-level) and the GPLv3 engine
(LGPL-3.0 is GPL-3.0-compatible). Flake outputs: `demod-ui-dcf`, `demod-remote-bridge`,
`dcf-ws-bridge`.

## Third-party / vendored components

See `THIRD_PARTY_LICENSES.md`. Notably: SDL2 (zlib), Lua (MIT), monocypher
(`CC0-1.0 OR BSD-2-Clause`, vendored in `src/crypto/`), StreamDB (LGPL-2.1-or-later), GNU
Unifont glyph data (OFL-1.1, fetched by `make font`, not committed), and the HydraMesh DCF
codec headers (LGPL-3.0-only, vendored in `third_party/hydramesh/`). The DeMoD/TERMINUS marks
and trade dress are reserved — see `TRADEMARK.md`.

## SPDX summary

| Path | SPDX |
|------|------|
| root framework (`src/`, `include/`, `examples/`, `tools/`, `tests/`, shells, Lua) | `MPL-2.0` |
| `audio-stack/**` (engine + orchestrator) | `GPL-3.0-only` (or commercial) |
| `nixos/modules/snake-*.nix` | `GPL-3.0-only OR LicenseRef-DeMoD-Commercial` |
| `quanta/**` (analyzer/render/freeze + QSC) | `GPL-3.0-only OR LicenseRef-DeMoD-Commercial` |
| `quanta/ui/quanta_panel.lua` (framework panel) | `MPL-2.0` |
| `apps/terminus/**` (home shell + DSP Studio + patches) | `LicenseRef-PolyForm-Shield-1.0.0` (exceptions above) |
| `src/ipc/dm_dcf.c`, `audio-stack/bridge/**`, `web/bridge/**`, `third_party/hydramesh/**` (DCF, opt-in) | `LGPL-3.0-only` |
| `src/crypto/monocypher*` | `CC0-1.0 OR BSD-2-Clause` |
| `src/db/streamdb.*` | `LGPL-2.1-or-later` |
