# SPDX-License-Identifier: MPL-2.0
{
  description = "DeMoD UI — SDL2/framebuffer GUI framework with Lua widget scripting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix-appimage = {
      url = "github:ralismark/nix-appimage";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nix-appimage }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ── The framework (MPL-2.0) ──────────────────────────────────
        demod-ui = pkgs.stdenv.mkDerivation {
          pname = "demod-ui";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; [ SDL2 lua5_4 ];

          buildPhase = ''
            make CC=${pkgs.stdenv.cc}/bin/cc
          '';

          installPhase = ''
            mkdir -p $out/bin $out/share/demod-ui/examples
            cp demod-ui $out/bin/
            cp examples/*.lua $out/share/demod-ui/examples/
          '';

          meta = {
            description = "DeMoD UI — SDL2 framebuffer GUI framework with Lua scripting";
            license = pkgs.lib.licenses.mpl20;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "demod-ui";
          };
        };

        # ── The audio stack (GPLv3-only OR commercial) ───────────────
        # Separate programs (socket + shm IPC); see audio-stack/ and LICENSING.md.
        # demod-rt: C engine, JACK client, CMake.
        demod-rt = pkgs.stdenv.mkDerivation {
          pname = "demod-rt";
          version = "0.1.0";
          src = ./audio-stack;

          nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
          buildInputs = with pkgs; [ jack2 ];

          cmakeFlags = [ "-DCMAKE_BUILD_TYPE=Release" "-DBUILD_TESTING=ON" ];
          doCheck = true;
          checkPhase = "ctest --output-on-failure";

          meta = {
            description = "DeMoD deterministic real-time audio engine";
            license = pkgs.lib.licenses.gpl3Only;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "demod-rt";
          };
        };

        # demod-orchestrator: Haskell control daemon. bt-midi flag OFF (the BLE-MIDI
        # peripheral lib is a separate, non-public dependency); built without it here.
        demod-orchestrator =
          let
            base = pkgs.haskellPackages.callCabal2nix
              "demod-orchestrator" ./audio-stack/orchestrator { demod_bt = null; };
          in pkgs.haskell.lib.compose.appendConfigureFlags [ "--flag=-bt-midi" ] base;

      in {
        packages = {
          default = demod-ui;
          inherit demod-ui demod-rt demod-orchestrator;

          # Portable single-file build of the framework (bundles the nix closure).
          appimage = nix-appimage.lib.${system}.mkAppImage {
            program = "${demod-ui}/bin/demod-ui";
            name = "demod-ui";
          };
        };

        apps.default = {
          type = "app";
          program = "${demod-ui}/bin/demod-ui";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # framework
            SDL2 lua5_4 pkg-config gcc gdb valgrind
            # audio stack (engine + orchestrator)
            cmake ninja jack2
            ghc cabal-install
            # fonts (make font)
            python3 curl gzip
          ];

          shellHook = ''
            echo "═══════════════════════════════════════════"
            echo " DeMoD UI — Development Shell"
            echo " make            — build the framework"
            echo " make test       — UTF-8 font tests"
            echo " make font       — build the Unifont glyph blob (CJK/UTF-8)"
            echo " make run        — run the hello example"
            echo " nix build .#demod-rt .#demod-orchestrator  — audio stack"
            echo "═══════════════════════════════════════════"
          '';
        };
      }
    );
}
