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

        # ── DCF (HydraMesh/UDP) remote transport ─────────────────────
        # Optional: run the engine on another box, driven over UDP. Uses the
        # vendored HydraMesh codec headers (LGPL-3.0, third_party/hydramesh).
        # demod-ui-dcf: the framework with the dm.dcf binding (DCF=1). The
        # dm.dcf/bridge sources are LGPL-3.0; the default demod-ui stays MPL.
        demod-ui-dcf = demod-ui.overrideAttrs (old: {
          pname = "demod-ui-dcf";
          buildPhase = ''
            make DCF=1 CC=${pkgs.stdenv.cc}/bin/cc
          '';
          meta = old.meta // {
            description = "DeMoD UI with the dm.dcf remote transport binding";
            license = pkgs.lib.licenses.lgpl3Only;
          };
        });

        # demod-remote-bridge: engine-side DCF <-> local-IPC relay (standalone).
        demod-remote-bridge = pkgs.stdenv.mkDerivation {
          pname = "demod-remote-bridge";
          version = "0.1.0";
          src = ./.;
          buildPhase = ''
            make -C audio-stack/bridge CC=${pkgs.stdenv.cc}/bin/cc
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp audio-stack/bridge/demod-remote-bridge $out/bin/
          '';
          meta = {
            description = "DeMoD remote-engine bridge (DCF/UDP <-> local control socket + meters shm)";
            license = pkgs.lib.licenses.lgpl3Only;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "demod-remote-bridge";
          };
        };

        # dcf-ws-bridge: stateless WebSocket<->UDP relay so the browser (WASM)
        # client can join the plaintext DCF mesh. Vendored LGPL crate (web/bridge,
        # from HydraMesh); it shuttles opaque datagrams and never parses a frame.
        # Sits in front of demod-remote-bridge; deploy behind WireGuard.
        dcf-ws-bridge = pkgs.rustPlatform.buildRustPackage {
          pname = "dcf-ws-bridge";
          version = "0.1.0";
          src = ./web/bridge;
          cargoLock.lockFile = ./web/bridge/Cargo.lock;
          doCheck = false;
          meta = {
            description = "DCF browser-client WebSocket<->UDP bridge";
            license = pkgs.lib.licenses.lgpl3Only;
            mainProgram = "dcf-ws-bridge";
          };
        };

      in {
        packages = {
          default = demod-ui;
          inherit demod-ui demod-rt demod-orchestrator demod-ui-dcf
                  demod-remote-bridge dcf-ws-bridge;

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

        # `nix run .#mcp` — the DeMoD MCP server (AI agent tooling; see mcp/).
        # Runs against the working tree (DEMOD_REPO defaults to $PWD) so its
        # build/test/render tools operate on your checkout, not the store.
        apps.mcp = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-mcp" ''
            exec ${pkgs.python3}/bin/python3 "''${DEMOD_REPO:-$PWD}/mcp/demod_mcp_server.py" "$@"
          '');
        };

        # `nix run .#auto` — DeMoD Auto, the FOSS car head-unit + vehicle-companion
        # shell (see auto/). Uses the DCF-enabled UI so the companion surface has
        # dm.dcf; python3 on PATH for the OBD-II reader (auto/vehicle/obd2-reader.py).
        apps.auto = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-auto" ''
            export DEMOD_SHELL_DIR=${./shell}/       # the shared companion-shell SDK
            export DEMOD_AUTO_DIR=${./auto}/
            # python3 for the OBD-II reader; pipewire/ffmpeg for the media player.
            export PATH=${pkgs.python3}/bin:${pkgs.pipewire}/bin:${pkgs.ffmpeg}/bin:$PATH
            exec ${demod-ui-dcf}/bin/demod-ui ${./auto}/main.lua "$@"
          '');
        };

        # Sibling shells on the same SDK (see shell/). Each is DCF-enabled so its
        # mesh/telemetry surfaces work; set DEMOD_DCF_HOST/_PORT to attach a mesh,
        # else they run their simulator. `nix run .#dash|.#gcs|.#rov`.
        apps.dash = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-dash" ''
            export DEMOD_SHELL_DIR=${./shell}/ DEMOD_DASH_DIR=${./dash}/
            exec ${demod-ui-dcf}/bin/demod-ui ${./dash}/main.lua "$@"
          '');
        };
        apps.gcs = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-gcs" ''
            export DEMOD_SHELL_DIR=${./shell}/ DEMOD_GCS_DIR=${./gcs}/
            exec ${demod-ui-dcf}/bin/demod-ui ${./gcs}/main.lua "$@"
          '');
        };
        apps.rov = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-rov" ''
            export DEMOD_SHELL_DIR=${./shell}/ DEMOD_ROV_DIR=${./rov}/
            exec ${demod-ui-dcf}/bin/demod-ui ${./rov}/main.lua "$@"
          '');
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
