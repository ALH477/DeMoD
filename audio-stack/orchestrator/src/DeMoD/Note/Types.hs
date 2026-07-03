{- |
Module      : DeMoD.Note.Types
Description : Internal MIDI-note event currency for DeMoD synth routing
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Portions adapted from DeMoD-Note (Copyright 2026, MIT). MIT is compatible
with this repository's GPL-3.0-only license.
-}

module DeMoD.Note.Types
    ( MIDINote
    , Velocity
    , TimeStamp
    , MidiEvent(..)
    , MidiEventType(..)
    ) where

import Data.Word (Word64)

type MIDINote = Int
type Velocity = Int
type TimeStamp = Word64

data MidiEvent = MidiEvent
    { eventType :: !MidiEventType
    , eventNote :: !MIDINote
    , eventVel  :: !Velocity
    , eventTime :: !TimeStamp
    , eventBend :: !(Maybe Double)
    } deriving (Show, Eq)

data MidiEventType = NoteOn | NoteOff | PitchBend
    deriving (Show, Eq, Ord, Enum, Bounded)
