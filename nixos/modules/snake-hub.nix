# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# NixOS module for DCF-Snake hub node deployment (x86)
#
# Deploys snake_mixer + demod-rt (hub mode) with proper RT scheduling,
# multi-core CPU isolation, and raw L2 network transport.
#
# Architecture:
#   snake_mixer --shm → /demod-snake-src-{N} → demod-rt --hub N
#   demod-rt → /demod-snake-cue-{N} → snake_mixer → raw-L2 → spoke
#
# Network:
#   Record plane: EtherType 0x88B5 (spoke → hub)
#   Cue plane: EtherType 0x88B6 (hub → spoke)

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.snake-hub;
in {
  imports = [
    ./snake-hub-service.nix
    ./snake-hub-network.nix
  ];

  options.services.snake-hub = {
    enable = mkEnableOption "DCF-Snake hub node for x86 deployment";

    interface = mkOption {
      type = types.str;
      default = "eth0";
      description = ''
        Network interface for raw L2 transport.
        Record plane uses EtherType 0x88B5 (spoke → hub).
        Cue plane uses EtherType 0x88B6 (hub → spoke).
        Must support AF_PACKET/SOCK_RAW sockets.
      '';
      example = "enp3s0";
    };

    channel = mkOption {
      type = types.str;
      default = "snake";
      description = ''
        Snake channel name for network identification.
        Used to distinguish multiple snake networks on the same physical segment.
      '';
    };

    maxSources = mkOption {
      type = types.int;
      default = 5;
      description = ''
        Maximum number of spoke sources the hub will accept.
        Passed to demod-rt as --hub N. Determines the number of
        shared memory rings: /demod-snake-src-{0..N-1} and
        /demod-snake-cue-{0..N-1}.
      '';
      example = 8;
    };

    isolatedCores = mkOption {
      type = types.listOf types.int;
      default = [ 2 3 ];
      description = ''
        CPU cores to isolate for real-time audio processing.
        Hub mode uses multiple cores: one for demod-rt, others for
        snake_mixer and cue processing. These cores will be removed
        from the kernel scheduler via isolcpus.
      '';
      example = [ 4 5 6 ];
    };

    outputDir = mkOption {
      type = types.str;
      default = "/var/lib/snake-hub";
      description = ''
        Directory for recording output files.
        Created with proper permissions for the snake-hub service user.
      '';
      example = "/srv/recordings";
    };

    outputFile = mkOption {
      type = types.str;
      default = "record.raw";
      description = ''
        Output filename for mixed audio recording.
        Combined with outputDir to form the full path.
      '';
    };

    noQuanta = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable quanta codec and use passthrough PCM mode.
        Useful for testing or when quanta encoding is not needed.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.demod-rt;
      defaultText = literalExpression "pkgs.demod-rt";
      description = ''
        The demod-rt package to use. Override to use a custom build.
      '';
    };

    snakeMixerPackage = mkOption {
      type = types.package;
      default = pkgs.snake-mixer or (throw "pkgs.snake-mixer not defined");
      defaultText = literalExpression "pkgs.snake-mixer";
      description = ''
        The snake_mixer package to use. Must be provided in pkgs.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.maxSources > 0;
        message = "services.snake-hub.maxSources must be > 0";
      }
      {
        assertion = cfg.maxSources <= 64;
        message = "services.snake-hub.maxSources must be <= 64 (shared memory ring limit)";
      }
      {
        assertion = length cfg.isolatedCores >= 1;
        message = "services.snake-hub.isolatedCores must have at least 1 core";
      }
      {
        assertion = cfg.interface != "";
        message = "services.snake-hub.interface must be specified";
      }
      {
        assertion = all (c: c >= 0) cfg.isolatedCores;
        message = "services.snake-hub.isolatedCores: all core numbers must be >= 0";
      }
    ];

    # Ensure the packages are available
    environment.systemPackages = [
      cfg.package
      cfg.snakeMixerPackage
    ];
  };

  meta = {
    maintainers = [];
    platforms = platforms.linux;
  };
}
