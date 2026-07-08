# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# Network and CPU isolation configuration for DCF-Snake hub node
#
# Configures:
# - Multi-core CPU isolation via isolcpus for real-time audio processing
# - Network interface setup for raw L2 transport (EtherType 0x88B5/0x88B6)
# - Kernel parameters for low-latency audio
# - Shared memory limits for hub mode (maxSources * 2 rings)

{ config, lib, ... }:

with lib;

let
  cfg = config.services.snake-hub;
  isolatedCoresStr = concatStringsSep "," (map toString cfg.isolatedCores);

  # Calculate shared memory requirements
  # Each ring: sizeof(SnakeSpsc) + 65536 * sizeof(float) ≈ 262KB
  # Hub needs: maxSources * 2 rings (src + cue)
  # Total: maxSources * 524KB, add 50% headroom
  shmSizeMB = builtins.ceil (cfg.maxSources * 524 * 1.5 / 1024);

in {
  # ── Multi-core CPU isolation for real-time audio ───────────────────────
  # Isolate multiple cores from the kernel scheduler
  # Hub mode uses multiple cores: one for demod-rt, others for snake_mixer
  # This prevents the kernel from scheduling regular tasks on these cores
  boot.kernelParams = [
    "isolcpus=${isolatedCoresStr}"
    "nohz_full=${isolatedCoresStr}"
    "rcu_nocbs=${isolatedCoresStr}"
  ];

  # ── Network interface configuration ────────────────────────────────────
  # Ensure the network interface is up and configured
  # snake_mixer needs the interface to be up for AF_PACKET sockets
  # Record plane: EtherType 0x88B5 (spoke → hub)
  # Cue plane: EtherType 0x88B6 (hub → spoke)
  systemd.network.enable = mkDefault true;

  systemd.network.networks."10-${cfg.interface}" = {
    matchConfig.Name = cfg.interface;
    networkConfig.DHCP = mkDefault "yes";
    linkConfig.RequiredForOnline = mkDefault "routable";
  };

  # ── Kernel parameters for low-latency audio ────────────────────────────
  boot.kernel.sysctl = {
    # Disable RT bandwidth limiting
    # Allows RT tasks to run indefinitely without being throttled
    # Critical for SCHED_FIFO audio processing
    "kernel.sched_rt_runtime_us" = -1;

    # Reduce swappiness to minimize swap activity
    # RT audio should stay in RAM
    "vm.swappiness" = 10;

    # Increase dirty page ratio for better write performance
    # Helps with shared memory ring buffer writes and recording output
    "vm.dirty_ratio" = 10;
    "vm.dirty_background_ratio" = 5;

    # Disable NUMA balancing (not relevant for multi-core RT on same socket)
    # Prevents automatic page migration that could cause latency
    "kernel.numa_balancing" = 0;

    # Increase shared memory limits for hub mode
    # Hub needs: maxSources * 2 rings * 262KB ≈ maxSources * 524KB
    # Add 50% headroom for safety
    "kernel.shmmax" = shmSizeMB * 1024 * 1024;
    "kernel.shmall" = builtins.ceil (shmSizeMB * 1024 * 1024 / 4096);
  };

  # ── Kernel modules for raw sockets ─────────────────────────────────────
  # Ensure af_packet module is loaded for AF_PACKET/SOCK_RAW
  boot.kernelModules = [ "af_packet" ];

  # ── Systemd resource control ───────────────────────────────────────────
  # Ensure the isolated cores are not used by other services
  # demod-rt gets the first core, snake_mixer gets the rest
  systemd.services.demod-rt-hub.serviceConfig.CPUAffinity =
    toString (builtins.head cfg.isolatedCores);

  systemd.services.snake-mixer.serviceConfig.CPUAffinity =
    if builtins.length cfg.isolatedCores > 1
    then concatStringsSep "," (map toString (builtins.tail cfg.isolatedCores))
    else toString (builtins.head cfg.isolatedCores);  # fallback: share core

  # ── Firewall configuration ─────────────────────────────────────────────
  # Raw L2 transport uses EtherType 0x88B5 (record) and 0x88B6 (cue)
  # These are not IP-based, so firewall rules don't apply
  # However, ensure the interface is not blocked by network policies
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];

  # ── Power management ───────────────────────────────────────────────────
  # Disable CPU frequency scaling on the isolated cores
  # Prevents frequency transitions that cause latency spikes
  # Note: This requires cpufreq driver support
  powerManagement.cpuFreqGovernor = mkDefault "performance";

  # ── Logging ────────────────────────────────────────────────────────────
  # Increase journal rate limit for RT audio debugging
  # Hub processes multiple sources, so more log volume
  services.journald.rateLimitBurst = 10000;
  services.journald.rateLimitInterval = "30s";
}
