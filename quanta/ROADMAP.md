# demod-quanta — Follow-up Roadmap

*DeMoD LLC · demod.ltd · roadmap as of v0.2.0-streaming*

This is a working roadmap for the Gabor-quanta codec whose decoder compiles to a
static Faust program. It is written to the project's existing culture: **every
item ships with an acceptance gate** in the style of the current suite
(`test/run.sh` gates 1–7 offline, A–E streaming), and nothing lands unless the
gate is green and the change is honestly characterized.

## Where things stand (v0.2.0)

| Subsystem | State | Evidence |
|---|---|---|
| Offline codec (`analyzer`/`render`/`freeze` → Faust) | shipped | null −260.7 dBFS; M0 tonal active-LSD 1.55 dB; offline pursuit residual −43.6 dB |
| Streaming profile (commit-horizon MP, QSS container) | shipped | gate A bit-exact; gate B bridge→Faust −272.6 dBFS; gate C corrupt re-anchor |
| Entropy coding (QSS2 = Rice + quantization) | shipped | 270→86 kbps (3.1×); gate D codec round-trip; gate E rate+fidelity |
| Latency presets (live/near/relaxed, cap-scaled rate) | shipped | monotonic 98/83/64 kbps at ~1.8–2.2 dB atoms-LSD |

**Honest open edges** carried into this roadmap: the residual is a noise model
that mis-serves pure-tone content at decode; the QSS packet transport is not yet
bound to DCF/HydraMesh; the causal per-frame residual trim proven in streaming
has not been backported to the offline analyzer; the good-case (percussive/
speech) fidelity is asserted but not published; and the bitstream is not yet
version-frozen for third-party interop.

---

## Horizon 1 — Codec quality & the transport binding (next)

The two items that most change the product: make it *sound right by default*, and
make packets *move* over the DeMoD stack.

### 1.1 Content-adaptive residual (tonal-aware envelope) — **P0, S–M, low risk**
- **Problem.** On tonal frames the pursuit leaves ~−20 dB energy that the residual
  models as band-limited noise; at correct energy this still raises the noise
  floor in spectral valleys (the 24 dB-LSD artifact; offline sidesteps it with
  `--g2 0`).
- **Approach.** Per residual frame, compute a tonality/flatness measure (spectral
  flatness of the pre-residual `r`, or atom-energy vs residual-energy ratio) and
  scale the band gains *in the encoder* before `qsc_gain_q`. Purely encoder-side:
  no QSS2 format change, no decoder change, bridge/Faust untouched.
- **Effort.** Small. Touches `flush_to` in `src/stream.c` and the offline
  analyzer's residual pass for parity.
