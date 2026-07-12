# DeMoD Jam — collaborative audio over the certified DCF-Audio wire

A TERMINUS **app patch** (`type: app`) that turns the DeMoD mesh into a jam: pick a
codec, choose a **delivery profile** (latency-first or quality-first), hit START, and
stream real **DCF-Audio** — every 20 ms block is encoded and packetized into 17‑byte
`DeModFrame` `CTRL` frames and shown live, a TUNED peer reassembles them and a
MISTUNED one rejects them, while the mesh strip tracks your peers.

It is a **combination of DeMoD codebases**:

- the **certified DCF-Audio codec** from HydraMesh (`python/MCP/audiolab_core.py`,
  `codec/demod_audio.h`, `codec/src/audio.rs`), ported to pure Lua in
  [`dcf_audio.lua`](dcf_audio.lua) — **byte-identical** to the C/Rust/Python
  references and to `GUI/wirelab.lua`;
- the certified **SuperPack** ([`dcf_superpack.lua`](dcf_superpack.lua)) and **FEC**
  ([`dcf_fec.lua`](dcf_fec.lua)) framework modules from HydraMesh `lua/`, bundled
  byte-identically — they back the two delivery profiles; and
- the **TERMINUS** app-patch model (`patches/example-app`), so the home shell
  launches it and `back` returns to TERMINUS.

## Delivery profiles — latency-first vs quality-first (timing synced either way)

A **PROFILE** row picks the trade-off. It only changes how the certified frames are
*delivered* — never their bytes, and never their timing:

- **LATENCY-first** — adjacent frame-pairs are **SuperPacked** (two 17‑byte frames →
  one 32‑byte datagram: one IP/UDP header, one syscall, one packet), and the jitter
  buffer is shallow (1 block, ~20 ms). The wire view shows the live `frames →
  datagrams` reduction; the monitor `unpack`s each SuperPack and proves the round-trip
  is bit-exact (`Documentation/SUPERPACK_SPEC.md`).
- **QUALITY-first** — the block payload is protected with **Reed-Solomon FEC**
  (`2t=16` → corrects 8 byte-errors/codeword), and the jitter buffer is deeper (4
  blocks, ~80 ms) for reorder + PLC headroom. The view injects a single-byte error and
  shows it **RECOVERED**, not dropped (`Documentation/DCF_FEC_SPEC.md`).

**Timing is synced no matter what.** A single monotonic block clock sets the certified
24-bit `timestamp_us` field to `block_index * 20000` µs — identical across all of a
packet's frames and **identical in both profiles**. Playout/record keys on
`(packet_id, timestamp_us)` (DCF_AUDIO_SPEC L3), so a peer stays sample-accurate
regardless of which profile the sender chose. The header `SYNC` line is the same
formula in latency and quality mode; only the buffer depth differs.

## What it does

- **Codec registry** — PCM-diag (id 1), Opus (id 0), Faust phase-mod (id 2). The
  bundled [`dcf_pm_codec.dsp`](dcf_pm_codec.dsp) is the musical PM synth; its
  parameters ([`fx.lua`](fx.lua)) are quantised by `FX.pm_block()` and travel as the
  certified 8-byte PM block on the wire (the layout — not the synthesis — is the
  certified surface; `fx.lua` is the single real-unit → byte authority).
- **Certified wire** — `dcf_audio.lua` self-certifies on load against the CRC anchor
  (`0x29B1`) and the `exampleAudioPacket` vector in
  `HydraMesh/Documentation/audio_vectors.json`. The header lamp lights turquoise
  (`WIRE CERTIFIED`) only when the port matches the reference.
- **Live wire view** — the latest descriptor `DeModFrame`, field-colored
  (sync / flags / seq / src / dst / payload / ts / crc), with per-packet stats.
- **Mesh strip** — peer count + link state from `$DEMOD_MESH_STATE`
  (default `/var/lib/demod/mesh.json`), the same source the Systems tour uses.

## Wire format (recap)

Audio is an *adapter* over the one wire quantum — see
`HydraMesh/Documentation/DCF_AUDIO_SPEC.md`. One 20 ms block → `1 + ceil(len/4)`
frames; `seq = packet_id[15:5] | frag_idx[4:0]`; `frag_idx 0` is the
`[len, frag_total, codec_id, flags]` descriptor; payload ≤ 124 B / block.

