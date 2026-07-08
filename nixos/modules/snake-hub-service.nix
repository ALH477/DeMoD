# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# Systemd services for DCF-Snake hub node
#
# Two services:
# 1. snake_mixer: Reads raw L2 from spokes (EtherType 0x88B5), writes to
#    /demod-snake-src-{N} rings, reads /demod-snake-cue-{N} rings,
#    sends cue mix back to spokes via raw L2 (EtherType 0x88B6).
#    SCHED_FIFO priority 70.
#
# 2. demod-rt-hub: Reads from /demod-snake-src-{N} rings (one per source),
#    processes audio, writes cue mix to /demod-snake-cue-{N} rings.
#    SCHED_FIFO priority 80 (highest in the stack).

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.snake-hub;
  demod-rt = cfg.package;
  snake_mixer = cfg.snakeMixerPackage;

  # CPU core assignment: first core for demod-rt, rest for snake_mixer
  demodCore = builtins.head cfg.isolatedCores;
  mixerCores = builtins.tail cfg.isolatedCores;
  mixerCoreStr = if mixerCores != []
    then concatStringsSep "," (map toString mixerCores)
    else toString demodCore;  # fallback: share demod's core

  # Build snake_mixer command line
  snake-mixer-args = [
    "--shm"
    "--iface" cfg.interface
    "--channel" cfg.channel
    "--out" "${cfg.outputDir}/${cfg.outputFile}"
  ] ++ optional cfg.noQuanta "--no-quanta";

  # Build demod-rt command line (hub mode)
  demod-rt-args = [
    "--hub" (toString cfg.maxSources)
    "--core" (toString demodCore)
  ];

  # Generate tmpfiles rules for shared memory rings
  # Source rings: /demod-snake-src-{0..N-1}
  # Cue rings: /demod-snake-cue-{0..N-1}
  srcRingRules = genList (n:
    "f /dev/shm/demod-snake-src-${toString n} 0666 root root -"
  ) cfg.maxSources;

  cueRingRules = genList (n:
    "f /dev/shm/demod-snake-cue-${toString n} 0666 root root -"
  ) cfg.maxSources;

in {
  # ── snake_mixer service (hub) ──────────────────────────────────────────
  # Starts first: sets up raw L2 listeners, creates shared memory rings
  systemd.services.snake-mixer = {
    description = "DCF-Snake Mixer (Hub Mode)";
    documentation = [ "man:snake_mixer" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "systemd-tmpfiles-setup-dev.service" ];
    wants = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${snake_mixer}/bin/snake_mixer ${escapeShellArgs snake-mixer-args}
      '';

      # Real-time scheduling: SCHED_FIFO priority 70
      # Below demod-rt (80) but above JACK (50)
      LimitRTPRIO = "infinity";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 65536;

      # Security hardening
      NoNewPrivileges = false;  # Need capabilities for RT + network
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = false;  # Need /dev/shm access
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = false;
      LockPersonality = true;
      RestrictRealtime = false;  # We ARE a realtime process
      RestrictNamespaces = true;

      # Recording output directory
      StateDirectory = "snake-hub";
      ReadWritePaths = [ cfg.outputDir ];

      # Restart policy
      Restart = "on-failure";
      RestartSec = "5s";
      WatchdogSec = "30s";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "snake_mixer";
    };

    # Grant CAP_NET_RAW for AF_PACKET/SOCK_RAW (EtherType 0x88B5/0x88B6)
    # Grant CAP_SYS_NICE for SCHED_FIFO 70
    ambientCapabilities = [ "CAP_NET_RAW" "CAP_SYS_NICE" ];

    # Resource control: pin to mixer cores
    unitConfig = {
      CPUAffinity = mixerCoreStr;
    };
  };

  # ── demod-rt service (hub mode) ────────────────────────────────────────
  # Starts after snake_mixer: reads from source rings, writes cue rings
  systemd.services.demod-rt-hub = {
    description = "DeMoD RT Audio Engine (Hub Mode)";
    documentation = [ "man:demod-rt" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "snake-mixer.service" "network.target" ];
    requires = [ "snake-mixer.service" ];
    bindsTo = [ "snake-mixer.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${demod-rt}/bin/demod-rt ${escapeShellArgs demod-rt-args}
      '';

      # Real-time scheduling: SCHED_FIFO priority 80
      # Highest priority in the hub audio stack
      LimitRTPRIO = "infinity";
      LimitMEMLOCK = "infinity";  # mlockall() for RT audio
      LimitNOFILE = 65536;

      # Security hardening
      NoNewPrivileges = false;  # Need capabilities for RT
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = false;  # Need /dev/shm access
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = false;  # JIT may be needed for Faust
      LockPersonality = true;
      RestrictRealtime = false;  # We ARE the realtime process
      RestrictNamespaces = true;

      # Restart policy
      Restart = "on-failure";
      RestartSec = "5s";
      WatchdogSec = "30s";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "demod-rt-hub";
    };

    # Grant CAP_SYS_NICE for SCHED_FIFO 80
    ambientCapabilities = [ "CAP_SYS_NICE" ];

    # Resource control: pin to isolated core (highest priority)
    unitConfig = {
      CPUAffinity = toString demodCore;
    };
  };

  # ── Shared memory setup ────────────────────────────────────────────────
  # Pre-create shared memory rings for inter-process communication
  # Each ring: sizeof(SnakeSpsc) + 65536 * sizeof(float) ≈ 262KB
  # Total: maxSources * 2 rings (src + cue) ≈ maxSources * 524KB
  systemd.tmpfiles.rules =
    srcRingRules ++
    cueRingRules ++
    [
      # Ensure the output directory exists with proper permissions
      "d ${cfg.outputDir} 0755 root root -"
    ];

  # Increase /dev/shm size for hub mode
  # Hub needs: maxSources * 2 rings * 262KB ≈ maxSources * 524KB
  # Default 5 sources = ~2.6MB, add headroom
  boot.tmp.tmpfsSize = "512M";
}
