{- |
Module      : DeMoD.Ulation.YIN
Description : YIN pitch detection algorithm
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Pure Haskell implementation of the YIN algorithm (de Cheveigné & Kawahara, 2002)
for monophonic pitch detection. Optimized for guitar: 82 Hz (E2) to 1320 Hz (E6).

The algorithm:
  1. Difference function: d(τ) = Σ(x[n] - x[n+τ])²
  2. Cumulative mean normalized difference: d'(τ) = d(τ) / ((1/τ) Σ d(j))
  3. Absolute threshold: first τ where d'(τ) < threshold
  4. Parabolic interpolation for sub-sample accuracy
  5. Frequency: f = sampleRate / τ

Performance: ~200μs for a 2048-sample window at 48kHz on x86.
This runs on non-isolated cores (0-1), so GC pauses are acceptable.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DeMoD.Ulation.YIN
    ( -- * Core API
      YinConfig(..)
    , YinResult(..)
    , defaultConfig
    , detectPitch

      -- * Helpers
    , frequencyToMidi
    , midiToNoteName
    ) where

import qualified Data.Vector.Unboxed as V
import Data.Vector.Unboxed (Vector, (!))

-- ── Configuration ──────────────────────────────────────────────

data YinConfig = YinConfig
    { yinSampleRate :: !Double    -- ^ Sample rate in Hz (default: 48000)
    , yinThreshold  :: !Double    -- ^ Absolute threshold for d'(τ) (default: 0.15)
    , yinMinFreq    :: !Double    -- ^ Minimum detectable frequency (default: 75 Hz)
    , yinMaxFreq    :: !Double    -- ^ Maximum detectable frequency (default: 1400 Hz)
    } deriving (Show, Eq)

defaultConfig :: YinConfig
defaultConfig = YinConfig
    { yinSampleRate = 48000.0
    , yinThreshold  = 0.15
    , yinMinFreq    = 75.0
    , yinMaxFreq    = 1400.0
    }

-- ── Result ─────────────────────────────────────────────────────

data YinResult = YinResult
    { yinFrequency  :: !Double    -- ^ Detected frequency in Hz (0 = no detection)
    , yinConfidence :: !Double    -- ^ Confidence 0.0–1.0 (1 - d'(τ) at detected lag)
    , yinMidiNote   :: !Int       -- ^ Nearest MIDI note number (-1 = no detection)
    , yinPeriod     :: !Double    -- ^ Detected period in samples (0 = none)
    } deriving (Show, Eq)

noDetection :: YinResult
noDetection = YinResult 0.0 0.0 (-1) 0.0

-- ── Step 1: Difference Function ────────────────────────────────
--
-- d(τ) = Σ_{n=0}^{W-1} (x[n] - x[n+τ])²
--
-- where W = windowSize / 2 (we only search up to half the window).

differenceFunction :: Vector Double -> Int -> Vector Double
differenceFunction !buf !halfW = V.generate halfW go
  where
    go 0 = 0.0
    go !tau =
        let !s = V.foldl' (\acc j ->
                    let !d = (buf ! j) - (buf ! (j + tau))
                    in acc + d * d
                 ) 0.0 (V.enumFromN 0 halfW)
        in s
{-# INLINE differenceFunction #-}

-- ── Step 2: Cumulative Mean Normalized Difference ──────────────
--
-- d'(τ) = d(τ) / ((1/τ) Σ_{j=1}^{τ} d(j))
--       = d(τ) * τ / Σ_{j=1}^{τ} d(j)
--
-- d'(0) = 1 by convention.

cumulativeMeanNormalize :: Vector Double -> Vector Double
cumulativeMeanNormalize !df = V.generate len go
  where
    !len = V.length df

    go 0 = 1.0
    go !tau =
        let !cumSum = V.foldl' (+) 0.0 (V.slice 1 tau df)
        in if cumSum < 1.0e-10
            then 1.0  -- avoid division by zero
            else (df ! tau) * fromIntegral tau / cumSum
{-# INLINE cumulativeMeanNormalize #-}

-- ── Step 3: Absolute Threshold ─────────────────────────────────
--
-- Find the first τ (within the valid frequency range) where
-- d'(τ) < threshold. If multiple dips exist, take the first.

absoluteThreshold :: Double -> Int -> Int -> Vector Double -> Maybe Int
absoluteThreshold !thresh !tauMin !tauMax !cmndf
    | tauMin >= len || tauMax >= len = Nothing
    | otherwise = findFirst tauMin
  where
    !len = V.length cmndf

    -- Find first tau below threshold, then find the local minimum
    findFirst !tau
        | tau > tauMax = Nothing
        | (cmndf ! tau) < thresh = Just (findLocalMin tau)
        | otherwise = findFirst (tau + 1)

    -- Walk forward while d' keeps decreasing
    findLocalMin !tau
        | tau + 1 > tauMax = tau
        | (cmndf ! (tau + 1)) < (cmndf ! tau) = findLocalMin (tau + 1)
        | otherwise = tau
{-# INLINE absoluteThreshold #-}

-- ── Step 4: Parabolic Interpolation ───────────────────────────
--
-- Refine the integer τ to sub-sample accuracy using the three points
-- around the minimum: d'(τ-1), d'(τ), d'(τ+1).
--
-- τ_refined = τ + (d'(τ-1) - d'(τ+1)) / (2 * (d'(τ-1) - 2*d'(τ) + d'(τ+1)))

parabolicInterp :: Vector Double -> Int -> Double
parabolicInterp !cmndf !tau
    | tau < 1 || tau >= V.length cmndf - 1 = fromIntegral tau
    | otherwise =
        let !a = cmndf ! (tau - 1)
            !b = cmndf ! tau
            !c = cmndf ! (tau + 1)
            !denom = 2.0 * (a - 2.0 * b + c)
        in if abs denom < 1.0e-10
            then fromIntegral tau
            else fromIntegral tau + (a - c) / denom
{-# INLINE parabolicInterp #-}

-- ── Full Detection Pipeline ───────────────────────────────────

{- |
Detect the fundamental frequency of a monophonic signal.

Input: a window of audio samples (recommended: 2048 samples at 48kHz).
The window should be at least 2× the maximum period (sr/minFreq).

Returns a YinResult with frequency, confidence, and MIDI note.
Runs in ~200μs for 2048 samples on modern x86.
-}
detectPitch :: YinConfig -> Vector Double -> YinResult
detectPitch !cfg !buf
    | V.length buf < halfW * 2 = noDetection
    | otherwise =
        case absoluteThreshold (yinThreshold cfg) tauMin tauMax cmndf of
            Nothing  -> noDetection
            Just tau ->
                let !refinedTau = parabolicInterp cmndf tau
                    !freq = yinSampleRate cfg / refinedTau
                    !conf = 1.0 - (cmndf ! tau)
                    !midi = frequencyToMidi freq
                in if freq >= yinMinFreq cfg && freq <= yinMaxFreq cfg
                    then YinResult freq (max 0.0 (min 1.0 conf)) midi refinedTau
                    else noDetection
  where
    !halfW  = V.length buf `div` 2
    !tauMin = max 2 (floor (yinSampleRate cfg / yinMaxFreq cfg))
    !tauMax = min (halfW - 1) (ceiling (yinSampleRate cfg / yinMinFreq cfg))

    !df    = differenceFunction buf halfW
    !cmndf = cumulativeMeanNormalize df

-- ── Frequency / MIDI Conversion ───────────────────────────────

-- | Convert frequency to nearest MIDI note number.
-- A4 = 440 Hz = MIDI 69.
frequencyToMidi :: Double -> Int
frequencyToMidi freq
    | freq <= 0 = -1
    | otherwise = round (69.0 + 12.0 * logBase 2.0 (freq / 440.0))

-- | Convert MIDI note number to note name (e.g., "A4", "C#3").
midiToNoteName :: Int -> String
midiToNoteName midi
    | midi < 0 || midi > 127 = "---"
    | otherwise =
        let noteNames = ["C", "C#", "D", "D#", "E", "F",
                         "F#", "G", "G#", "A", "A#", "B"]
            noteName  = noteNames !! (midi `mod` 12)
            octave    = (midi `div` 12) - 1
        in noteName ++ show octave
