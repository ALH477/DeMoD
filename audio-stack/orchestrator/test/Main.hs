{- |
Module      : Main (test)
Description : Integration tests for DeMoD orchestrator
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Tests the FFI bindings, YIN pitch detection with synthetic sine waves,
and the local runtime control boundary.
-}

{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM)
import Data.Aeson (Value(..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.IORef (readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Array (withArray)
import Network.Socket
    ( Family(AF_UNIX)
    , SockAddr(SockAddrUnix)
    , SocketType(Stream)
    , connect
    , defaultProtocol
    , socket
    )
import qualified Network.Socket as NS
import System.Directory
    ( createDirectoryIfMissing
    , doesPathExist
    , getTemporaryDirectory
    , removePathForcibly
    )
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO
    ( BufferMode(LineBuffering)
    , IOMode(ReadWriteMode)
    , hClose
    , hFlush
    , hGetLine
    , hPutStrLn
    , hSetBuffering
    )

import qualified Data.Vector.Unboxed as V
import qualified Data.Vector.Unboxed.Mutable as VM

import DeMoD.CLI (CliResult(..), parseArgs)
import qualified DeMoD.Control as Control
import qualified DeMoD.IPC.FFI as FFI
import qualified DeMoD.Note.Tracker as NoteTracker
import qualified DeMoD.Note.Types as NoteTypes
import qualified DeMoD.OSCRouter as OSCRouter
import qualified DeMoD.Orchestrator as Orchestrator
import qualified DeMoD.ProcessTree as ProcessTree
import qualified DeMoD.Supervisor as Supervisor
import qualified DeMoD.Ulation.Engine as Ulation
import DeMoD.Ulation.YIN

data TestResult = Pass | Fail String

runTest :: String -> IO TestResult -> IO Bool
runTest name action = do
    result <- action
    case result of
        Pass -> do
            putStrLn $ "  PASS  " ++ name
            pure True
        Fail msg -> do
            putStrLn $ "  FAIL  " ++ name ++ ": " ++ msg
            pure False

assert :: Bool -> String -> IO TestResult
assert True _ = pure Pass
assert False msg = pure (Fail msg)

generateSine :: Double -> Double -> Int -> V.Vector Double
generateSine freq sampleRate numSamples =
    V.generate numSamples $ \i ->
        sin (2.0 * pi * freq * fromIntegral i / sampleRate)

generateHarmonic :: Double -> Double -> Int -> V.Vector Double
generateHarmonic freq sampleRate numSamples =
    V.generate numSamples $ \i ->
        let t = fromIntegral i / sampleRate
            f1 = sin (2.0 * pi * freq * t)
            f2 = 0.5 * sin (2.0 * pi * 2 * freq * t)
            f3 = 0.25 * sin (2.0 * pi * 3 * freq * t)
        in f1 + f2 + f3

testIpcCreateDestroy :: IO TestResult
testIpcCreateDestroy = do
    mIpc <- FFI.ipcCreate FFI.defaultSpscCapacity
    case mIpc of
        Nothing -> pure (Fail "ipcCreate returned Nothing")
        Just ipc -> FFI.ipcDestroy ipc >> pure Pass

testTripleBufferRoundTrip :: IO TestResult
testTripleBufferRoundTrip = do
    mIpc <- FFI.ipcCreate FFI.defaultSpscCapacity
    case mIpc of
        Nothing -> pure (Fail "ipcCreate failed")
        Just ipc -> do
            snap <- FFI.tbBeginWrite ipc
            FFI.snapSetPitch snap 440.0 0.95 69
            FFI.snapSetTempo snap 120.0 42
            FFI.tbPublish ipc

            buf <- mallocBytes FFI.paramSnapshotSize
            _ <- FFI.tbReadCopy ipc buf
            pitchHz <- FFI.snapGetPitchHz buf
            bpm <- FFI.snapGetBpm buf

            free buf
            FFI.ipcDestroy ipc

            assert
                ( realToFrac pitchHz == (440.0 :: Float)
               && realToFrac bpm == (120.0 :: Float)
                )
                "pitch or bpm mismatch"

testUlationSkipsEventFrames :: IO TestResult
testUlationSkipsEventFrames = do
    mIpc <- FFI.ipcCreate FFI.defaultSpscCapacity
    case mIpc of
        Nothing -> pure (Fail "ipcCreate failed")
        Just ipc -> do
            state <- Ulation.mkUlationState Ulation.defaultUlationConfig
            let mixed =
                    [ CFloat 0.1
                    , CFloat 0.2
                    , CFloat (0 / 0)
                    , CFloat 90.0
                    , CFloat 0.3
                    , CFloat (0 / 0)
                    , CFloat 1.0
                    , CFloat 7.0
                    , CFloat 0.4
                    , CFloat 0.5
                    ]

            pushed <- withArray mixed $ \buf ->
                FFI.evtPush ipc buf (fromIntegral (length mixed))
            if pushed /= fromIntegral (length mixed)
                then FFI.ipcDestroy ipc >> pure (Fail "evtPush failed")
                else do
                    nRead <- Ulation.readAudioSamples ipc 16 state
                    writePos <- readIORef (Ulation.usWritePos state)
                    samples <- forM [0 .. 4] $ \i ->
                        VM.read (Ulation.usRingBuf state) i
                    pongs <- readIORef (Ulation.usEvtPongs state)
                    xruns <- readIORef (Ulation.usEvtXruns state)
                    unknown <- readIORef (Ulation.usEvtUnknown state)
                    avail <- FFI.evtAvailable ipc
                    FFI.ipcDestroy ipc

                    let expected = [0.1, 0.2, 0.3, 0.4, 0.5] :: [Double]
                        closeEnough a b = abs (a - b) < 1e-6
                    assert
                        ( nRead == 5
                       && writePos == 5
                       && avail == 0
                       && pongs == 1
                       && xruns == 1
                       && unknown == 0
                       && and (zipWith closeEnough samples expected)
                        )
                        "Ulation reader did not skip event frames correctly"

testSupervisorFailsMissingBinaryLaunch :: IO TestResult
testSupervisorFailsMissingBinaryLaunch = do
    running <- newTVarIO True
    sv <- Supervisor.newSupervisor running
    let childName = "missing-binary"
        spec = Supervisor.ChildSpec
            { Supervisor.csName = childName
            , Supervisor.csBinary = "/definitely/missing/demod-rt"
            , Supervisor.csArgs = []
            , Supervisor.csCpuCore = Nothing
            , Supervisor.csSchedFifo = Nothing
            , Supervisor.csMlockAll = False
            , Supervisor.csRestartBaseMs = 10
            , Supervisor.csRestartMaxMs = 10
            , Supervisor.csShutdownMs = 10
            , Supervisor.csMaxRestarts = -1
            }

    Supervisor.spawnChild sv spec
    result <- waitForFailed sv childName 20
    atomically $ writeTVar running False
    Supervisor.shutdownAll sv

    case result of
        Just (Supervisor.Failed msg) ->
            assert
                ( not (null msg)
               && ( "executeFile failed" `isInfixOf` msg
                 || "startup completed" `isInfixOf` msg
                  )
                )
                "missing binary should report a launch failure"
        Just status ->
            pure $ Fail $ "expected Failed status, got " ++ show status
        Nothing ->
            pure $ Fail "child never reached Failed status"

testCliParsesProductBoundaryFlags :: IO TestResult
testCliParsesProductBoundaryFlags =
    case parseArgs
        [ "--rt-binary", "/tmp/demod-rt"
        , "--rt-core", "6"
        , "--control-socket", "/run/demod/control.sock"
        , "--data-dir", "/var/lib/demod"
        , "--setup-marker", "/var/lib/demod/setup/first-boot-complete"
        , "--synth"
        ]
    of
        Left err ->
            pure $ Fail $ "parseArgs failed: " ++ err
        Right CliHelp ->
            pure $ Fail "expected CliRun, got CliHelp"
        Right (CliRun cfg) ->
            assert
                ( Orchestrator.cfgRtBinary cfg == "/tmp/demod-rt"
               && Orchestrator.cfgRtCore cfg == 6
               && Orchestrator.cfgControlSocket cfg == Just "/run/demod/control.sock"
               && Orchestrator.cfgDataDir cfg == "/var/lib/demod"
               && Orchestrator.cfgSetupMarker cfg
                    == Just "/var/lib/demod/setup/first-boot-complete"
               && Orchestrator.cfgSynthEnable cfg
                )
                "CLI flags were not parsed into the orchestrator config"

testRtSpecUsesExplicitSlots :: IO TestResult
testRtSpecUsesExplicitSlots =
    let spec = ProcessTree.mkRtAudioSpec
            "/tmp/demod-rt"
            6
            80
            [ Nothing
            , Just "/tmp/slot-1.so"
            , Nothing
            , Just "/tmp/slot-3.so"
            ]
        expectedArgs =
            [ "--core", "6"
            , "--faust-slot", "1", "/tmp/slot-1.so"
            , "--faust-slot", "3", "/tmp/slot-3.so"
            ]
    in assert
        (Supervisor.csArgs spec == expectedArgs)
        "RT spec should preserve explicit slot numbers when launching demod-rt"

testNoteTrackerSyntheticA4 :: IO TestResult
testNoteTrackerSyntheticA4 = do
    mIpc <- FFI.ipcCreate FFI.defaultSpscCapacity
    case mIpc of
        Nothing -> pure (Fail "ipcCreate failed")
        Just ipc -> do
            tracker <- NoteTracker.newNoteTracker
                NoteTracker.defaultNoteTrackerConfig
                ipc
            ev1 <- NoteTracker.handleYinResult tracker (YinResult 440.0 0.95 69 109.0)
            ev2 <- NoteTracker.handleYinResult tracker (YinResult 440.0 0.96 69 109.0)
            ev3 <- NoteTracker.handleYinResult tracker (YinResult 0.0 0.10 (-1) 0.0)
            FFI.ipcDestroy ipc
            let onOk = case ev1 ++ ev2 of
                    [evt] ->
                        NoteTypes.eventType evt == NoteTypes.NoteOn
                        && NoteTypes.eventNote evt == 69
                    _ -> False
                offOk = case ev3 of
                    [evt] ->
                        NoteTypes.eventType evt == NoteTypes.NoteOff
                        && NoteTypes.eventNote evt == 69
                    _ -> False
            assert (onOk && offOk) "tracker should emit NoteOn 69 then NoteOff 69"

testControlSocketRoundTrip :: IO TestResult
testControlSocketRoundTrip = do
    tmpRoot <- getTemporaryDirectory
    nowUs <- FFI.clockUs
    let baseDir = tmpRoot </> ("demod-control-test-" ++ show nowUs)
        socketPath = baseDir </> "control.sock"
        markerPath = baseDir </> "first-boot-complete"
        fxPath = baseDir </> "test-fx.so"

    createDirectoryIfMissing True baseDir
    writeFile markerPath "completed_at=test\n"
    writeFile fxPath "fake-shared-object\n"

    running <- newTVarIO True
    router <- OSCRouter.newRouterState
    sv <- Supervisor.newSupervisor running

    mIpc <- FFI.ipcCreate FFI.defaultSpscCapacity
    case mIpc of
        Nothing -> pure (Fail "ipcCreate failed")
        Just ipc -> do
            let cfg = Control.defaultControlConfig
                    { Control.ccSocketPath = socketPath
                    , Control.ccSetupMarker = Just markerPath
                    }
            rtSlots <- newTVarIO (replicate 16 Nothing)
            let applyRtSlots slots = atomically (writeTVar rtSlots slots) >> pure (Right ())
            result <- withAsync
                (Control.runControlServer cfg ipc router sv rtSlots applyRtSlots running)
                $ \_ -> do
                ready <- waitForPath socketPath 40
                if not ready
                    then pure (Fail "control socket never appeared")
                    else do
                        healthResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"health\",\"op\":\"get_health\"}"
                        tempoResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"tempo\",\"op\":\"set_bpm\",\"bpm\":132.5}"
                        paramResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"param\",\"op\":\"set_param\",\"slot\":0,\"idx\":3,\"value\":0.65}"
                        synthModeResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"mode\",\"verb\":\"synth.mode\",\"args\":{\"mode\":\"synth-only\"}}"
                        synthGainResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"synth-gain\",\"op\":\"synth.gain\",\"value\":0.5}"
                        synthNoteResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"note\",\"op\":\"synth.note_on\",\"slot\":0,\"note\":69,\"velocity\":100}"
                        loadResp <- sendJsonRequest socketPath
                            ("{\"v\":1,\"id\":\"load\",\"op\":\"load_fx\",\"slot\":0,\"path\":\""
                                ++ fxPath ++ "\"}")
                        unloadResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"unload\",\"op\":\"unload_fx\",\"slot\":0}"
                        slotGainResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"sg\",\"op\":\"set_slot_gain\",\"slot\":2,\"gain\":0.5}"
                        slotPanResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"sp\",\"op\":\"set_slot_pan\",\"slot\":2,\"pan\":-0.5}"
                        slotMuteResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"sm\",\"op\":\"set_slot_mute\",\"slot\":3,\"on\":true}"
                        slotSoloResp <- sendJsonRequest socketPath
                            "{\"v\":1,\"id\":\"ss\",\"op\":\"set_slot_solo\",\"slot\":3,\"on\":true}"
                        let slotMixerOk = all responseOk
                                [slotGainResp, slotPanResp, slotMuteResp, slotSoloResp]
                        case sequence
                            [ healthResp
                            , tempoResp
                            , paramResp
                            , synthModeResp
                            , synthGainResp
                            , synthNoteResp
                            , loadResp
                            , unloadResp
                            ]
                            of
                            Left err ->
                                pure (Fail err)
                            Right
                                [ healthValue
                                , tempoValue
                                , paramValue
                                , synthModeValue
                                , synthGainValue
                                , synthNoteValue
                                , loadValue
                                , unloadValue
                                ] -> do
                                tempo <- readTVarIO (OSCRouter.rsTempo router)
                                fx <- readTVarIO (OSCRouter.rsFx router)
                                synth <- readTVarIO (OSCRouter.rsSynth router)
                                finalSlots <- readTVarIO rtSlots
                                let base =
                                        validateControlResponses
                                            healthValue
                                            tempoValue
                                            paramValue
                                            synthModeValue
                                            synthGainValue
                                            synthNoteValue
                                            loadValue
                                            unloadValue
                                            tempo
                                            fx
                                            synth
                                            finalSlots
                                pure $ case base of
                                    Pass ->
                                        if slotMixerOk
                                            then Pass
                                            else Fail "set_slot_* ops did not return ok"
                                    other -> other
                            Right _ ->
                                pure (Fail "unexpected control response count")

            atomically $ writeTVar running False
            FFI.ipcDestroy ipc
            removePathForcibly baseDir
            pure result

waitForFailed :: Supervisor.SupervisorState -> String -> Int -> IO (Maybe Supervisor.ChildStatus)
waitForFailed sv childName attempts = go attempts
  where
    go remaining = do
        status <- Supervisor.getChildStatus sv childName
        case status of
            Just failed@(Supervisor.Failed _) -> pure (Just failed)
            _ | remaining <= 0 -> pure status
              | otherwise -> do
                    threadDelay 50_000
                    go (remaining - 1)

waitForPath :: FilePath -> Int -> IO Bool
waitForPath path attempts = go attempts
  where
    go remaining = do
        exists <- doesPathExist path
        if exists
            then pure True
            else if remaining <= 0
                then pure False
                else threadDelay 50_000 >> go (remaining - 1)

sendJsonRequest :: FilePath -> String -> IO (Either String Value)
sendJsonRequest socketPath payload = do
    sock <- socket AF_UNIX Stream defaultProtocol
    connect sock (SockAddrUnix socketPath)
    handle <- NS.socketToHandle sock ReadWriteMode
    hSetBuffering handle LineBuffering
    hPutStrLn handle payload
    hFlush handle
    line <- hGetLine handle
    hClose handle
    pure $ A.eitherDecode (BSL.pack line)

lookupField :: T.Text -> Value -> Either String Value
lookupField key (Object obj) =
    maybe
        (Left ("missing field: " ++ T.unpack key))
        Right
        (KM.lookup (K.fromText key) obj)
lookupField key _ =
    Left ("expected object when reading field: " ++ T.unpack key)

asBoolField :: Value -> Either String Bool
asBoolField (Bool b) = Right b
asBoolField _ = Left "expected bool"

-- a control response is "ok" when it parsed and carries {"ok": true}
responseOk :: Either String Value -> Bool
responseOk r = case r >>= lookupField "ok" >>= asBoolField of
    Right True -> True
    _ -> False

validateControlResponses
    :: Value
    -> Value
    -> Value
    -> Value
    -> Value
    -> Value
    -> Value
    -> Value
    -> OSCRouter.TempoUpdate
    -> OSCRouter.FxUpdate
    -> OSCRouter.SynthUpdate
    -> [Maybe FilePath]
    -> TestResult
validateControlResponses
    healthResp
    tempoResp
    paramResp
    synthModeResp
    synthGainResp
    synthNoteResp
    loadResp
    unloadResp
    tempo
    fx
    synth
    finalSlots =
    case do
        healthOk <- lookupField "ok" healthResp >>= asBoolField
        healthData <- lookupField "data" healthResp
        setupComplete <- lookupField "setup_complete" healthData >>= asBoolField
        tempoOk <- lookupField "ok" tempoResp >>= asBoolField
        paramOk <- lookupField "ok" paramResp >>= asBoolField
        synthModeOk <- lookupField "ok" synthModeResp >>= asBoolField
        synthGainOk <- lookupField "ok" synthGainResp >>= asBoolField
        synthNoteOk <- lookupField "ok" synthNoteResp >>= asBoolField
        loadOk <- lookupField "ok" loadResp >>= asBoolField
        unloadOk <- lookupField "ok" unloadResp >>= asBoolField
        pure
            ( healthOk
            , setupComplete
            , tempoOk
            , paramOk
            , synthModeOk
            , synthGainOk
            , synthNoteOk
            , loadOk
            , unloadOk
            )
    of
        Left err ->
            Fail err
        Right
            ( healthOk
            , setupComplete
            , tempoOk
            , paramOk
            , synthModeOk
            , synthGainOk
            , synthNoteOk
            , loadOk
            , unloadOk
            ) ->
            let tempoOkValue =
                    abs (realToFrac (OSCRouter.tuBpm tempo) - (132.5 :: Double)) < 1e-6
                paramOkValue = case drop 3 (OSCRouter.fuParams fx) of
                    (v:_) -> abs (realToFrac v - (0.65 :: Double)) < 1e-6
                    [] -> False
                synthOkValue =
                    OSCRouter.suMixMode synth == 2
                    && abs (realToFrac (OSCRouter.suGain synth) - (0.5 :: Double)) < 1e-6
                unloadCleared = case finalSlots of
                    (Nothing:_) -> True
                    _ -> False
            in if healthOk
                && setupComplete
                && tempoOk
                && paramOk
                && synthModeOk
                && synthGainOk
                && synthNoteOk
                && loadOk
                && unloadOk
                && tempoOkValue
                && paramOkValue
                && synthOkValue
                && unloadCleared
                then Pass
                else Fail "control socket state or responses did not match expectations"

testYinA4 :: IO TestResult
testYinA4 = do
    let buf = generateSine 440.0 48000.0 2048
        result = detectPitch defaultConfig buf
        freq = yinFrequency result
        err = abs (freq - 440.0) / 440.0
    assert (err < 0.01) $ "A4 detection: expected ~440Hz, got " ++ show freq

testYinE2 :: IO TestResult
testYinE2 = do
    let buf = generateSine 82.41 48000.0 2048
        result = detectPitch defaultConfig buf
        freq = yinFrequency result
        err = abs (freq - 82.41) / 82.41
    assert (err < 0.02) $ "E2 detection: expected ~82Hz, got " ++ show freq

testYinE6 :: IO TestResult
testYinE6 = do
    let buf = generateSine 1318.5 48000.0 2048
        result = detectPitch defaultConfig buf
        freq = yinFrequency result
        err = abs (freq - 1318.5) / 1318.5
    assert (err < 0.01) $ "E6 detection: expected ~1319Hz, got " ++ show freq

testYinAllStrings :: IO TestResult
testYinAllStrings = do
    let strings =
            [ (82.41, "E2")
            , (110.0, "A2")
            , (146.83, "D3")
            , (196.0, "G3")
            , (246.94, "B3")
            , (329.63, "E4")
            ]
        check (expected, name) =
            let buf = generateSine expected 48000.0 2048
                result = detectPitch defaultConfig buf
                freq = yinFrequency result
                err = abs (freq - expected) / expected
            in if err < 0.02
                then Nothing
                else Just $
                    name ++ ": expected " ++ show expected ++ " got " ++ show freq

    let failures = map check strings
        errs = [e | Just e <- failures]
    assert (null errs) $ "string detection failures: " ++ unwords errs

testYinHarmonic :: IO TestResult
testYinHarmonic = do
    let buf = generateHarmonic 440.0 48000.0 2048
        result = detectPitch defaultConfig buf
        freq = yinFrequency result
        err = abs (freq - 440.0) / 440.0
    assert (err < 0.01) $
        "harmonic A4 detection: expected ~440Hz, got " ++ show freq

testYinSilence :: IO TestResult
testYinSilence = do
    let buf = V.replicate 2048 0.0
        result = detectPitch defaultConfig buf
    assert
        (yinFrequency result == 0.0 && yinMidiNote result == (-1))
        "silence should return no detection"

testYinConfidence :: IO TestResult
testYinConfidence = do
    let buf = generateSine 440.0 48000.0 2048
        result = detectPitch defaultConfig buf
    assert
        (yinConfidence result > 0.85)
        ("A4 confidence should be >85%, got "
            ++ show (yinConfidence result * 100)
            ++ "%")

testYinMidiConversion :: IO TestResult
testYinMidiConversion = do
    let checks =
            [ (440.0, 69, "A4")
            , (261.63, 60, "C4")
            , (82.41, 40, "E2")
            , (1318.5, 88, "E6")
            ]
        errs =
            [ name ++ ": expected MIDI " ++ show expected
                ++ " got " ++ show (frequencyToMidi freq)
            | (freq, expected, name) <- checks
            , frequencyToMidi freq /= expected
            ]
    assert (null errs) $ unwords errs

testYinNoteName :: IO TestResult
testYinNoteName = do
    let checks = [(69, "A4"), (60, "C4"), (40, "E2"), (0, "C-1")]
        errs =
            [ "MIDI " ++ show midi ++ ": expected " ++ expected
                ++ " got " ++ midiToNoteName midi
            | (midi, expected) <- checks
            , midiToNoteName midi /= expected
            ]
    assert (null errs) $ unwords errs

main :: IO ()
main = do
    putStrLn "=== DeMoD Orchestrator + Ulation Tests ==="

    putStrLn "\n-- Core Runtime --"
    r1 <- sequence
        [ runTest "IPC create/destroy" testIpcCreateDestroy
        , runTest "triple buffer round-trip" testTripleBufferRoundTrip
        , runTest "Ulation skips framed evt-ring events" testUlationSkipsEventFrames
        , runTest "supervisor fails closed on child launch errors" testSupervisorFailsMissingBinaryLaunch
        , runTest "CLI parses product-boundary flags" testCliParsesProductBoundaryFlags
        , runTest "RT launch spec preserves explicit slots" testRtSpecUsesExplicitSlots
        , runTest "note tracker emits A4 on/off" testNoteTrackerSyntheticA4
        , runTest "control socket round-trip" testControlSocketRoundTrip
        ]

    putStrLn "\n-- YIN Pitch Detection --"
    r2 <- sequence
        [ runTest "A4 (440 Hz) pure sine" testYinA4
        , runTest "E2 (82 Hz) lowest guitar string" testYinE2
        , runTest "E6 (1319 Hz) highest guitar note" testYinE6
        , runTest "all 6 guitar strings" testYinAllStrings
        , runTest "harmonic signal (fund + 2nd + 3rd)" testYinHarmonic
        , runTest "silence -> no detection" testYinSilence
        , runTest "pure sine confidence > 85%" testYinConfidence
        , runTest "frequency -> MIDI conversion" testYinMidiConversion
        , runTest "MIDI -> note name" testYinNoteName
        ]

    let results = r1 ++ r2
        passed = length (filter id results)
        failed = length (filter not results)

    putStrLn $ "\n" ++ show passed ++ " passed, " ++ show failed ++ " failed"

    if failed > 0 then exitFailure else exitSuccess
