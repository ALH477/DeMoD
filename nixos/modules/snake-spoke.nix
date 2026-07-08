# SPDX-License-Identifier: GPL-3.0-only OR Commercial
# NixOS module for DCF-Snake spoke node deployment (RISC-V)
#
# Deploys demod-rt (spoke mode) + snake_source with proper RT scheduling,
# CPU isolation, and raw L2 network transport.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.snake-spoke;
in {
  imports = [
    ./snake-spoke-service.nix
    ./snake-spoke-network.nix
  ];

  options.services.snake-spoke = {
    enable = mkEnableOption "DCF-Snake spoke node for RISC-V deployment";

    interface = mkOption {
      type = types.str;
      default = "eth0";
      description = ''
        Network interface for raw L2 transport (EtherType 0x88B5 for record plane).
        Must support AF_PACKET/SOCK_RAW sockets.
      '';
      example = "enp0s3";
    };

    channel = mkOption {
      type = types.str;
      default = "snake";
      description = ''
        Snake channel name for network identification.
        Used to distinguish multiple snake networks on the same physical segment.
      '';
    };

    isolatedCore = mkOption {
      type = types.int;
      default = 3;
      description = ''
        CPU core to isolate for demod-rt real-time audio processing.
        This core will be removed from the kernel scheduler via isolcpus.
        Must be a valid core number for the target RISC-V SoC.
      '';
      example = 2;
    };

    faustLibs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of Faust DSP libraries to load into demod-rt.
        Each library is passed as --faust-lib <path> to demod-rt.
      '';
      example = [ "/etc/faust/effect.dsp" "/etc/faust/filter.dsp" ];
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

    snakeSourcePackage = mkOption {
      type = types.package;
      default = pkgs.snake-source or (throw "pkgs.snake-source not defined");
      defaultText = literalExpression "pkgs.snake-source";
      description = ''
        The snake_source package to use. Must be provided in pkgs.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.isolatedCore >= 0;
        message = "services.snake-spoke.isolatedCore must be >= 0";
      }
      {
        assertion = cfg.interface != "";
        message = "services.snake-spoke.interface must be specified";
      }
    ];

    # Ensure the packages are available
    environment.systemPackages = [
      cfg.package
      cfg.snakeSourcePackage
    ];
  };

  meta = {
    maintainers = [];
    platforms = platforms.linux;
  };
}
