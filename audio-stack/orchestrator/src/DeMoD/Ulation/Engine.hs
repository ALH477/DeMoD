{- |
Module      : DeMoD.Ulation.Engine
Description : Pitch detection engine with STM pipeline
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The Ulation Engine runs as an async green thread within the orchestrator.
It reads mono audio samples from the SPSC event ring (written by the RT
callback), accumulates them into a sliding analysis window, runs YIN
pitch detection, and forwards results to the router.

Pipeline:
  SPSC evt_ring → accumulator → YIN → router callback → triple buffer → RT callback

Timing:
  - Audio arrives at 48kHz in 64-sample blocks (~750 blocks/sec)
  - YIN runs on every hop (configurable, default: 64 samples = 1.33ms)
  - YIN takes ~200μs for 2048-sample window
  - GC pauses of 1-5ms are tolerable: the RT callback uses the last
    published pitch (staleness < 10ms is inaudible for monophonic)

Threading:
  - Runs on non-isolated cores (0-1) under the GHC scheduler
  - Uses STM for coordination with the orchestrator shutdown signal
  - Uses unsafe FFI for SPSC reads
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DeMoD.Ulation.Engine
    ( -- * Engine
      UlationConfig(..)
    , UlationState(..)
    , defaultUlationConfig
    , runUlationEngine
    , mkUlationState
    , readAudioSamples

      -- * Re-exports
    , YinResult(..)
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (void, when, unless)
import Data.IORef
import Data.Word
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)

import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Unboxed.Mutable as VM

import DeMoD.Ulation.YIN
import qualified DeMoD.IPC.FFI as FFI

-- ── Configuration ──────────────────────────────────────────────

data UlationConfig = UlationConfig
    { ulYinConfig   :: !YinConfig   -- ^ YIN algorithm parameters
    , ulWindowSize  :: !Int         -- ^ Analysis window in samples (default: 2048)
    , ulHopSize     :: !Int         -- ^ Hop between detections (default: 64)
    , ulReadBatch   :: !Int         -- ^ Max samples to read per poll (default: 256)
    , ulPollDelayUs :: !Int         -- ^ Delay when ring empty (default: 500μs)
    } deriving (Show)

defaultUlationConfig :: UlationConfig
defaultUlationConfig = UlationConfig
    { ulYinConfig   = defaultConfig
    , ulWindowSize  = 2048
    , ulHopSize     = 64
    , ulReadBatch   = 256
    , ulPollDelayUs = 500
    }

-- ── Mutable State ──────────────────────────────────────────────

data UlationState = UlationState
    { usRingBuf     :: !(VM.IOVector Double)   -- ^ Circular analysis buffer
    , usWritePos    :: !(IORef Int)            -- ^ Write position in ring
    , usSinceHop    :: !(IORef Int)            -- ^ Samples since last detection
    , usDetections  :: !(IORef Word64)         -- ^ Total detection count
    , usLastResult  :: !(TVar YinResult)       -- ^ Latest detection (for status)
    , usEvtPongs    :: !(IORef Word64)         -- ^ PONG frames observed on evt ring
    , usEvtXruns    :: !(IORef Word64)         -- ^ XRUN frames observed on evt ring
    , usEvtFxLoaded :: !(IORef Word64)         -- ^ FX_LOADED frames observed
    , usEvtFxErrors :: !(IORef Word64)         -- ^ FX_ERROR frames observed
    , usEvtUnknown  :: !(IORef Word64)         -- ^ Unknown framed events observed
    }

mkUlationState :: UlationConfig -> IO UlationState
mkUlationState cfg = do
    buf     <- VM.replicate (ulWindowSize cfg) 0.0
    writeP  <- newIORef 0
    sinceH  <- newIORef 0
    detects <- newIORef 0
    lastR   <- newTVarIO noDetection
    pongs   <- newIORef 0
    xruns   <- newIORef 0
    loaded  <- newIORef 0
    errors  <- newIORef 0
    unknown <- newIORef 0
    pure $ UlationState buf writeP sinceH detects lastR pongs xruns loaded errors unknown
  where
    noDetection = YinResult 0.0 0.0 (-1) 0.0

-- ── Core Loop ──────────────────────────────────────────────────

{- |
Run the Ulation Engine. Blocks until the TVar becomes False.

Flow:
  1. Read available audio from SPSC event ring (unsafe FFI, ~50ns)
  2. Push samples into circular analysis buffer
  3. When hop threshold reached, extract window and run YIN (~200μs)
  4. Forward the result to the orchestrator router
  5. If ring was empty, sleep briefly to avoid spinning
-}
runUlationEngine :: UlationConfig
                 -> FFI.IpcHandle
                 -> TVar Bool
                 -> UlationState
                 -> (YinResult -> IO ())
                 -> IO ()
runUlationEngine cfg ipc running state forwardResult = loop
  where
    !hopSize = ulHopSize cfg
    !batch   = ulReadBatch cfg

    loop = do
        alive <- readTVarIO running
        unless alive $ pure ()

        when alive $ do
            -- Read from SPSC event ring
            nRead <- readAudioSamples ipc batch state

            if nRead == 0
                then do
                    -- Ring empty: sleep to avoid spinning, then retry
                    threadDelay (ulPollDelayUs cfg)
                    loop
                else do
                    -- Check if we've accumulated enough for a hop
                    sinceH <- readIORef (usSinceHop state)
                    let newSince = sinceH + fromIntegral nRead

                    if newSince >= hopSize
                        then do
                            -- Run pitch detection
                            result <- runDetection cfg state
                            writeIORef (usSinceHop state) (newSince - hopSize)

                            -- Route detections through the orchestrator's
                            -- single-writer aggregation path.
                            forwardResult result

                            -- Update stats
                            modifyIORef' (usDetections state) (+ 1)
                            atomically $ writeTVar (usLastResult state) result
                        else
                            writeIORef (usSinceHop state) newSince

                    loop

-- ── Audio Input ────────────────────────────────────────────────

-- | Read samples from SPSC event ring into the circular analysis buffer.
-- Returns number of samples read.
readAudioSamples :: FFI.IpcHandle -> Int -> UlationState -> IO Word64
readAudioSamples ipc maxRead state =
    allocaArray 1 $ \(cBuf :: Ptr CFloat) -> do
        writePos <- readIORef (usWritePos state)
        let !winSize = VM.length (usRingBuf state)

        let finish !nRead !pos = do
                writeIORef (usWritePos state) (pos `mod` winSize)
                pure nRead

            loop !nRead !pos
                | nRead >= fromIntegral maxRead = finish nRead pos
                | otherwise = do
                    popped <- FFI.evtPop ipc cBuf 1
                    if popped == 0
                        then finish nRead pos
                        else do
                            CFloat sample <- peekElemOff cBuf 0
                            if isNaN sample
                                then skipEventFrame ipc cBuf state >> loop nRead pos
                                else do
                                    VM.write (usRingBuf state) (pos `mod` winSize) (realToFrac sample)
                                    loop (nRead + 1) (pos + 1)

        loop 0 writePos

skipEventFrame :: FFI.IpcHandle -> Ptr CFloat -> UlationState -> IO ()
skipEventFrame ipc cBuf state = do
    popped <- FFI.evtPop ipc cBuf 1
    when (popped == 1) $ do
        CFloat evtCode <- peekElemOff cBuf 0
        let payloadCount
                | evtCode == 1.0   = 1  -- XRUN
                | evtCode == 101.0 = 1  -- FX_LOADED
                | evtCode == 102.0 = 1  -- FX_ERROR
                | otherwise        = 0  -- PONG and unknown fixed-size events
        when (payloadCount > 0) $
            void $ FFI.evtPop ipc cBuf payloadCount
        if evtCode == 90.0
            then modifyIORef' (usEvtPongs state) (+ 1)
            else if evtCode == 1.0
                then modifyIORef' (usEvtXruns state) (+ 1)
                else if evtCode == 101.0
                    then modifyIORef' (usEvtFxLoaded state) (+ 1)
                    else if evtCode == 102.0
                        then modifyIORef' (usEvtFxErrors state) (+ 1)
                        else modifyIORef' (usEvtUnknown state) (+ 1)

-- ── Detection ──────────────────────────────────────────────────

-- | Extract the analysis window from the circular buffer and run YIN.
runDetection :: UlationConfig -> UlationState -> IO YinResult
runDetection cfg state = do
    writePos <- readIORef (usWritePos state)
    let !winSize = ulWindowSize cfg

    -- Extract window: samples from (writePos - winSize) to writePos
    window <- V.generateM winSize $ \i -> do
        let idx = (writePos - winSize + i) `mod` winSize
        VM.read (usRingBuf state) idx

    pure $! detectPitch (ulYinConfig cfg) window
