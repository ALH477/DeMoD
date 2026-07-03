{- |
Module      : DeMoD.ProcessTree
Description : Standard child process specifications
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Defines the standard DeMoD process tree. Each child spec encodes
the binary, CPU affinity, scheduling policy, and restart strategy.

Process Tree (from whiteboard):
  ┌─ Cores 0-1: Orchestrator + system services
  ├─ Core 4:    demod-rt (SCHED_FIFO 80, isolated)
  ├─ Core 5:    demod-ui compositor
  ├─ Core 6-7:  demod-hydramesh / spare RT
  └─ (any):     demod-lyrics (TCP 7709, normal priority)
-}

{-# LANGUAGE RecordWildCards #-}

module DeMoD.ProcessTree
    ( mkRtAudioSpec
    , normalizeFaustSlots
    , mkUiSpec
    , mkLyricsSpec
    , mkHydraMeshSpec
    ) where

import DeMoD.Supervisor (ChildSpec(..))

normalizeFaustSlots :: [FilePath] -> [Maybe FilePath]
normalizeFaustSlots faustLibs =
    take 16 (map Just faustLibs ++ repeat Nothing)

-- | RT Audio: the critical path. SCHED_FIFO 80, isolated core 4, mlockall.
mkRtAudioSpec :: FilePath -> Int -> Int -> [Maybe FilePath] -> ChildSpec
mkRtAudioSpec binary core priority faustSlots = ChildSpec
    { csName          = "demod-rt"
    , csBinary        = binary
    , csArgs          = ["--core", show core]
                     ++ concatMap slotArgs (zip [0 :: Int .. 15] normalizedSlots)
    , csCpuCore       = Just core
    , csSchedFifo     = Just priority
    , csMlockAll      = True
    , csRestartBaseMs = 100
    , csRestartMaxMs  = 30000
    , csShutdownMs    = 5000
    , csMaxRestarts   = -1          -- infinite restarts
    }
  where
    normalizedSlots = take 16 (faustSlots ++ repeat Nothing)
    slotArgs (_, Nothing) = []
    slotArgs (slot, Just lib) = ["--faust-slot", show slot, lib]

-- | UI Compositor: DeMoD UI on core 5, normal priority.
mkUiSpec :: FilePath -> String -> ChildSpec
mkUiSpec binary luaScript = ChildSpec
    { csName          = "demod-ui"
    , csBinary        = binary
    , csArgs          = [luaScript]
    , csCpuCore       = Just 5
    , csSchedFifo     = Nothing     -- normal scheduling
    , csMlockAll      = False
    , csRestartBaseMs = 500
    , csRestartMaxMs  = 10000
    , csShutdownMs    = 3000
    , csMaxRestarts   = 10
    }

-- | Lyrics Engine: TCP control on port 7709, any core.
mkLyricsSpec :: FilePath -> ChildSpec
mkLyricsSpec binary = ChildSpec
    { csName          = "demod-lyrics"
    , csBinary        = binary
    , csArgs          = ["--port", "7709"]
    , csCpuCore       = Nothing
    , csSchedFifo     = Nothing
    , csMlockAll      = False
    , csRestartBaseMs = 1000
    , csRestartMaxMs  = 30000
    , csShutdownMs    = 3000
    , csMaxRestarts   = 5
    }

-- | HydraMesh: P2P networking on cores 6-7.
mkHydraMeshSpec :: FilePath -> ChildSpec
mkHydraMeshSpec binary = ChildSpec
    { csName          = "demod-hydramesh"
    , csBinary        = binary
    , csArgs          = []
    , csCpuCore       = Just 6
    , csSchedFifo     = Nothing
    , csMlockAll      = False
    , csRestartBaseMs = 2000
    , csRestartMaxMs  = 60000
    , csShutdownMs    = 5000
    , csMaxRestarts   = 3
    }
