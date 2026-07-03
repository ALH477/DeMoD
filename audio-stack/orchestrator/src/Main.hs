{- |
Module      : Main
Description : DeMoD Orchestrator entry point
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Usage:
  demod-orchestrator [OPTIONS]

  --rt-binary PATH     Path to demod-rt binary (default: demod-rt)
  --rt-core N          Core for RT process (default: 4)
  --rt-priority N      SCHED_FIFO priority (default: 80)
  --faust-lib PATH     Faust .so plugin (repeatable)
  --heartbeat-ms N     Heartbeat timeout in ms (default: 500)
  --control-socket P   Unix socket for local product/runtime clients
  --data-dir PATH      Persistent DeMoD data root
  --setup-marker PATH  First-boot completion marker
  --help               Show usage

RTS flags are passed after +RTS:
  taskset -c 0,1 demod-orchestrator --rt-core 4 \
    +RTS -N2 -qg -qb -qm -I0 -A512k --nonmoving-gc -C0 -V0 -RTS
-}

module Main (main) where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure, exitSuccess)

import DeMoD.CLI (CliResult(..), parseArgs, usageLines)
import DeMoD.Orchestrator (runOrchestrator)

main :: IO ()
main = do
    args <- getArgs
    case parseArgs args of
        Left err -> do
            hPutStrLn stderr $ "Error: " ++ err
            printUsage
            exitFailure
        Right CliHelp -> do
            printUsage
            exitSuccess
        Right (CliRun cfg) ->
            runOrchestrator cfg

printUsage :: IO ()
printUsage = mapM_ (hPutStrLn stderr) usageLines
