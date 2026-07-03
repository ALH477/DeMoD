{- |
Module      : DeMoD.OSCRouter
Description : Parameter aggregation and routing
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The OSC Router aggregates parameter updates from multiple sources
and publishes consolidated snapshots to the triple buffer.

Sources:
  - Ulation Engine (pitch, confidence, MIDI note)
  - External OSC (UDP port 9000, future)
  - Bluetooth control: implemented as an outbound publisher in
    'DeMoD.BT.Bridge' — the router's TVars are mirrored to a paired
    DAW host as BLE-MIDI events. Inbound BLE-MIDI (DAW → guitar) is
    not yet wired; it would write back into rsFx here.
  - Internal commands (FX bypass, gain, BPM)

The router runs as a green thread, polling a TVar-based mailbox.
Each source writes to its own TVar; the router reads all TVars,
merges into a single snapshot, and publishes at a configurable rate.

This decouples sources from the IPC layer — sources don't need to
know about the triple buffer or FFI. They just write to TVars.
-}

{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

module DeMoD.OSCRouter
    ( -- * Types
      RouterConfig(..)
    , RouterState(..)
    , PitchUpdate(..)
    , TempoUpdate(..)
    , FxUpdate(..)
    , SynthUpdate(..)

      -- * Lifecycle
    , defaultRouterConfig
    , newRouterState
    , runRouter
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (when, unless)
import Data.IORef
import Data.Word
import Foreign.C.Types (CFloat(..))

import qualified DeMoD.IPC.FFI as FFI

-- ── Configuration ──────────────────────────────────────────────

data RouterConfig = RouterConfig
    { rcPublishRateHz :: !Int   -- ^ How often to publish (default: 100 Hz = 10ms)
    } deriving (Show)

defaultRouterConfig :: RouterConfig
defaultRouterConfig = RouterConfig { rcPublishRateHz = 100 }

-- ── Source Mailboxes ───────────────────────────────────────────

data PitchUpdate = PitchUpdate
    { puFrequency  :: !Float
    , puConfidence :: !Float
    , puMidiNote   :: !Int
    } deriving (Show, Eq)

data TempoUpdate = TempoUpdate
    { tuBpm       :: !Float
    , tuBeatCount :: !Word32
    } deriving (Show, Eq)

data FxUpdate = FxUpdate
    { fuBypassMask :: !Word32
    , fuParams     :: ![Float]   -- ^ Up to 16 slot values
    } deriving (Show, Eq)

data SynthUpdate = SynthUpdate
    { suMixMode :: !Word32  -- ^ 0=sum, 1=dry, 2=synth-only
    , suGain    :: !Float
    } deriving (Show, Eq)

-- ── Router State ───────────────────────────────────────────────

data RouterState = RouterState
    { rsPitch    :: !(TVar PitchUpdate)
    , rsTempo    :: !(TVar TempoUpdate)
    , rsFx       :: !(TVar FxUpdate)
    , rsSynth    :: !(TVar SynthUpdate)
    , rsPublishCount :: !(IORef Word64)
    }

newRouterState :: IO RouterState
newRouterState = do
    pitch <- newTVarIO (PitchUpdate 0 0 (-1))
    tempo <- newTVarIO (TempoUpdate 120 0)
    fx    <- newTVarIO (FxUpdate 0 (replicate 16 0))
    synth <- newTVarIO (SynthUpdate 0 1.0)
    count <- newIORef 0
    pure $ RouterState pitch tempo fx synth count

-- ── Router Loop ────────────────────────────────────────────────

{- |
Run the router. Reads all source TVars, merges into a single
parameter snapshot, and publishes to the triple buffer.

Runs at rcPublishRateHz (default 100Hz = 10ms between publishes).
Only publishes if at least one source has changed since the last
publish, to avoid unnecessary atomic CAS operations.
-}
runRouter :: RouterConfig -> FFI.IpcHandle -> TVar Bool -> RouterState -> IO ()
runRouter cfg ipc running state = do
    lastPitch <- newIORef (PitchUpdate 0 0 (-1))
    lastTempo <- newIORef (TempoUpdate 120 0)
    lastFx    <- newIORef (FxUpdate 0 (replicate 16 0))
    lastSynth <- newIORef (SynthUpdate 0 1.0)

    loop lastPitch lastTempo lastFx lastSynth
  where
    delayUs = 1_000_000 `div` rcPublishRateHz cfg

    loop lpRef ltRef lfRef lsRef = do
        alive <- readTVarIO running
        unless alive $ pure ()

        when alive $ do
            -- Read current values from all sources
            curPitch <- readTVarIO (rsPitch state)
            curTempo <- readTVarIO (rsTempo state)
            curFx    <- readTVarIO (rsFx state)
            curSynth <- readTVarIO (rsSynth state)

            -- Check if anything changed
            prevPitch <- readIORef lpRef
            prevTempo <- readIORef ltRef
            prevFx    <- readIORef lfRef
            prevSynth <- readIORef lsRef

            let changed = curPitch /= prevPitch
                       || curTempo /= prevTempo
                       || curFx /= prevFx
                       || curSynth /= prevSynth

            when changed $ do
                -- Publish merged snapshot
                snap <- FFI.tbBeginWrite ipc
                ts   <- FFI.clockUs

                FFI.snapSetPitch snap
                    (CFloat $ puFrequency curPitch)
                    (CFloat $ puConfidence curPitch)
                    (fromIntegral $ puMidiNote curPitch)

                FFI.snapSetTempo snap
                    (CFloat $ tuBpm curTempo)
                    (tuBeatCount curTempo)

                FFI.snapSetFxBypass snap (fuBypassMask curFx)
                FFI.snapSetSynth snap
                    (suMixMode curSynth)
                    (CFloat $ suGain curSynth)

                -- Set individual FX params
                let params = fuParams curFx
                mapM_ (\(i, v) -> FFI.snapSetFxParam snap (fromIntegral i) (CFloat v))
                      (zip [0 :: Int .. 15] (take 16 (params ++ repeat 0)))

                FFI.snapSetTimestamp snap ts
                FFI.tbPublish ipc

                -- Update cache
                writeIORef lpRef curPitch
                writeIORef ltRef curTempo
                writeIORef lfRef curFx
                writeIORef lsRef curSynth
                modifyIORef' (rsPublishCount state) (+ 1)

            threadDelay delayUs
            loop lpRef ltRef lfRef lsRef
