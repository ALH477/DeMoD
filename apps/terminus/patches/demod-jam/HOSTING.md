<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# DeMoD Jam — hosting, recording & multiplayer

This guide explains how to take **DeMoD Jam** from a local preview to a real,
multi-peer, recorded session. It covers both the **HydraMesh client app** (per-user
multitrack recording) and **Docker** (a `dcf-radio` station that archives a whole
channel).

> The commands below drive the **HydraMesh** repo (the DCF reference stack), which is
> separate from this TERMINUS patch. They are transcribed and verified against
> HydraMesh source; run them from a checkout of that repo.

## Can this patch do multiplayer on its own? — No.

DeMoD Jam is a **control + certified-wire surface**. It encodes 20 ms blocks into the
certified 17-byte `DeModFrame` wire, packetizes them for a rendezvous channel, and
shows the result live — but it **never opens a socket and never captures or plays
audio**. The TERMINUS host (`demod-ui`) deliberately gives Lua patches no network or
audio I/O: the `dm` API exposes drawing, input, MIDI, StreamDB, and a *local control
socket* only. Real mic/speaker, real codecs, and transport belong to the device
orchestrator (`demod-rt`) and the HydraMesh node beneath it.

So "multiplayer" means: **stand up a real DCF endpoint and point it at the same
rendezvous this patch shows you** (the `CONNECT / HOST…` screen prints the exact
channel, codec, and join command). Three ways to do that follow.

The wire is **plaintext by design** (EAR/ITAR export compliance). Deploy every endpoint
inside **WireGuard** beneath the UDP socket — see
`HydraMesh/Documentation/DCF_SECURITY_EXPOSURE.md`.

## Matching the rendezvous (the one thing that must agree)

DCF is handshakeless — peers connect by **pre-agreeing on a channel** (the frame `dst`
field), nothing else. Open `CONNECT / HOST…` in the patch and read off:

- **channel** — a `u16`. In PASSPHRASE mode it is `crc16(passphrase)` (the certified
  hash, identical in the patch and the client); in FREQUENCY mode it is the number you
  tuned. This value is what a node passes as `--channel N`.
- **codec** — `id 0` Opus, `id 1` PCM-diag (byte-certified), `id 2` Faust-PM.
- **UDP port** — the ProtoMessage nodes (Go/C/Rust) default to **7777/udp**.

Every endpoint that shares the same channel + codec + reachable port jams together;
everyone else's frames are silently dropped.

## Path A — Jam & record with the HydraMesh client app (recommended)

The Tauri client (`HydraMesh/client/`) is the real jam endpoint: it captures the mic,
encodes, ships DCF-Audio over the mesh, mixes inbound peers per-source, and records.

```sh
# from a HydraMesh checkout
nix develop .#comms                 # rust + node + webkit + alsa + opus + cargo-tauri
cd client && npm install && cargo tauri dev
```

In the app: open the same **rendezvous** as the patch — by passphrase
(`set_channel({ passphrase = "basement-jam" })`) or frequency (`{ freq = 1420 }`) — and
pick the **same codec**. Add peers (each laptop adds the others) and start the jam.

**Recording** (per-participant, sample-accurate):

- `start_recording("<dir>")` / `stop_recording()` (Tauri commands; also a UI button).
- Output, keyed by frame `src_id` (one stream per participant + `self`):
  - per-source `*.opus` tracks on a shared, gapless timeline
    (`client/src-tauri/src/sync.rs`),
  - **`master.mka`** — multitrack, bit-exact (`ffmpeg -c:a copy`),
  - **`mix.flac`** — lossless stereo mixdown (`ffmpeg amix`).
- Requires host **ffmpeg** on `PATH`; without it the `.opus` tracks are still written,
  `master.mka`/`mix.flac` are skipped. See `client/src-tauri/src/recorder.rs`.

```sh
cd client/src-tauri && cargo test --features audio   # sync/recorder (+ ffprobe) tests
```