## Run

```bash
# from the TERMINUS toolchain (demod-ui host)
~/demod-ui/demod-ui patches/demod-jam/main.lua
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 ~/demod-ui/demod-ui patches/demod-jam/main.lua   # headless

# verify the Lua framework (audio + SuperPack + FEC + synced ts24) vs the golden
# vectors (Lua 5.3+) — 16 checks, exit 0 iff all pass
lua patches/demod-jam/selftest.lua
```

Controls: **up/down** move (or tune frequency) · **select** choose codec / cycle
passphrase / toggle **profile** / open **CONNECT / HOST…** / toggle jam · **back**
closes the overlay, else exits. Stopping a jam emits a final `FLAG_END_TALKSPURT`
descriptor.

## Multiplayer & recording — see [`HOSTING.md`](HOSTING.md)

**Can this patch jam multiplayer on its own? No.** It is a local **control +
certified-wire preview**: it encodes and visualises the wire but never opens a socket
or touches the mic/speaker — the TERMINUS host gives Lua patches no network or audio
I/O. Transport and real audio belong to the orchestrator (`demod-rt`) + HydraMesh.

The frames it emits are interoperable, so going multiplayer means **matching its
rendezvous on a real DCF endpoint**. The in-patch **CONNECT / HOST…** screen prints the
exact channel/codec and the join command; the three routes are:

- **Client app** (recommended) — the HydraMesh Tauri client jams for real and records
  per-participant `master.mka` + `mix.flac`.
- **Docker `dcf-radio`** — a station that archives a whole channel as HLS + DVR.
- **Bridge** — feed orchestrator blocks through `dcf_audio.packetize(...)` and ship via
  HydraMesh `send_audio_dcf` / `reassemble_audio_payload`.

[`HOSTING.md`](HOSTING.md) has the full commands, the rendezvous-matching rules, and the
WireGuard deployment note.

## Integration seam

This patch is the **control + certified-wire surface**. Real mic/speaker I/O and
true Opus encoding belong to the device orchestrator/`demod-rt`; the Opus payload
shown here is synthesised for the wire view. To go live, feed the orchestrator's
20 ms blocks through `dcf_audio.packetize(...)` and ship the frames over the mesh
(HydraMesh `send_audio_dcf` / `reassemble_audio_payload`) — see
[`HOSTING.md`](HOSTING.md) Path C, and Paths A/B for the client-app and Docker routes.

## Frequency rendezvous (handshakeless)

DCF is handshakeless — no connection setup. Peers **pre-agree on a channel** (the
frame `dst` field) and are immediately connected. The Jam UI lets you set it two ways:

- **FREQUENCY** — tune a numeric `u16` channel (select to enter tuning, up/down to
  change).
- **PASSPHRASE** — pick a shared word; `dcf_audio.channel_from_passphrase` hashes it to
  a channel via the certified `crc16`. Same word → same channel.

Frames are packetized with `dst = channel`; a receiver accepts a frame iff
`dcf_audio.accepts(frame.dst, my_channel)` (match or broadcast `0xFFFF`). Two peers on
the same frequency jam; everyone else's frames are ignored. No wire change — the frames
are ordinary, certified `DeModFrame`s.

## Licensing — split (framework LGPL, UX Shield)

This patch is deliberately split so the open framework stays cleanly separable:

- **Framework (LGPL-3.0-only):** `dcf_audio.lua`, `dcf_superpack.lua`, `dcf_fec.lua`,
  `selftest.lua`, `dcf_pm_codec.dsp` — byte-identical to the canonical, dual-licensed
  framework in the HydraMesh repo (`lua/`). A commercial license is available from
  DeMoD LLC on request.
- **Jam UX (PolyForm Shield 1.0.0):** `main.lua`, `fx.lua`, `HOSTING.md` — the TERMINUS
  application layer, under the same license as the rest of the shell.

The UX depends on the framework as a discrete module; no Shield code flows into the
LGPL framework and vice versa. The `manifest.json` `"license": "free"` field is the
marketplace gratis/paid flag (per `MANIFESTS.md`), not an SPDX license — the per-file
SPDX headers are authoritative.
