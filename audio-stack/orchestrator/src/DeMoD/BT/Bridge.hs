{- |
Module      : DeMoD.BT.Bridge
Description : Publish OSCRouter state as BLE-MIDI
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The bridge subscribes to the OSC Router's TVars (pitch, tempo, FX) and
publishes the changes as BLE-MIDI events on the libdemod_bt-managed
peripheral. A paired DAW host then receives standard MIDI input that
the user can route at any plugin (including the DeMoD VST3 itself).

Mappings — symmetric with the plugin-side handler in @demod_plugin.c@:

 * /Pitch wheel on channel 16/:    live YIN frequency, 14-bit centred
                                   at 8192 over a ±2-semitone window
                                   around the detected MIDI note.
 * /CC on slot channel/:           FX param value (slot 0..15 maps to
                                   channels 1..16; CC# is the param
                                   index, value is 0..127 normalised).
 * /CC #127 on slot channel/:      FX bypass for that slot (0 = active,
                                   127 = bypassed).
 * /Program Change on channel 1/:  Tempo, BPM clamped to 0..127 — a
                                   stand-in until we expose a real
                                   path-hash mapping for FX loads.

A coalescing layer (max ~100 Hz) prevents flooding when many params
change in rapid succession. MIDI Clock (0xF8) is not emitted in v1 —
hosts that need transport sync can derive it from the PC tempo or run
their own clock.
-}

