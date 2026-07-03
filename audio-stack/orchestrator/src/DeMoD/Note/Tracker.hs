{- |
Module      : DeMoD.Note.Tracker
Description : Hysteretic note tracker that drives RT Faust instruments
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The transition pattern is adapted from DeMoD-Note's Backend.handleNoteChange
(Copyright 2026, MIT), but emits DeMoD command-ring note messages instead of
OSC/FluidSynth messages.
-}

{-# LANGUAGE RecordWildCards #-}

module DeMoD.Note.Tracker
    ( NoteTrackerConfig(..)
    , NoteTrackerState(..)
    , NoteTracker(..)
    , defaultNoteTrackerConfig
    , newNoteTracker
    , handleYinResult
    ) where

import Control.Concurrent.STM
import Data.IORef
import Data.Word (Word64)
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Array (withArray)
import System.IO (hPutStrLn, stderr)

import qualified DeMoD.IPC.FFI as FFI
import DeMoD.Note.Pitch (isInTune, nearestNote)
import DeMoD.Note.Types
import DeMoD.Ulation.YIN (YinResult(..))

data NoteTrackerConfig = NoteTrackerConfig
    { ntSlot          :: !Int
    , ntOnThreshold   :: !Double
    , ntOffThreshold  :: !Double
    , ntStableWindows :: !Int
    , ntVelocity      :: !Velocity
    } deriving (Show, Eq)

defaultNoteTrackerConfig :: NoteTrackerConfig
defaultNoteTrackerConfig = NoteTrackerConfig
    { ntSlot = 0
    , ntOnThreshold = 0.70
    , ntOffThreshold = 0.30
    , ntStableWindows = 2
    , ntVelocity = 100
    }

data NoteTrackerState = NoteTrackerState
    { currentNote  :: !(Maybe MIDINote)
    , pendingNote  :: !(Maybe MIDINote)
    , stableCount  :: !Int
    , lastEmitTime :: !Word64
    } deriving (Show, Eq)

data NoteTracker = NoteTracker
    { trackerConfig :: !NoteTrackerConfig
    , trackerIpc    :: !FFI.IpcHandle
    , trackerState  :: !(IORef NoteTrackerState)
    , noteEventChan :: !(TChan MidiEvent)
    }

newNoteTracker :: NoteTrackerConfig -> FFI.IpcHandle -> IO NoteTracker
newNoteTracker cfg ipc = do
    state <- newIORef (NoteTrackerState Nothing Nothing 0 0)
    chan <- newTChanIO
    pure $ NoteTracker cfg ipc state chan

handleYinResult :: NoteTracker -> YinResult -> IO [MidiEvent]
handleYinResult tracker result = do
    now <- FFI.clockUs
    state0 <- readIORef (trackerState tracker)
    let (state1, events) = stepTracker (trackerConfig tracker) now result state0
    ok <- mapM (emitMidiEvent tracker) events
    if and ok
        then do
            let state2 =
                    if null events
                        then state1
                        else state1 { lastEmitTime = now }
            writeIORef (trackerState tracker) state2
            pure events
        else do
            hPutStrLn stderr "[tracker] command ring full; dropping note transition"
            pure []

stepTracker
    :: NoteTrackerConfig
    -> Word64
    -> YinResult
    -> NoteTrackerState
    -> (NoteTrackerState, [MidiEvent])
stepTracker NoteTrackerConfig{..} now YinResult{..} st
    | yinConfidence < ntOffThreshold =
        case currentNote st of
            Nothing ->
                (st { pendingNote = Nothing, stableCount = 0 }, [])
            Just note ->
                ( st { currentNote = Nothing, pendingNote = Nothing, stableCount = 0 }
                , [mkEvent NoteOff note 0]
                )

    | yinConfidence > ntOnThreshold
      && yinMidiNote >= 0
      && trustedDetection =
        if currentNote st == Just yinMidiNote
            then (st { pendingNote = Nothing, stableCount = ntStableWindows }, [])
            else
                let nextStable =
                        if pendingNote st == Just yinMidiNote
                            then stableCount st + 1
                            else 1
                    primed = st { pendingNote = Just yinMidiNote, stableCount = nextStable }
                in if nextStable >= ntStableWindows
                    then
                        let offEvents =
                                maybe [] (\note -> [mkEvent NoteOff note 0]) (currentNote st)
                            onEvent = mkEvent NoteOn yinMidiNote ntVelocity
                        in ( primed
                                { currentNote = Just yinMidiNote
                                , pendingNote = Nothing
                                , stableCount = ntStableWindows
                                }
                           , offEvents ++ [onEvent]
                           )
                    else (primed, [])

    | otherwise =
        (st, [])
  where
    (_nearest, cents) = nearestNote yinFrequency
    trustedDetection = yinFrequency > 0.0 && isInTune cents
    mkEvent typ note vel = MidiEvent
        { eventType = typ
        , eventNote = note
        , eventVel = vel
        , eventTime = now
        , eventBend = Nothing
        }

emitMidiEvent :: NoteTracker -> MidiEvent -> IO Bool
emitMidiEvent NoteTracker{..} evt = do
    let cfg = trackerConfig
        payload = case eventType evt of
            NoteOn ->
                [ 20.0
                , fromIntegral (ntSlot cfg)
                , fromIntegral (eventNote evt)
                , fromIntegral (eventVel evt)
                ]
            NoteOff ->
                [ 21.0
                , fromIntegral (ntSlot cfg)
                , fromIntegral (eventNote evt)
                ]
            PitchBend ->
                []
    if null payload
        then pure True
        else withArray (map CFloat payload) $ \ptr -> do
            let count = fromIntegral (length payload)
            written <- FFI.cmdPush trackerIpc ptr count
            if written == count
                then do
                    atomically $ writeTChan noteEventChan evt
                    hPutStrLn stderr $
                        "[tracker] " ++ show (eventType evt)
                        ++ " " ++ show (eventNote evt)
                    pure True
                else pure False
