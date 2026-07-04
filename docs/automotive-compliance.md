<!-- SPDX-License-Identifier: MPL-2.0 -->
# Automotive safety & compliance posture (DeMoD Auto)

**This is engineering documentation, not legal advice.** It records the safety/privacy defaults the
FOSS framework ships and — following the way Automotive Grade Linux, openpilot, and comma.ai allocate
duties — assigns certification and compliance obligations to the **integrator** who builds a physical
head unit. Verify any statute/standard against current official texts before relying on it.

## Who bears what (duties attach to your role in the stream of commerce, not to who wrote the code)

| Regime | Upstream FOSS author (this repo) | Integrator / device maker | Installer / owner |
|--------|----------------------------------|---------------------------|-------------------|
| **FMVSS 111** rear visibility | No (publishing code isn't making equipment) | **Yes** — validate the rear camera | Installer via §30122 |
| **FMVSS 101** controls/displays | No | **Yes** | — |
| NHTSA distraction guidelines (voluntary) | design target | design target | — |
| **FCC Part 15** (Bluetooth/Wi-Fi radios) | No (FCC certifies devices, not source) | **Yes** — module + finished-device cert | — |
| **EPA** Clean Air Act (tampering) | Only if it writes emissions params (it doesn't) | Yes if it ships a defeat device | Installer/tuner |
| **49 U.S.C. §30122** make-inoperative | No | **Yes** | Businesses yes; individual owner no |
| **FTC §5 / state privacy** | No (never touches consumer data) | The data **controller/operator** | — |
| **BIS** connected-vehicle rule | Minimal (US author, open supply chain) | Yes (importer / CV manufacturer) | — |
| **Product liability** (tort) | Weak (software isn't a "product"; non-commercial) | Yes (commercial seller) | — |

The single most favorable fact: **a pure FOSS framework that others integrate** sits in the safest
position — nearly every binding US duty attaches to a physical device, a commercial seller, or a data
operator. That posture changes the moment anyone **sells hardware, offers a hosted data service, or
ships flashable end-vehicle binaries** (see "If you commercialize").

## What the framework ships (safety/privacy by default)

These are wired into DeMoD Auto + the companion-shell SDK today:

1. **Non-preemptible rear camera (FMVSS 111).** `auto/surfaces/camera.lua` is a `safety` surface. On
   reverse (`$DEMOD_REVERSE` / a reverse-line GPIO → the provider's `reverse` flag), the shell's
   `priority()` hook **forces** it and blocks navigation away from it — it cannot be crashed, delayed,
   or preempted by entertainment. It blits the live camera (`auto/camera.sh`, ffmpeg V4L2) with parking
   guidelines. This directly targets the failure mode NHTSA recalled (an infotainment reboot killing
   the rear image).
2. **Motion lockout (state distraction law / NHTSA 2-12).** The shell gates any surface marked
   `restricted` (e.g. MEDIA) above a speed threshold (`lockout_kmh`, default 8), showing a "PULL OVER"
   screen and ignoring its input — while **exempting** the cluster, nav, camera, and config (mirroring
   CVC §27602's interlock exemption). **On by default** (`lockout` config key).
3. **Data-minimization.** No telematics is collected or transmitted by default. The DCF mesh is
   strictly opt-in (`$DEMOD_DCF_HOST`), local-first, and off unless configured. The rear camera is
   captured **only when a camera is explicitly configured** (`$DEMOD_CAMERA_DEV`/test mode) — it never
   auto-grabs an arbitrary `/dev/video*`.
4. **Read-only OBD/CAN.** `auto/vehicle/obd2-reader.py` only issues standard mode-01 read PIDs + `ATRV`.
   There is **no write path** and no capability to modify emissions-related parameters (Clean Air Act).
5. **No end-user RF control.** The framework exposes no Bluetooth/Wi-Fi power/frequency controls, so it
   can't turn a certified module into an unapproved software-defined radio (47 CFR §2.944).

## Integrator responsibilities (you, if you build a product)

Building a shippable head unit means **you** own: FCC equipment authorization of the finished device
and any radios; **FMVSS 111** rear-camera validation on the target vehicle; §30122 (don't disable a
compliant safety device by swapping in your unit); tuning the motion-lockout speed/threshold to your
state's distraction law; ISO 26262 (functional safety) and ISO/SAE 21434 (cybersecurity) processes as
demanded by OEMs/Tier-1s and as the de-facto standard of care; and, if you import/sell connected
vehicles ≤10,000 lbs, BIS Declaration-of-Conformity due diligence. The framework gives you the safety
hooks; wiring them to a certified, validated product is your job.

## Posture

- **Research / non-commercial framing, AS-IS, no warranty.** The code is provided under MPL-2.0 with no
  warranty; it is a framework for research and integration, not a finished aftermarket product. The
  no-warranty/license terms reliably defeat licensee warranty claims; the stronger protections are
  structural (software isn't a "product," a non-commercial author isn't a "commercial seller"). The
  strongest single move is **not selling finished head units yourself.**
- **Export.** The DCF/HydraMesh transport avoids built-in cryptography to stay export-control-free
  (EAR/ITAR); adding cryptography can re-trigger classification — revisit before doing so.

## If you commercialize

The moment you sell hardware, run a hosted data service, or ship flashable end-vehicle binaries, the
risk flips: you may become an FCC responsible party, a NHTSA equipment manufacturer (recall/TREAD
duties), a privacy "controller," and a "commercial seller" for strict product liability. Before that
step: stand up ISO 26262 / ISO/SAE 21434 processes, obtain FCC certification for any radio product, and
get product-liability insurance. **Change your posture** if: NHTSA opens any Special Order or defect
inquiry (the comma.ai signal → pause device shipment); the federal REPAIR Act becomes law (new
data-access duties); the next DMCA §1201 triennial (~2026) narrows the vehicle-modification exemption
(reassess before Oct 28 2027); or you sell connected vehicles by MY2027 (BIS conformity).
