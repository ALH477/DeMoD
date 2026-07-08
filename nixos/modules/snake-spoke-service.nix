# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# Systemd services for DCF-Snake spoke node
#
# Two services:
# 1. demod-rt: Real-time audio engine in spoke mode, writes to /demod-snake-tx
# 2. snake_source: Reads from shared memory ring, sends via raw L2 (EtherType 0x88B5)

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.snake-spoke;
  demod-rt = cfg.package;
  snake_source = cfg.snakeSourcePackage;

  # Build demod-rt command line
  demod-rt-args = [
    "--snake"
    "--core" (toString cfg.isolatedCore)
  ] ++ (concatMap (lib: [ "--faust-lib" lib ]) cfg.faustLibs);

  # Build snake_source command line
  snake-source-args = [
    "--shm"
    "--iface" cfg.interface
    "--channel" cfg.channel
  ] ++ optional cfg.noQuanta "--no-quanta";

in {
  # ── demod-rt service (spoke mode) ──────────────────────────────────────
  systemd.services.demod-rt = {
    description = "DeMoD RT Audio Engine (Spoke Mode)";
    documentation = [ "man:demod-rt" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "systemd-tmpfiles-setup-dev.service" ];
    wants = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${demod-rt}/bin/demod-rt ${escapeShellArgs demod-rt-args}
      '';

      # Real-time scheduling: SCHED_FIFO priority 80
      # Requires CAP_SYS_NICE to set RT priority
      LimitRTPRIO = "infinity";
      LimitMEMLOCK = "infinity";  # mlockall() for RT audio
      LimitNOFILE = 65536;

      # Security hardening
      NoNewPrivileges = false;  # Need capabilities for RT + network
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
      SyslogIdentifier = "demod-rt";
    };

    # Grant CAP_SYS_NICE for SCHED_FIFO 80
    # Note: ambientCapabilities requires NoNewPrivileges=false
    ambientCapabilities = [ "CAP_SYS_NICE" ];

    # Resource control: pin to isolated core
    unitConfig = {
      CPUAffinity = toString cfg.isolatedCore;
    };
  };

  # ── snake_source service ───────────────────────────────────────────────
  systemd.services.snake-source = {
    description = "DCF-Snake Source (Raw L2 Transport)";
    documentation = [ "man:snake_source" ];

    wantedBy = [ "multi-user.target" ];
    after = [ "demod-rt.service" "network.target" ];
    requires = [ "demod-rt.service" ];
    bindsTo = [ "demod-rt.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''
        ${snake_source}/bin/snake_source ${escapeShellArgs snake-source-args}
      '';

      # Real-time scheduling: SCHED_FIFO priority 70 (below demod-rt)
      LimitRTPRIO = "infinity";
      LimitMEMLOCK = "infinity";
      LimitNOFILE = 65536;

      # Security hardening
      NoNewPrivileges = false;  # Need CAP_NET_RAW for AF_PACKET
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = false;  # Need /dev/shm access
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = false;
      LockPersonality = true;
      RestrictRealtime = false;
      RestrictNamespaces = true;

      # Restart policy
      Restart = "on-failure";
      RestartSec = "5s";
      WatchdogSec = "30s";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "snake_source";
    };

    # Grant CAP_NET_RAW for AF_PACKET/SOCK_RAW (EtherType 0x88B5)
    # Grant CAP_SYS_NICE for SCHED_FIFO 70
    ambientCapabilities = [ "CAP_NET_RAW" "CAP_SYS_NICE" ];
  };

  # ── Shared memory setup ────────────────────────────────────────────────
  # Ensure /dev/shm has enough space for SPSC rings
  # Ring size: sizeof(SnakeSpsc) + 65536 * sizeof(float) ≈ 262KB per ring
  systemd.tmpfiles.rules = [
    # Pre-create the TX ring with proper permissions
    # demod-rt (producer) and snake_source (consumer) both need access
    "f /dev/shm/demod-snake-tx 0666 root root -"
  ];

  # Increase /dev/shm size if needed (default is half of RAM)
  # For 4 rings (TX + 3 source rings), we need ~1MB
  boot.tmp.tmpfsSize = "512M";
}