- **Gate F.** On the tonal corpus, full-decode active-LSD within ~1 dB of
  atoms-only; on a broadband corpus, residual-on still *beats* residual-off
  (proving it didn't just mute the residual). Existing gates A–E unaffected.

### 1.2 DCF / HydraMesh transport binding — **P0, M, medium risk**
- **Problem.** QSS packets are self-delimiting and CRC-guarded but not yet framed
  onto the 17-byte DeModFrame or a HydraMesh datagram.
- **Approach.** Two adapters sharing one fragmentation layer: (a) **datagram
  mode** — one QSS packet per UDP 7777 payload (packets already ≤ MTU at these
  rates); (b) **DeModFrame mode** — fragment a packet across 17-byte frames with
  a fragment header (packet-id, frag-index, last-flag) riding the DCF retract.
  Reuse the existing `qss_crc16`; lean on DCF's `serialize∘deserialize = id`.
- **Effort.** Medium. New `src/qss-dcf.c` (pack/unpack), a loopback harness.
- **Gate G.** Encode → fragment → (lossy channel sim: drop/reorder/dup) →
  reassemble → `stream-decode` equals the direct-file decode on clean channel;
  under loss, only the affected packets drop and the stream re-anchors (extends
  gate C to the transport layer).

### 1.3 Backport causal band-coherence trim to offline — **P1, S, low risk**
- **Problem.** The streaming residual's per-frame `√(E/gᵀCg)` trim is causal *and*
  strictly better than the offline global scalar; offline still uses the scalar.
- **Approach.** Swap the offline analyzer's residual scaling for the per-frame
  trim (same `qsc_band_coherence` matrix). Re-baseline offline gates.
- **Effort.** Small, but it moves a reference — do it deliberately with a
  changelog entry and new golden vectors.
- **Gate.** Offline null still ≤ −120 dBFS; M0 active-LSD ≤ current; document the
  new residual-on LSD as the baseline.

---

## Horizon 2 — Bitrate & perceptual efficiency

Push past 86 kbps and toward a tunable quality knob.

### 2.1 Range/arithmetic coder over Rice — **P1, M, medium risk**
- **Approach.** Replace per-block Rice with a byte-wise range coder + small
  adaptive context models (separate contexts for onset-Δ, freq-q, amp-q,
  phase-q, gain-Δ). Keep Rice as the fallback/debug path.
- **Expected.** ~10–25% over Rice on the same symbols.
- **Gate.** Round-trip (extend gate D); bitrate strictly below the Rice path on
  the corpus; decode remains bit-exact (coder is lossless).

### 2.2 Residual band-sparsity / run-length — **P2, S, low risk**
- **Approach.** Many bands sit at the −144 dB floor; code a per-frame active-band
  mask + RLE of floor runs before the gain-Δ block.
- **Gate.** Lossless (gains bit-identical, as in the current `gcmp` check);
  measurable residual-section shrink.

### 2.3 Psychoacoustic bit allocation — **P2, L, high risk**
- **Approach.** A masking model (bark-band spread, tonal/noise masker split) to
  (a) drop atoms below threshold and (b) allocate residual bits by audibility.
  This is where "transparent at N kbps" claims get earned.
- **Risk.** Needs listening validation, not just LSD; budget for that.
- **Gate.** Blinded ABX on a small panel + objective (PEAQ-like or ViSQOL if
  available) — not LSD alone. A new class of gate for the project.

### 2.4 VBR + `--quality` target — **P1, S, low risk (after 2.1)**
- **Approach.** Replace fixed `--rate` with a quality target driving per-block
  atom budget (RD-style: add atoms until marginal SNR gain < threshold).
- **Gate.** At a fixed `--quality`, LSD variance across corpora within a band;
  bitrate adapts to content.

---

## Horizon 3 — Reach: channels, speech, real-time, hardware

### 3.1 Real-time reference player — **P1, M, medium risk**
- **Problem.** `stream-decode` decodes a whole file; the residual env interp
  needs one `residual_hop` (~5.3 ms) of lookahead for a true live player.
- **Approach.** A ring-buffered player consuming packets from a socket/pipe with
  the documented +1-frame output latency; JACK/ALSA sink.
- **Gate.** Live-decoded output equals file-decoded output to bit-exact for a
  clean stream; measured end-to-end latency matches the L + residual model.

### 3.2 Stereo / multichannel — **P2, M, medium risk**
- **Approach.** Mid-side or a shared voice pool with per-channel residual;
  QSS header gains a channel count; packets tag channel or interleave.
- **Gate.** Per-channel null bit-exact vs a two-mono baseline; joint coding beats
  dual-mono on correlated material.

### 3.3 Speech mode — **P2, M, medium risk**
- **Context.** Early design mirrors Codec2 700C frame layout; the physical-model
  vocal work (`demod_voice`) is adjacent.
- **Approach.** A low-rate profile: glottal + formant residual priors, fixed
  frame layout, aggressive quantization.
- **Gate.** Intelligibility (transcription WER on a clip set) at target rate;
  bitrate ≤ speech-codec ballpark.

### 3.4 RISC-V decode profiling — **P1, S, low risk**
- **Problem.** Decode is claimed real-time (≤25% U74 core at P=64); measure it.
- **Approach.** Cross-compile `stream-decode`/frozen Faust for JH7110 (U74),
  cycle-count the hot path; confirm the ftz/no-fma numeric contract holds on
  RV64GC. Feeds the `demod_audio` peripheral IP story.
- **Gate.** Measured cycles/sample ≤ budget at P=64; numeric null vs x86 within
  the documented libm-tolerance (freeze path already avoids libm in the hot loop).

---

## Horizon 4 — Interop, hardening, and the bitstream freeze

### 4.1 Bitstream v1 freeze + reference vectors — **P0 once H1 lands, S, low risk**
- **Approach.** Version the QSS2 stream (header already carries room), publish
  canonical `.qss` + expected `.f64` decode vectors, and a `CHANGELOG`/conformance
  note. This is the gate to any third-party encoder/decoder.
- **Gate.** A from-spec decoder (even a slow Python one) reproduces the reference
  vectors; the spec Appendix S is sufficient to reimplement without the source.

### 4.2 Fuzzing the packet reader — **P1, S, low risk**
- **Approach.** libFuzzer/AFL over `qss2_next_packet` and `qss_read_header`
  (ASan/UBSan, already the house style). Adversarial truncation, bad lengths,
  CRC collisions, sync-word injection.
- **Gate.** No OOB/UB on any input; malformed streams degrade to dropped packets,
  never crash (hardens gate C into a security property).

### 4.3 Conformance corpus expansion — **P2, S, low risk**
- **Approach.** Grow beyond the tonal probe: percussive (generator exists),
  speech, mixed music, silence/edge cases; publish the fidelity curve promised in
  the writeup.
- **Gate.** Per-corpus LSD/rate table checked into `docs/`, regenerated by CI.

---

## Horizon 5 — Legal / IP / productization (founder track)

Runs in parallel; several items gate *how* the tech ships, not whether it works.

### 5.1 Prior-art & patentability memo — **P1, M**
- The streaming novelty is the **commit-horizon block MP with coarse-to-fine
  maturity** + the **QSS framed container with voice-free deterministic
  re-derivation**. The JANUS/GRAME analysis already narrowed the modem white
  space; do the analogous pass for the *codec* claims (Gabor/matching-pursuit
  audio coding is old; the Faust-frozen-decoder + commit-horizon streaming is the
  defensible angle). Decide provisional vs trade-secret vs defensive-publication
  before any public bitstream freeze (4.1), since publication starts clocks.
- **Deliverable.** A short memo: claim candidates, closest prior art, filing vs
  publish recommendation.

### 5.2 Licensing posture — **P1, S**
- Current headers are `GPL-3.0-only OR LicenseRef-DeMoD-Commercial`. Confirm the
  dual-license is clean across all files (including generated Faust output and the
  `arch/` harness), and that the Faust runtime/license-scan gate used elsewhere in
  DeMoD applies to shipped decoders.
- **Deliverable.** License audit note; SPDX consistency check in CI.

### 5.3 Marketplace / product integration — **P2, M**
- How the codec rides the DeMoD Marketplace / Terminus (first-party hardware DSP,
  Faust patch channel) and the ArchibaldOS/IVI stack. Ties decode-CPU budget
  (3.4) to the target hardware.
- **Deliverable.** Integration one-pager: where QSS sits relative to DCF/HydraMesh
  and the Faust decoder artifact in a shipping product.

---

## Suggested sequence (dependency-aware)

```
Now  ──► 1.1 tonal residual ─┬─► 1.3 offline backport ──► 4.1 bitstream freeze ──► 5.x IP/license
         1.2 DCF transport ──┘                              │
                                                            ├─► 2.1 range coder ──► 2.4 VBR/quality
2.2 residual RLE (anytime) ─────────────────────────────────┤
3.4 RISC-V profiling (anytime, informs product) ────────────┤
4.2 fuzzing (before/with freeze) ───────────────────────────┘
Later ► 2.3 psychoacoustics, 3.1 realtime player, 3.2 stereo, 3.3 speech
```

**Rationale.** 1.1 and 1.2 are the highest product leverage and are low/medium
risk on a now-stable format. 1.3 + 4.1 lock a clean, documented reference before
any third party (or patent clock) touches the bitstream — which is why the IP/
license track (5.1–5.2) is sequenced right after the freeze, not before. Bitrate
work (H2) and reach (H3) build on that frozen base. Psychoacoustics (2.3) is
deliberately last of the near-term set: it's the highest-value *and* highest-risk
item because it can't be signed off on LSD alone.

## Sizing legend
`S` ≈ a focused session · `M` ≈ a few sessions · `L` ≈ a sustained effort with a
new validation method. `P0` blocks product; `P1` high value; `P2` opportunistic.
