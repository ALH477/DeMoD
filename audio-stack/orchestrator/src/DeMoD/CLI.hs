{- |
Module      : DeMoD.CLI
Description : Command-line parsing for demod-orchestrator
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only
-}

module DeMoD.CLI
    ( CliResult(..)
    , parseArgs
    , usageLines
    ) where

import Text.Read (readMaybe)

import DeMoD.Orchestrator (OrchestratorConfig(..), defaultConfig)
import qualified DeMoD.Marketplace as Marketplace

data CliResult
    = CliHelp
    | CliRun OrchestratorConfig
    deriving (Show)

parseArgs :: [String] -> Either String CliResult
parseArgs args = go args defaultConfig
  where
    go [] cfg = Right (CliRun cfg)
    go ("--help":_) _ = Right CliHelp
    go ("--rt-binary":v:rest) cfg =
        go rest cfg { cfgRtBinary = v }
    go ("--rt-core":v:rest) cfg =
        parseIntFlag "--rt-core" v (\n -> cfg { cfgRtCore = n }) >>= \cfg' -> go rest cfg'
    go ("--rt-priority":v:rest) cfg =
        parseIntFlag "--rt-priority" v (\n -> cfg { cfgRtPriority = n }) >>= \cfg' -> go rest cfg'
    go ("--faust-lib":v:rest) cfg =
        go rest cfg { cfgFaustLibs = cfgFaustLibs cfg ++ [v] }
    go ("--heartbeat-ms":v:rest) cfg =
        parseIntFlag "--heartbeat-ms" v (\n -> cfg { cfgHeartbeatMs = n }) >>= \cfg' -> go rest cfg'
    go ("--restart-delay-ms":v:rest) cfg =
        parseIntFlag "--restart-delay-ms" v (\n -> cfg { cfgRestartDelayMs = n }) >>= \cfg' -> go rest cfg'
    go ("--max-restart-ms":v:rest) cfg =
        parseIntFlag "--max-restart-ms" v (\n -> cfg { cfgMaxRestartMs = n }) >>= \cfg' -> go rest cfg'
    go ("--shutdown-timeout-ms":v:rest) cfg =
        parseIntFlag "--shutdown-timeout-ms" v (\n -> cfg { cfgShutdownTimeMs = n }) >>= \cfg' -> go rest cfg'
    go ("--control-socket":v:rest) cfg =
        go rest cfg { cfgControlSocket = Just v }
    go ("--data-dir":v:rest) cfg =
        go rest cfg { cfgDataDir = v }
    go ("--setup-marker":v:rest) cfg =
        go rest cfg { cfgSetupMarker = Just v }
    go ("--synth":rest) cfg =
        go rest cfg { cfgSynthEnable = True }
    go ("--bt-midi":rest) cfg =
        go rest cfg { cfgBtMidiEnable = True }
    go ("--bt-midi-name":v:rest) cfg =
        go rest cfg { cfgBtMidiName = v }
    go ("--marketplace":rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcEnabled = True }
            }
    go ("--marketplace-bridge-url":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcBridgeUrl = v }
            }
    go ("--marketplace-shm-name":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcShmName = v }
            }
    go ("--marketplace-poll-ms":v:rest) cfg =
        parseIntFlag "--marketplace-poll-ms" v
            (\n -> cfg
                { cfgMarketplace =
                    (cfgMarketplace cfg) { Marketplace.mcPollIntervalMs = n }
                })
            >>= \cfg' -> go rest cfg'
    go ("--marketplace-offline-ms":v:rest) cfg =
        parseIntFlag "--marketplace-offline-ms" v
            (\n -> cfg
                { cfgMarketplace =
                    (cfgMarketplace cfg) { Marketplace.mcOfflineTimeoutMs = n }
                })
            >>= \cfg' -> go rest cfg'
    go ("--marketplace-library-dir":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcLibraryDir = v }
            }
    go ("--marketplace-manifest":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcInstallManifestPath = v }
            }
    go ("--marketplace-catalog-file":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcCatalogFile = Just v }
            }
    go ("--marketplace-pairing-code-bin":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcPairingCodeBin = v }
            }
    go ("--marketplace-pairing-code-file":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcPairingCodeFile = v }
            }
    go ("--marketplace-pairing-ttl-sec":v:rest) cfg =
        parseIntFlag "--marketplace-pairing-ttl-sec" v
            (\n -> cfg
                { cfgMarketplace =
                    (cfgMarketplace cfg) { Marketplace.mcPairingCodeTtlSec = n }
                })
            >>= \cfg' -> go rest cfg'
    go ("--marketplace-qrencode-bin":v:rest) cfg =
        go rest cfg
            { cfgMarketplace =
                (cfgMarketplace cfg) { Marketplace.mcQrEncodeBin = Just v }
            }
    go (flag:[]) _ =
        Left $ "missing value for option: " ++ flag
    go (x:_) _ =
        Left $ "unknown option: " ++ x

    parseIntFlag :: String -> String -> (Int -> OrchestratorConfig) -> Either String OrchestratorConfig
    parseIntFlag flag raw mkCfg =
        case readMaybe raw of
            Just n  -> Right (mkCfg n)
            Nothing -> Left $ "invalid integer for " ++ flag ++ ": " ++ raw

