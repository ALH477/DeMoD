# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# Network and CPU isolation configuration for DCF-Snake spoke node
#
# Configures:
# - CPU isolation via isolcpus for real-time audio processing
# - Network interface setup for raw L2 transport
# - Kernel parameters for low-latency audio

{ config, lib, ... }:

with lib;

let
  cfg = config.services.snake-spoke;
in {
  # ── CPU isolation for real-time audio ──────────────────────────────────
  # Isolate the configured core from the kernel scheduler
  # This prevents the kernel from scheduling regular tasks on this core
  boot.kernelParams = [
    "isolcpus=${toString cfg.isolatedCore}"
    "nohz_full=${toString cfg.isolatedCore}"
    "rcu_nocbs=${toString cfg.isolatedCore}"
  ];

  # ── Network interface configuration ────────────────────────────────────
  # Ensure the network interface is up and configured
  # snake_source needs the interface to be up for AF_PACKET sockets
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
    # Helps with shared memory ring buffer writes
    "vm.dirty_ratio" = 10;
    "vm.dirty_background_ratio" = 5;

    # Disable NUMA balancing (not relevant for single-core RT)
    # Prevents automatic page migration that could cause latency
    "kernel.numa_balancing" = 0;
  };

  # ── Kernel modules for raw sockets ─────────────────────────────────────
  # Ensure af_packet module is loaded for AF_PACKET/SOCK_RAW
  boot.kernelModules = [ "af_packet" ];

  # ── Systemd resource control ───────────────────────────────────────────
  # Ensure the isolated core is not used by other services
  systemd.services.demod-rt.serviceConfig.CPUAffinity = toString cfg.isolatedCore;

  # ── Firewall configuration ─────────────────────────────────────────────
  # Raw L2 transport uses EtherType 0x88B5 (record) and 0x88B6 (cue)
  # These are not IP-based, so firewall rules don't apply
  # However, ensure the interface is not blocked by network policies
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];

  # ── Shared memory limits ───────────────────────────────────────────────
  # Ensure /dev/shm can hold the SPSC rings
  # Each ring: sizeof(SnakeSpsc) + 65536 * sizeof(float) ≈ 262KB
  # For spoke: 1 TX ring = ~262KB
  # Add headroom for future expansion
  boot.kernel.sysctl."kernel.shmmax" = 67108864;  # 64MB
  boot.kernel.sysctl."kernel.shmall" = 16384;       # 16384 pages (64MB / 4KB)

  # ── Power management ───────────────────────────────────────────────────
  # Disable CPU frequency scaling on the isolated core
  # Prevents frequency transitions that cause latency spikes
  # Note: This requires cpufreq driver support
  powerManagement.cpuFreqGovernor = mkDefault "performance";

  # ── Logging ────────────────────────────────────────────────────────────
  # Increase journal rate limit for RT audio debugging
  services.journald.rateLimitBurst = 10000;
  services.journald.rateLimitInterval = "30s";
}