{-# LANGUAGE NumericUnderscores #-}

module DeMoD.BT.Bridge
    ( BridgeConfig(..)
    , defaultBridgeConfig
    , runBridge
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forM_, unless, when)
import Data.Bits ((.&.), (.|.), shiftR)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Word (Word8, Word32)
import System.IO (hPutStrLn, stderr)

import qualified DeMoD.BT.FFI as BT
import qualified DeMoD.OSCRouter as Router

-- ── Configuration ──────────────────────────────────────────────

data BridgeConfig = BridgeConfig
    { bcDeviceName :: !String   -- ^ BLE-MIDI advertised local name.
    , bcPublishHz  :: !Int      -- ^ Max publish rate (default 100 Hz).
    } deriving (Show)

defaultBridgeConfig :: BridgeConfig
defaultBridgeConfig = BridgeConfig
    { bcDeviceName = "DeMoD Guitar"
    , bcPublishHz  = 100
    }

-- ── Cached state ───────────────────────────────────────────────

data Cached = Cached
    { cPitch    :: !Router.PitchUpdate
    , cTempo    :: !Router.TempoUpdate
    , cFx       :: !Router.FxUpdate
    } deriving (Eq)

emptyCached :: Cached
emptyCached = Cached
    { cPitch = Router.PitchUpdate 0 0 (-1)
    , cTempo = Router.TempoUpdate 120 0
    , cFx    = Router.FxUpdate 0 (replicate 16 0)
    }

-- ── Bridge ─────────────────────────────────────────────────────

logInfo :: String -> IO ()
logInfo msg = hPutStrLn stderr $ "[bt-bridge] " ++ msg

logError :: String -> IO ()
logError msg = hPutStrLn stderr $ "[bt-bridge] ERROR: " ++ msg

{- |
Run the bridge. Brings up the BLE-MIDI peripheral, then loops at
@bcPublishHz@, diff-publishing TVar changes until @running@ goes False.
Tears down the peripheral cleanly on exit.
-}
runBridge
    :: BridgeConfig
    -> Router.RouterState
    -> TVar Bool        -- ^ shutdown flag (False = stop)
    -> IO ()
runBridge cfg routerState running = do
    started <- BT.midiStart (bcDeviceName cfg)
    if not started
        then logError "midiStart failed; bridge will idle"
        else logInfo $ "BLE-MIDI peripheral up (" ++ bcDeviceName cfg ++ ")"

    cacheRef <- newIORef emptyCached
    loop cacheRef
    BT.midiStop
    logInfo "stopped"
  where
    delayUs = max 1 (1_000_000 `div` max 1 (bcPublishHz cfg))

    loop cacheRef = do
        alive <- readTVarIO running
        when alive $ do
            cur <- readCurrent routerState
            prev <- readIORef cacheRef
            unless (cur == prev) $ do
                publishDiffs prev cur
                writeIORef cacheRef cur
            threadDelay delayUs
            loop cacheRef

readCurrent :: Router.RouterState -> IO Cached
readCurrent rs = atomically $
    Cached <$> readTVar (Router.rsPitch rs)
           <*> readTVar (Router.rsTempo rs)
           <*> readTVar (Router.rsFx rs)

-- ── Diff & publish ─────────────────────────────────────────────

publishDiffs :: Cached -> Cached -> IO ()
publishDiffs prev cur = do
    -- Pitch: emit a 14-bit pitch wheel on channel 16 when the
    -- frequency changed enough to matter (>= 0.1 Hz).
    when (pitchChanged (cPitch prev) (cPitch cur)) $ do
        let hz = Router.puFrequency (cPitch cur)
            ref = referencePitchHz (cPitch cur)
            wheel = pitchWheelValue hz ref
        emitPitchWheel 15 wheel

    -- FX params per slot: scan all 16 slots; emit a CC for any param
    -- whose value moved.
    forM_ (zip3 [0..] (Router.fuParams (cFx prev)) (Router.fuParams (cFx cur))) $
        \(slot, oldV, newV) ->
            when (abs (oldV - newV) > 1.0e-4) $ do
                let chan = fromIntegral (slot `mod` 16)
                    cc   = 0 :: Word8  -- single param per slot for now;
                                       -- multi-param comes when the
                                       -- router exposes per-slot
                                       -- per-idx params.
                    val  = floatToCC newV
                emitCc chan cc val

    -- FX bypass mask: bit i = 1 means slot i is bypassed; emit
    -- CC#127 = 0/127 on the slot's channel.
    when (Router.fuBypassMask (cFx prev) /= Router.fuBypassMask (cFx cur)) $ do
        let m = Router.fuBypassMask (cFx cur)
        forM_ [0 .. 15] $ \slot -> do
            let bypassed = testBit32 m slot
                chan     = fromIntegral slot
                value    = if bypassed then 127 else 0
            emitCc chan 127 value

    -- Tempo: program-change stand-in (the cleanest way to surface BPM
    -- on a 1-byte channel without sysex). Bias to the 0..127 PC range.
    when (Router.tuBpm (cTempo prev) /= Router.tuBpm (cTempo cur)) $ do
        let bpm = Router.tuBpm (cTempo cur)
            pc  = max 0 (min 127 (round bpm :: Int))
        emitProgramChange 0 (fromIntegral pc)

-- ── Helpers ────────────────────────────────────────────────────

pitchChanged :: Router.PitchUpdate -> Router.PitchUpdate -> Bool
pitchChanged a b =
    abs (Router.puFrequency a - Router.puFrequency b) > 0.1
        || Router.puMidiNote a /= Router.puMidiNote b

-- | Reference pitch in Hz for the current MIDI note. ±2 semitones from
-- this value maps onto the full 14-bit pitch-wheel range.
referencePitchHz :: Router.PitchUpdate -> Float
referencePitchHz pu
    | Router.puMidiNote pu < 0 = 440  -- A4 fallback.
    | otherwise = 440 * (2 ** ((fromIntegral (Router.puMidiNote pu) - 69) / 12))

{- |
Map a pitch frequency to a 14-bit pitch wheel value over a
±2-semitone window centred on `ref`.

  ratio = log2(hz / ref)  (in semitones / 12)
  out   = clamp 0..16383 (8192 + ratio * 8192 / 2)

ratio = ±2 semitones → ±8192 from centre.
-}
pitchWheelValue :: Float -> Float -> Word32
pitchWheelValue 0 _ = 8192
pitchWheelValue hz ref =
    let semitones = (logBase 2 (hz / ref)) * 12
        scaled    = round (8192 + semitones * 8192 / 2)
        clamped   = max 0 (min 16383 (scaled :: Int))
    in fromIntegral clamped

floatToCC :: Float -> Word8
floatToCC v =
    let v' = max 0 (min 1 v)
    in fromIntegral (round (v' * 127) :: Int)

testBit32 :: Word32 -> Int -> Bool
testBit32 m i = (m `shiftR` i) .&. 1 /= 0

-- ── Wire encoders ──────────────────────────────────────────────
--
-- All emitters push 3-byte messages — Rust adds the BLE-MIDI 2-byte
-- header/timestamp.

-- | channel: 0..15
emitCc :: Word8 -> Word8 -> Word8 -> IO ()
emitCc channel cc val = do
    let status = 0xB0 .|. (channel .&. 0x0F)
    sendBS (BS.pack [status, cc .&. 0x7F, val .&. 0x7F])

emitProgramChange :: Word8 -> Word8 -> IO ()
emitProgramChange channel pc = do
    let status = 0xC0 .|. (channel .&. 0x0F)
    sendBS (BS.pack [status, pc .&. 0x7F])

-- | channel: 0..15. value: 0..16383. 8192 = centre.
emitPitchWheel :: Word8 -> Word32 -> IO ()
emitPitchWheel channel value = do
    let status = 0xE0 .|. (channel .&. 0x0F)
        lsb    = fromIntegral (value .&. 0x7F)
        msb    = fromIntegral ((value `shiftR` 7) .&. 0x7F)
    sendBS (BS.pack [status, lsb, msb])

sendBS :: BS.ByteString -> IO ()
sendBS bs = do
    ok <- BT.midiSendBytes bs
    unless ok $ logError "midiSendBytes failed"
