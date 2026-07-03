{- |
Module      : DeMoD.Note.Pitch
Description : Frequency, MIDI-note, and cents helpers for synth tracking
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Portions adapted from DeMoD-Note's Detector module (Copyright 2026, MIT).
MIT is compatible with this repository's GPL-3.0-only license.
-}

module DeMoD.Note.Pitch
    ( midiToFreq
    , freqToMidi
    , freqToCents
    , nearestNote
    , isInTune
    ) where

midiToFreq :: Int -> Double
midiToFreq note =
    440.0 * (2.0 ** ((fromIntegral note - 69.0) / 12.0))

freqToMidi :: Double -> Int
freqToMidi freq
    | freq <= 0.0 = -1
    | otherwise = round (69.0 + 12.0 * logBase 2.0 (freq / 440.0))

freqToCents :: Double -> Int -> Double
freqToCents freq midiNote =
    1200.0 * logBase 2.0 (freq / midiToFreq midiNote)

nearestNote :: Double -> (Int, Double)
nearestNote freq
    | freq <= 0.0 = (69, 0.0)
    | otherwise =
        let midiNote = freqToMidi freq
        in (midiNote, freqToCents freq midiNote)

isInTune :: Double -> Bool
isInTune cents = abs cents <= 5.0
