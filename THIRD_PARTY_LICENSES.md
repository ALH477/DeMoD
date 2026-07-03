# Third-party components

Original demod-ui code is © 2026 DeMoD LLC under the **Mozilla Public License 2.0**
(SPDX `MPL-2.0`, see `LICENSE`). Bundled/linked third-party keeps its own license — all
are MPL-2.0-compatible:

| Component | License |
|-----------|---------|
| SDL2 / sdl2-compat | zlib |
| Lua 5.4 | MIT |
| monocypher (vendored in `src/crypto/`) | CC0-1.0 / BSD-2-Clause (public-domain-equivalent) — see `src/crypto/MONOCYPHER-LICENCE.md` |
| StreamDB (vendored in `src/db/`; DeMoD-authored, separate upstream project) | LGPL-2.1-or-later (see the headers in `src/db/streamdb.{c,h}`) |
| GNU Unifont glyph data (**not in this repo**; `tools/genfont.py` builds runtime `.dmf` glyph blobs from Unifont `.hex` releases) | SIL OFL-1.1 (Unifont is dual OFL-1.1 / GPL-2.0-or-later with font-embedding exception; used here under **OFL-1.1**) |
| HydraMesh DCF codec headers (vendored header-only in `third_party/hydramesh/`; used by the opt-in `DCF=1` transport) | LGPL-3.0-only — from github.com/ALH477/HydraMesh, pinned commit in that dir's `README.md` |
| Steamworks SDK (`libsteam_api.so`) — **Steam edition build only** (`make STEAM=1`) | Valve SDK Access Agreement (proprietary; **not in this repo**, referenced out-of-tree via `$DEMOD_STEAM_SDK`) |

monocypher is unmodified and keeps its own (CC0/BSD-2) terms — it is **not** relicensed
under the MPL. StreamDB is DeMoD's own embedded reverse-trie database, published as a
separate LGPL project and vendored here; it likewise keeps its LGPL-2.1-or-later terms
(LGPL §3 permits conveying it under the compatible GPL-family terms; it is **not**
relicensed under the MPL).

**Steamworks boundary.** The optional Steam edition links Valve's proprietary
`libsteam_api.so`. MPL-2.0 permits combining MPL code with proprietary components in a
larger work, so this is compatible; the SDK is never committed here and is only present
in `make STEAM=1` builds. Non-Steam builds neither link nor ship it.
