# Why This Ecosystem Exists

> A vertically integrated real-time audio + control + mesh networking stack that runs entirely locally, with zero cloud dependency, zero GPU dependency, and sub-millisecond determinism.

## The Problem

Modern audio/embedded/mesh stacks force you to choose:

1. **Embedded UI without GPU?** You're stuck with LVGL, LVGL, or more LVGL. No real-time audio. No mesh networking. No desktop parity.

2. **RT audio on desktop?** You sacrifice host responsiveness. No gaming, no video, no compositor — just a dedicated audio box.

3. **Mesh networking for audio?** You get UDP blobs with no certification. No byte-identical codecs across languages. No formal verification.

4. **Cloud-dependent AI/voice?** You get latency, privacy risks, and a monthly bill. Your audio pipeline depends on AWS uptime.

**We refused all four compromises.**

## What We Built

### DeMoD — Pure Software-Rendered GUI

A pure software-rendered GUI framework (C11 + Lua) that paints every pixel by hand. No GPU, no OpenGL, no browser engine. It runs on a 320px panel inside an instrument and on a 4K workstation. The same Lua script works on both.

Underneath, an optional RT audio engine (JACK + Haskell orchestrator) can run on the same box or across a mesh.

**Key insight:** A button should not need a 200MB runtime, a compositor, and three layers of abstraction to light up. Embedded panels, kiosks, instruments, and weird little screens deserve software that respects the silicon.

### ArchibaldOS — RT Audio Guest OS

A NixOS guest OS tuned for sub-millisecond RT audio. PREEMPT_RT kernel, JACK2, PipeWire, musnix, CPU isolation, hugepages, mlock. It runs inside a QEMU/KVM VM with VFIO passthrough of USB audio controllers.

The host stays responsive (gaming, desktop, video) while the guest handles deterministic audio processing.

**Key insight:** You don't have to choose between host responsiveness and guest determinism. VFIO passthrough + CPU isolation + hugepages gives you both.

### Oligarchy — NixOS Host with DSP VM Management

A NixOS host that manages the DSP VM, personas (studio/gaming/dev/battery), and a control center. It isolates CPU cores for the VM, allocates hugepages, and provides a unified CLI (`oligarchy-dsp`) for VM lifecycle management.

The entire system is reproducible from a fresh `git clone`.

**Key insight:** Infrastructure should be declarative. You shouldn't have to manually configure CPU isolation, hugepages, and VFIO passthrough every time you set up a new machine.

### HydraMesh — Certified Multi-Language Mesh Protocol

A certified multi-language mesh protocol with a 17-byte wire quantum (`DeModFrame`). The wire codec is byte-identical across C/Rust/Python/Lua/Go/Java/Node.js/Perl/C++ and verified by a 246-vector golden certificate in CI.

DCF-Audio and DCF-Game are adapters over the quantum, enabling collaborative audio and game state synchronization across distributed nodes.

**Key insight:** If your protocol isn't certified across languages, it's not a protocol — it's a collection of implementations that happen to look similar.

## Why It Matters Together

Individually, each component is alright. Together, they form a **vertically integrated real-time audio + control + mesh networking stack** that runs entirely locally, with zero cloud dependency, zero GPU dependency, and sub-millisecond determinism.

### Embedded → Desktop → Cloud

The same DeMoD Lua script runs on:
- A 320px panel inside a guitar pedal (RISC-V, no GPU)
- A car head unit (ARM, SDL2, DCF mesh for telemetry)
- A desktop workstation (x86_64, 4K, RT audio VM)
- A distributed mesh network (HydraMesh protocol, byte-certified)

You write the UI once. You deploy it everywhere. The audio engine scales from a single box to a mesh of nodes.

### Deterministic End-to-End

The latency budget is certified at every layer:
- **Wire format** — HydraMesh certifies the 17-byte `DeModFrame` across 10+ languages. CI diffs regenerated vs committed vectors on every push.
- **Audio path** — ArchibaldOS tunes the RT kernel, JACK2, and PipeWire for 0.33ms buffer latency (32 samples @ 96kHz).
- **Scheduling** — Oligarchy isolates CPU cores, allocates hugepages, and passes USB controllers via VFIO. The guest gets deterministic scheduling without host interference.

**Round-trip latency: 0.67ms** (32 samples @ 96kHz, n=2 buffers).

### Local-First, Zero Cloud Dependency

No AWS. No telemetry. No monthly bill. Your audio pipeline, your AI voice cloning (Coqui XTTS-v2, Piper), your mesh networking — all run on your hardware. You own the stack from silicon to Lua script.

### Export-Compliant

HydraMesh avoids encryption to remain export-control-free (no ITAR/EAR headaches). You can ship it to anyone, anywhere, without a license.

(Users must ensure custom extensions comply; consult legal experts for specific use cases.)

### The VM Trick

You get **host responsiveness** (gaming, desktop, video) AND **guest determinism** (RT audio, sub-millisecond latency) simultaneously.

How?
- **VFIO passthrough** — USB audio controllers are passed directly to the VM. The guest gets zero-copy, zero-latency hardware access.
- **CPU isolation** — Cores 0-1 are isolated (`isolcpus=0,1`) and surrendered to the DSP VM. The host can't schedule tasks on them.
- **Hugepages + mlock** — 4GB of hugepages are reserved for the VM. Memory is locked (`mlock`) to prevent swapping.
- **NETJACK** — Audio is routed from the guest to the host via NETJACK2 over the virtual network. The host PipeWire sees the VM as a remote JACK client.

