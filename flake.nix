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
    # HydraMesh provides the DCF-Audio serve/decode tooling (patched ffmpeg with a
    # `dcf` demuxer + the dcf-radio HLS server) that the slim runtime image bakes in
    # to play the engine's DCF-Audio monitor stream in a browser. Its own nixpkgs is
    # left unpinned-to-ours on purpose (different input graph); the closure is cached.
    hydramesh.url = "github:ALH477/HydraMesh";
  };

  outputs = { self, nixpkgs, flake-utils, nix-appimage, hydramesh }:
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

        # ── The quanta compiler (GPLv3-only OR commercial) ───────────
        # Analysis-to-synthesis codec: matching-pursuit analyzer -> QSC score ->
        # Faust-freeze (decoder is a pure static Faust program). Separate program
        # from the framework; see quanta/ and LICENSING.md. Builds three CLIs with
        # a plain gcc Makefile — no JACK, no framework dependency.
        quanta = pkgs.stdenv.mkDerivation {
          pname = "demod-quanta";
          version = "0.1.0";
          src = ./quanta;
          buildPhase = "make";
          installPhase = ''
            mkdir -p $out/bin
            cp bin/quanta-analyzer bin/quanta-render bin/quanta-freeze $out/bin/
          '';
          meta = {
            description = "DeMoD Quanta — acoustic-quanta analyzer / Faust freeze compiler";
            license = pkgs.lib.licenses.gpl3Only;
            platforms = pkgs.lib.platforms.linux;
          };
        };

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

        # demod-dcf-audiocast: JACK client that casts the engine's output over the
        # DCF-Audio wire (Opus/24k, codec_id 0) — the capture/encode half of the
        # HLS live-monitor path. Pipe its stdout into dcf-ffmpeg to serve HLS.
        # Audio-stack code (GPLv3-only OR commercial); links libjack + libopus.
        demod-dcf-audiocast = pkgs.stdenv.mkDerivation {
          pname = "demod-dcf-audiocast";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; [ jack2 libopus ];
          buildPhase = ''
            make -C audio-stack/bridge demod-dcf-audiocast CC=${pkgs.stdenv.cc}/bin/cc
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp audio-stack/bridge/demod-dcf-audiocast $out/bin/
          '';
          meta = {
            description = "Cast the DeMoD engine's JACK output over the DCF-Audio wire (Opus/HLS monitor)";
            license = pkgs.lib.licenses.gpl3Only;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "demod-dcf-audiocast";
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

        # ── Slim runtime container image (dockerTools) ───────────────
        # A distributable image with ONLY the runtime closures — the engine, the
        # orchestrator, both DCF bridges, the DCF-Audio caster, the Quanta CLIs, the
        # DCF-Audio HLS server (HydraMesh dcf-ffmpeg), jackd, python3 and tini — plus
        # the *prebuilt* WASM UI from ./web (the browser build is impure — emscripten's
        # SDL2 port needs network — so it is not rebuilt here; the fat dev image in
        # docker/Dockerfile rebuilds it). No toolchain, no Nix store, no source tree.
        #   nix build .#docker-runtime && docker load < result
        # Same soft-RT caveats as the dev image — run with the caps in docker/README.md.
        dcf-ffmpeg = hydramesh.packages.${system}.dcf-ffmpeg;
        dcf-radio  = hydramesh.packages.${system}.dcf-radio;

        ociLabels = {
          "org.opencontainers.image.title"       = "DeMoD runtime";
          "org.opencontainers.image.description" =
            "Soft-real-time DeMoD audio engine + Quanta codec + WASM UI + HydraMesh DCF-Audio HLS monitor. DEV/soft-RT only — not representative of real hardware.";
          "org.opencontainers.image.source"      = "https://github.com/ALH477/DeMoD";
          "org.opencontainers.image.licenses"    = "MPL-2.0 AND GPL-3.0-only AND LGPL-3.0-only";
          "org.opencontainers.image.version"     = "0.1.0";
          "com.demod.soft-rt"                    = "true";
        };

        docker-runtime =
          let
            runtimeEnv = pkgs.buildEnv {
              name = "demod-runtime-env";
              paths = with pkgs; [
                quanta demod-rt demod-orchestrator demod-remote-bridge
                dcf-ws-bridge demod-dcf-audiocast dcf-ffmpeg
                jack2 (python3.withPackages (ps: [ ps.numpy ]))
                tini bashInteractive coreutils curl gnused gawk gnugrep procps
              ];
            };
            # Prebuilt browser UI (see note above) staged read-only in the image.
            webSrc = pkgs.runCommand "demod-web" { } ''
              mkdir -p $out/share/demod-web
              cp -r ${./web}/. $out/share/demod-web/
            '';
            entrypoint = pkgs.runCommand "demod-entrypoint" { } ''
              install -Dm755 ${./docker/entrypoint.sh} $out/entrypoint.sh
              # bake the stdlib health probe so wait_for_rt works without the repo.
              install -Dm755 ${./audio-stack/bridge/test/control_probe.py} \
                $out/share/demod/control_probe.py
            '';
          in pkgs.dockerTools.buildLayeredImage {
            name = "demod-runtime";
            tag  = "latest";
            contents = [ runtimeEnv webSrc entrypoint ];
            config = {
              # Invoke bash explicitly — the slim image has no /usr/bin/env for the
              # script's shebang to resolve.
              Entrypoint = [ "${pkgs.tini}/bin/tini" "--"
                             "${pkgs.bashInteractive}/bin/bash" "/entrypoint.sh" ];
              Cmd = [ "serve" ];
              WorkingDir = "/work";
              Env = [
                "PATH=/bin"
                "DEMOD_SLIM=1"
                "DEMOD_PROBE=/share/demod/control_probe.py"
                "DEMOD_WEB_SRC=/share/demod-web"
                "DEMOD_CONTROL_SOCK=/run/demod/control.sock"
                "DEMOD_DCF_PORT=47000"
                "JACK_PERIOD=1024"
                "HTTP_PORT=8080"
                "WS_PORT=7000"
                "OUT=/out"
              ];
              ExposedPorts = { "8080/tcp" = { }; "7000/tcp" = { }; "47000/udp" = { }; };
              Labels = ociLabels;
            };
          };

      in {
        packages = {
          default = demod-ui;
          inherit demod-ui demod-rt demod-orchestrator demod-ui-dcf
                  demod-remote-bridge dcf-ws-bridge quanta
                  demod-dcf-audiocast dcf-ffmpeg dcf-radio docker-runtime;

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

        # `nix run .#quanta` — the Quanta score-browser panel on the framework host
        # (see quanta/ui/quanta_panel.lua; DCF ops stubbed, so plain demod-ui). The
        # analyzer/render/freeze CLIs are the `quanta` package: `nix build .#quanta`.
        apps.quanta = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-quanta-panel" ''
            exec ${demod-ui}/bin/demod-ui ${./quanta}/ui/quanta_panel.lua "$@"
          '');
        };

        # `nix run .#check` — the pre-push gate (= ./dev check, against the tree).
        apps.check = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-check" ''
            exec ${pkgs.bash}/bin/bash "''${DEMOD_REPO:-$PWD}/dev" check
          '');
        };
        # `nix run .#dev -- <cmd>` — the dev CLI without cloning-then-cd.
        apps.dev = {
          type = "app";
          program = toString (pkgs.writeShellScript "demod-dev" ''
            exec ${pkgs.bash}/bin/bash "''${DEMOD_REPO:-$PWD}/dev" "$@"
          '');
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # framework
            SDL2 lua5_4 pkg-config gcc gdb valgrind
            # audio stack (engine + orchestrator)
            cmake ninja jack2
            ghc cabal-install
            # quanta codec: Faust (freeze -> .dsp) + numpy (verification metrics)
            faust
            # fonts (make font) + quanta metrics (numpy)
            (python3.withPackages (ps: [ ps.numpy ])) curl gzip
            # dev CLI: fmt/lint (stylua+clang-tools), compiledb (bear), watch (entr),
            # LSP (lua-language-server + clangd from clang-tools), completion (bash-completion)
            stylua clang-tools lua-language-server bear entr bash-completion
          ];

          shellHook = ''
            echo "═══════════════════════════════════════════"
            echo " DeMoD UI — Development Shell"
            echo " ./dev check      — build + all tests (the pre-push gate)"
            echo " ./dev run  <auto|dash|gcs|rov|mcp|example>"
            echo " ./dev shot <target> [frame]   — headless screenshot -> PNG"
            echo " ./dev test <name|all> · fmt|lint · doctor · watch · compiledb"
            echo " make / make test / make font   ·   see DEVELOPING.md"
            echo " (cd quanta && make test)       — quanta null + M0 tonal gates"
            echo "═══════════════════════════════════════════"
            # tab-completion for ./dev
            [ -n "''${BASH_VERSION:-}" ] && [ -f completions/dev.bash ] && \
              source completions/dev.bash 2>/dev/null || true
          '';
        };
      }
    );
}