## Path B — Host & record with Docker (a `dcf-radio` station)

Use Docker when you want a **persistent station** that archives a channel (HLS live
stream + DVR rewind), or a mesh **hub** for peer-health/roles.

```sh
# build the station image (from a HydraMesh checkout; needs nix + docker)
nix build .#docker-dcf-radio && docker load < result

docker network create dcf-mesh
# dcf-radio: tap mesh audio on :7100, serve HLS on :8000, keep a 6 h DVR archive
docker run -d --name radio --network dcf-mesh \
  -p 8000:8000/tcp -p 7100:7100/udp -v dcf-radio:/var/dcf-radio \
  alh477/dcf-radio:latest \
  --bind 0.0.0.0:7100 --http 0.0.0.0:8000 --archive /var/dcf-radio --dvr 6h
# browse http://localhost:8000 for the live + DVR streams
```

Optional mesh hub (peer health / self-healing roles; not an audio mixer):

```sh
docker run -d --name hub --network dcf-mesh -p 7777:7777/udp \
  alh477/dcf-go:latest start --bind 0.0.0.0:7777 --mode master --node-id 1
# auto/p2p peers join with: ... start --mode auto --node-id N --master 1 --peer 1@hub:7777
```

**Honest caveat:** the dockerized **mesh nodes** (`dcf-go`/`dcf-c`/`dcf-rust`) *log*
audio frames — they do not play, mix, or forward audio (multi-hop audio is a future
extension). The **`dcf-radio`** image is the Docker-native **recorder/streamer**; the
actual jam endpoints are Path A clients (or a custom SDK app, Path C). See
`HydraMesh/docker/mesh-interop-test.sh` and `HydraMesh/Documentation/DCF_RADIO.md`.

## Path C — Bridge this patch's own frames (when `demod-rt` is present)

If the device orchestrator is running, the integration seam is: feed the orchestrator's
20 ms blocks through `dcf_audio.packetize(...)` (the same framing this patch uses) and
ship them with the HydraMesh Rust SDK:

- `DcfNode::send_audio_dcf(codec_id, encoded, packet_id, ts_us, channel)` and
  `reassemble_audio_payload` (`HydraMesh/rust/src/lib.rs`), per-source reassembly keyed
  by `src_id`.

This is the only path where the *patch's* descriptor frames leave the box, and it
requires the orchestrator to own the socket — the Lua layer still never transmits.

## Path D — Steam transport (Steam P2P + dedicated servers)

The node can also carry these frames over Valve's networking: **Steam P2P** for clients
and **dedicated servers** that are the Docker containers / runtime (`dcfcpp serve-gns` /
`serve-steam`, the open GameNetworkingSockets backend by default; the proprietary
Steamworks SDK adds SDR relay + lobbies + server browser). The channel/codec a Steam
endpoint must match is the same rendezvous this patch shows. See
[`../../STEAM_MULTIPLAYER.md`](../../STEAM_MULTIPLAYER.md) and
`HydraMesh/Documentation/DCF_STEAM_SPEC.md`.

## Quick reference

```sh
# headless 2-peer jam over UDP (loss + PLC + SNR), no GUI:
cd HydraMesh/codec && cargo run --example jam_loopback -- --codec pcm --loss 0.05

# send a single audio block from a node to a peer/channel:
dcfnode send-audio --peer host:7777 --channel <N> --hex <BYTES> --codec <0|1|2>

# record DCF-Audio off the wire with the ffmpeg `dcf` demuxer:
nix build .#dcf-ffmpeg     # provides the dcf demuxer / dcf-rec
```

| Want | Use | Output |
|------|-----|--------|
| Per-user multitrack record | client app (Path A) | `master.mka` + `mix.flac` |
| Channel-wide archive / replay | `dcf-radio` (Path B) | HLS live + DVR |
| Headless loopback test | `jam_loopback` | SNR / loss report |
| Mesh health / roles | `dcf-go` hub (Path B) | REPORT/ROLE mesh |