usageLines :: [String]
usageLines =
    [ ""
    , "Usage: demod-orchestrator [OPTIONS]"
    , ""
    , "  --rt-binary PATH          demod-rt binary (default: demod-rt)"
    , "  --rt-core N               isolated core (default: 4)"
    , "  --rt-priority N           SCHED_FIFO priority (default: 80)"
    , "  --faust-lib PATH          Faust .so plugin (repeatable)"
    , "  --heartbeat-ms N          heartbeat timeout (default: 500)"
    , "  --restart-delay-ms N      base restart delay (default: 100)"
    , "  --max-restart-ms N        max backoff cap (default: 30000)"
    , "  --shutdown-timeout-ms N   SIGTERM→SIGKILL timeout (default: 5000)"
    , "  --control-socket PATH     UDS for external clients (disabled by default)"
    , "  --data-dir PATH           persistent DeMoD data root (default: /var/lib/demod)"
    , "  --setup-marker PATH       first-boot completion marker path"
    , "  --synth                   drive Faust instruments from detected pitch"
    , "  --bt-midi                 publish OSC state as BLE-MIDI via libdemod_bt"
    , "  --bt-midi-name NAME       BLE-MIDI advertised local name (default: DeMoD Guitar)"
    , "  --marketplace             publish embedded Marketplace bridge status to shm"
    , "  --marketplace-bridge-url URL"
    , "                            local device bridge URL (default: http://127.0.0.1:7635)"
    , "  --marketplace-shm-name NAME"
    , "                            POSIX shm name (default: /demod-mkt-shm)"
    , "  --marketplace-poll-ms N    Marketplace poll interval (default: 1000)"
    , "  --marketplace-offline-ms N offline grace after bridge failure (default: 5000)"
    , "  --marketplace-library-dir PATH"
    , "                            installed effect library directory"
    , "  --marketplace-manifest PATH"
    , "                            bridge install manifest path"
    , "  --marketplace-catalog-file PATH"
    , "                            optional owned/free catalog JSON file"
    , "  --marketplace-pairing-code-bin PATH"
    , "                            bridge-owned pairing-code utility"
    , "  --marketplace-pairing-code-file PATH"
    , "                            pairing-code file consumed by the bridge"
    , "  --marketplace-pairing-ttl-sec N"
    , "                            physical pairing code lifetime (default: 600)"
    , "  --marketplace-qrencode-bin PATH"
    , "                            optional qrencode binary for framebuffer QR matrices"
    , "  --help                    show this message"
    , ""
    , "RTS flags (after +RTS):"
    , "  -N2 -qg -qb -qm -I0 -A512k --nonmoving-gc -C0 -V0"
    ]