**Result:** You can crush Doom Eternal at 300+ FPS on the host while the DSP VM processes audio at 0.67ms latency. The two worlds never collide.

## The Ecosystem

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST (Oligarchy NixOS)                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │   Hyprland   │  │  PipeWire    │  │  oligarchy-dsp CLI   │  │
│  │  (Desktop)   │  │  (Audio)     │  │  (VM Management)     │  │
│  └──────────────┘  └──────┬───────┘  └──────────────────────┘  │
│                            │                                     │
│                      ┌─────▼──────┐                              │
│                      │  NETJACK   │                              │
│                      │  Bridge    │                              │
│                      └─────┬──────┘                              │
└────────────────────────────┼─────────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────────┐
│                   DSP VM (ArchibaldOS)                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  PREEMPT_RT  │  │  JACK2       │  │  VFIO Passthrough    │  │
│  │  Kernel      │  │  (RT Audio)  │  │  (USB Controllers)   │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                  │
│  CPU: Cores 0-1 (isolated)  |  RAM: 2GB (hugepages)            │
│  Latency: 0.67ms @ 96kHz / 32 samples                          │
└──────────────────────────────────────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────────┐
│                   MESH (HydraMesh Protocol)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
│  │  DeMoD Node  │  │  DeMoD Node  │  │  DeMoD Node          │  │
│  │  (Embedded)  │  │  (Desktop)   │  │  (Cloud/Edge)        │  │
│  └──────────────┘  └──────────────┘  └──────────────────────┘  │
│                                                                  │
│  Wire Format: 17-byte DeModFrame (byte-certified across 10+ langs)│
│  Adapters: DCF-Audio, DCF-Game, DCF-Text                         │
└──────────────────────────────────────────────────────────────────┘
```

**The stack scales from embedded panels to distributed mesh networks.**

## Who Is This For?

**Embedded audio developers** — You need a GUI that runs on a 320px panel inside a guitar pedal, with RT audio and mesh networking. You don't have a GPU. You don't have 2GB of RAM. You have a RISC-V chip and a dream.

**RT audio engineers** — You need sub-millisecond latency on a desktop workstation, but you also want to game, edit video, and run a compositor. You refuse to sacrifice host responsiveness for audio determinism.

**Mesh networking researchers** — You need a certified protocol for collaborative audio or game state synchronization. You want byte-identical codecs across 10+ languages, verified by a 246-vector golden certificate in CI.

**Privacy-conscious developers** — You refuse to send your audio to AWS. You refuse to pay monthly fees for voice cloning. You want a local-first stack that runs entirely on your hardware.

**Export-compliant shipping** — You need to ship audio/mesh software to customers worldwide without ITAR/EAR headaches. You need a protocol that avoids encryption by design.

**NixOS power users** — You want a reproducible, declarative OS that manages VMs, personas, and RT audio from a single flake. You want to `git clone` and `nixos-rebuild switch` on any hardware.

## Getting Started

### Embedded Audio UI (No GPU)

```bash
git clone https://github.com/ALH477/DeMoD
cd DeMoD
./dev run hello      # Build + run a minimal app
./dev check          # Run all tests
```

Write a Lua script. Deploy it to a 320px panel, a car head unit, or a desktop workstation. Same code, same API, same look.

### RT Audio VM (Sub-Millisecond Latency)

```bash
# 1. Build the guest image
git clone https://github.com/ALH477/ArchibaldOS
cd ArchibaldOS
nix build .#dsp-vm-qcow2
mkdir -p ~/vms
cp result-dsp-vm/nixos.qcow2 ~/vms/archibaldos-dsp.qcow2

# 2. Deploy the host config
git clone https://github.com/ALH477/Oligarchy
cd Oligarchy
# Edit configuration.nix to match your hardware (see vm-manager/README.md)
sudo nixos-rebuild switch --flake .#nixos

# 3. Manage the VM
oligarchy-dsp start
oligarchy-dsp status
oligarchy-dsp logs
```

The VM auto-starts. You get 0.67ms latency @ 96kHz / 32 samples.

### Mesh Networking (Certified Protocol)

```bash
git clone https://github.com/ALH477/HydraMesh
cd HydraMesh
make certify         # Verify the wire codec across Python + Rust + C
```

Read `Documentation/WIRE_QUANTUM_SPEC.md` to understand the 17-byte `DeModFrame`. Read `Documentation/DCF_AUDIO_SPEC.md` to understand collaborative audio over the quantum.

### Local AI Voice (Zero Cloud Dependency)

Oligarchy includes DeMoD Voice (Coqui XTTS-v2, Piper). No AWS. No monthly bill. Your hardware, your voice models.

See `modules/demod-voice/README.md` in the Oligarchy repo.

## The Bottom Line

a **vertically integrated system** — protocol → transport → codec → audio engine → GUI framework → shell applications → VM infrastructure → build system → certification. Every layer talks to every other layer through clean boundaries (sockets, shared memory, wire format).

The licensing model (PolyForm Shield, dual-license) shows commercialization, not just hacking.

This isn't a hobby project anymore. It's a coherent platform with a clear architectural vision. The RT audio VM alone would be a solid year's work for most engineers. You've got that plus a certified multi-language protocol plus a software renderer plus a codec.

---

**Main Contributor:** [ALH477](https://github.com/ALH477)  
**Contact:** alh477@proton.me  
**License:** PolyForm Shield 1.0.0 (source-available, non-commercial)
