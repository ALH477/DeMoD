{- |
Module      : DeMoD.Control
Description : Unix-domain control socket for local product/runtime integration
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The control socket exposes a narrow JSON-lines API for local product shells,
operator tooling, and the companion Marketplace stack. Requests are translated
onto the existing single-writer control paths so external clients never touch
shared memory directly.
-}

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DeMoD.Control
    ( ControlConfig(..)
    , defaultControlConfig
    , runControlServer
    ) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, catch, finally)
import Control.Monad (unless, when)
import Data.Aeson ((.=), Value(..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Bits (clearBit, setBit, testBit)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Scientific as Sci
import qualified Data.Text as T
import Data.Word (Word64)
import Foreign.C.Types (CFloat(..))
import Foreign.Marshal.Array (withArray)
import Network.Socket
    ( Family(AF_UNIX)
    , SockAddr(SockAddrUnix)
    , Socket
    , SocketType(Stream)
    , accept
    , bind
    , close
    , defaultProtocol
    , listen
    , socket
    )
import qualified Network.Socket as NS
import System.Directory
    ( canonicalizePath
    , createDirectoryIfMissing
    , doesFileExist
    , doesPathExist
    , removeFile
    )
import System.FilePath (takeDirectory)
import System.IO
    ( BufferMode(LineBuffering)
    , Handle
    , IOMode(ReadWriteMode)
    , hClose
    , hFlush
    , hGetLine
    , hIsEOF
    , hPutStrLn
    , hSetBuffering
    , stderr
    )
import System.Posix.Files (setFileMode)
import System.Posix.Types (FileMode)

import qualified DeMoD.IPC.FFI as FFI
import qualified DeMoD.OSCRouter as OSCRouter
import qualified DeMoD.Supervisor as Supervisor

data ControlConfig = ControlConfig
    { ccSocketPath  :: !FilePath
    , ccSocketMode  :: !FileMode
    , ccVersion     :: !Int
    , ccSetupMarker :: !(Maybe FilePath)
    }

defaultControlConfig :: ControlConfig
defaultControlConfig = ControlConfig
    { ccSocketPath = "/run/demod/control.sock"
    , ccSocketMode = 0o660
    , ccVersion = 1
    , ccSetupMarker = Nothing
    }

data ControlContext = ControlContext
    { ctlIpc        :: !FFI.IpcHandle
    , ctlRouter     :: !OSCRouter.RouterState
    , ctlSupervisor :: !Supervisor.SupervisorState
    , ctlRtSlots    :: !(TVar [Maybe FilePath])
    , ctlApplyRtSlots :: !([Maybe FilePath] -> IO (Either String ()))
    }

logInfo, logWarn :: String -> IO ()
logInfo msg = hPutStrLn stderr $ "[control] " ++ msg
logWarn msg = hPutStrLn stderr $ "[control] WARN: " ++ msg

cmdFxBypass, cmdFxParam :: Float
cmdFxBypass = 3.0
cmdFxParam = 4.0

cmdSetBpm, cmdSetGain, cmdPing :: Float
cmdSetBpm = 10.0
cmdSetGain = 11.0
cmdPing = 90.0

cmdNoteOn, cmdNoteOff, cmdAllNotesOff, cmdSetMixMode :: Float
cmdNoteOn = 20.0
cmdNoteOff = 21.0
cmdAllNotesOff = 22.0
cmdSetMixMode = 23.0

-- per-slot mixer (channel strip) — see ipc/include/demod_commands.h
cmdSlotGain, cmdSlotPan, cmdSlotMute, cmdSlotSolo :: Float
cmdSlotGain = 12.0
cmdSlotPan = 13.0
cmdSlotMute = 14.0
cmdSlotSolo = 15.0

pushCmd :: FFI.IpcHandle -> [Float] -> IO Bool
pushCmd ipc xs = withArray (map CFloat xs) $ \ptr -> do
    let count = fromIntegral (length xs)
    written <- FFI.cmdPush ipc ptr count
    pure (written == count)

lookupKey :: T.Text -> KM.KeyMap Value -> Maybe Value
lookupKey key = KM.lookup (K.fromText key)

lookupArg :: T.Text -> KM.KeyMap Value -> Maybe Value
lookupArg key obj =
    lookupKey key obj <|> (lookupKey "args" obj >>= fromObject >>= lookupKey key)
  where
    fromObject (Object args) = Just args
    fromObject _ = Nothing

asNumber :: Value -> Maybe Double
asNumber (Number n) = Just (Sci.toRealFloat n)
asNumber _ = Nothing

asInt :: Value -> Maybe Int
asInt = fmap round . asNumber

asBool :: Value -> Maybe Bool
asBool (Bool b) = Just b
asBool _ = Nothing

asString :: Value -> Maybe String
asString (String t) = Just (T.unpack t)
asString _ = Nothing

asText :: Value -> Maybe T.Text
asText (String t) = Just t
asText _ = Nothing

okResp :: Int -> T.Text -> Value -> Value
okResp version reqId body = A.object
    [ "v" .= version
    , "id" .= reqId
    , "ok" .= True
    , "data" .= body
    ]

errResp :: Int -> T.Text -> String -> Value
errResp version reqId msg = A.object
    [ "v" .= version
    , "id" .= reqId
    , "ok" .= False
    , "err" .= msg
    ]

childStatusText :: Supervisor.ChildStatus -> String
childStatusText = \case
    Supervisor.Starting -> "starting"
    Supervisor.Running _ -> "running"
    Supervisor.Stopped -> "stopped"
    Supervisor.Failed _ -> "failed"
    Supervisor.Restarting _ -> "restarting"

childStatusJson :: (String, Supervisor.ChildStatus, Int, Word64) -> Value
childStatusJson (name, status, restarts, uptimeUs) = A.object
    [ "name" .= name
    , "status" .= childStatusText status
    , "restarts" .= restarts
    , "uptime_us" .= uptimeUs
    ]

updateFxBypass :: Int -> Bool -> OSCRouter.FxUpdate -> OSCRouter.FxUpdate
updateFxBypass slot on fx =
    fx { OSCRouter.fuBypassMask = mask' }
  where
    mask = OSCRouter.fuBypassMask fx
    mask' = if on then setBit mask slot else clearBit mask slot

updateFxParam :: Int -> Float -> OSCRouter.FxUpdate -> OSCRouter.FxUpdate
updateFxParam idx value fx =
    fx { OSCRouter.fuParams = go idx (OSCRouter.fuParams fx) }
  where
    go 0 (_:rest) = value : rest
    go n (x:rest) = x : go (n - 1) rest
    go _ [] = []

updateSynthMode :: Word64 -> OSCRouter.SynthUpdate -> OSCRouter.SynthUpdate
updateSynthMode mode synth =
    synth { OSCRouter.suMixMode = fromIntegral mode }

updateSynthGain :: Float -> OSCRouter.SynthUpdate -> OSCRouter.SynthUpdate
updateSynthGain value synth =
    synth { OSCRouter.suGain = value }

parseMixMode :: String -> Maybe Word64
parseMixMode mode = case mode of
    "sum" -> Just 0
    "dry" -> Just 1
    "synth-only" -> Just 2
    "synth" -> Just 2
    _ -> Nothing

instrumentSpec :: FilePath -> FilePath
instrumentSpec path
    | "instrument:" `isPrefixOf` path = path
    | otherwise = "instrument:" ++ path

dispatch :: ControlConfig -> ControlContext -> Value -> IO Value
dispatch cfg ctx (Object obj) =
    let reqId = fromMaybe "" (lookupKey "id" obj >>= asText)
        version = ccVersion cfg
        okData = okResp version reqId
        err = pure . errResp version reqId
        ringFull = err "cmd ring full"
        invalidRange :: String -> Int -> Int -> IO Value
        invalidRange label lo hi = err $
            label ++ " out of range (" ++ show lo ++ "-" ++ show hi ++ ")"
    in case (lookupKey "op" obj <|> lookupKey "verb" obj) >>= asString of
        Nothing -> err "missing op"
        Just op -> case op of
            "ping" -> do
                ok <- pushCmd (ctlIpc ctx) [cmdPing]
                if ok
                    then pure $ okData (A.object ["pong" .= True, "queued" .= True])
                    else ringFull

            "get_health" -> do
                alive <- FFI.heartbeatAlive (ctlIpc ctx)
                callbacks <- FFI.heartbeatCallbackCount (ctlIpc ctx)
                xruns <- FFI.heartbeatXrunCount (ctlIpc ctx)
                cpuLoad <- FFI.heartbeatCpuLoad (ctlIpc ctx)
                hbUs <- FFI.heartbeatTimestamp (ctlIpc ctx)
                nowUs <- FFI.clockUs
                children <- Supervisor.allChildStates (ctlSupervisor ctx)
                setupComplete <- case ccSetupMarker cfg of
                    Nothing -> pure Nothing
                    Just marker -> Just <$> doesPathExist marker
                pure $ okData $ A.object $
                    [ "alive" .= (alive == 1)
                    , "callbacks" .= callbacks
                    , "xruns" .= xruns
                    , "cpu_load" .= (realToFrac cpuLoad :: Double)
                    , "hb_us" .= hbUs
                    , "now_us" .= nowUs
                    , "children" .= map childStatusJson children
                    ] ++ maybe [] (\ready -> ["setup_complete" .= ready]) setupComplete

            "list_slots" -> do
                fx <- readTVarIO (OSCRouter.rsFx (ctlRouter ctx))
                rtSlots <- readTVarIO (ctlRtSlots ctx)
                let params = take 16 (OSCRouter.fuParams fx ++ repeat 0)
                    loadedSlots = take 16 (rtSlots ++ repeat Nothing)
                    slots =
                        [ A.object
                            [ "slot" .= idx
                            , "loaded" .= maybe False (const True) libPath
                            , "path" .= libPath
                            , "bypassed" .= testBit (OSCRouter.fuBypassMask fx) idx
                            , "value" .= value
                            ]
                        | ((idx, value), libPath) <- zip (zip [0 :: Int .. 15] params) loadedSlots
                        ]
                pure $ okData $ A.object
                    [ "count" .= (16 :: Int)
                    , "bypass_mask" .= OSCRouter.fuBypassMask fx
                    , "slots" .= slots
                    ]

            "load_fx" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "path" obj >>= asString
                ) of
                (Just slot, Just path)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        exists <- doesFileExist path
                        if not exists
                            then err ("load_fx path does not exist: " ++ path)
                            else do
                                realPath <- canonicalizePath path
                                current <- readTVarIO (ctlRtSlots ctx)
                                let nextSlots = take 16 $
                                        replaceAt slot (Just realPath) (current ++ repeat Nothing)
                                ctlApplyRtSlots ctx nextSlots >>= \case
                                    Left applyErr -> err applyErr
                                    Right () -> pure $ okData $ A.object
                                        [ "slot" .= slot
                                        , "path" .= realPath
                                        , "restart_rt" .= True
                                        ]
                _ -> err "load_fx requires slot(int) and path(string)"

            "unload_fx" -> case lookupKey "slot" obj >>= asInt of
                Just slot
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        current <- readTVarIO (ctlRtSlots ctx)
                        let nextSlots = take 16 $
                                replaceAt slot Nothing (current ++ repeat Nothing)
                        ctlApplyRtSlots ctx nextSlots >>= \case
                            Left applyErr -> err applyErr
                            Right () -> pure $ okData $ A.object
                                [ "slot" .= slot
                                , "restart_rt" .= True
                                ]
                Nothing -> err "unload_fx requires slot(int)"

            "bypass_fx" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "on" obj >>= asBool
                ) of
                (Just slot, Just on)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        atomically $ modifyTVar' (OSCRouter.rsFx (ctlRouter ctx)) (updateFxBypass slot on)
                        ok <- pushCmd (ctlIpc ctx)
                            [ cmdFxBypass
                            , fromIntegral slot
                            , if on then 1 else 0
                            ]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "on" .= on]
                            else ringFull
                _ -> err "bypass_fx requires slot(int) and on(bool)"

            "set_param" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "idx" obj >>= asInt
                , lookupKey "value" obj >>= asNumber
                ) of
                (Just slot, Just idx, Just value)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | idx < 0 || idx >= 16 -> invalidRange "idx" 0 15
                    | otherwise -> do
                        atomically $
                            modifyTVar' (OSCRouter.rsFx (ctlRouter ctx))
                                (updateFxParam idx (realToFrac value))
                        ok <- pushCmd (ctlIpc ctx)
                            [ cmdFxParam
                            , fromIntegral slot
                            , fromIntegral idx
                            , realToFrac value
                            ]
                        if ok
                            then pure $ okData $ A.object
                                [ "slot" .= slot
                                , "idx" .= idx
                                , "value" .= value
                                ]
                            else ringFull
                _ -> err "set_param requires slot(int), idx(int), value(number)"

            "set_bpm" -> case lookupKey "bpm" obj >>= asNumber of
                Just bpm
                    | bpm <= 0 -> err "set_bpm requires bpm(number > 0)"
                    | otherwise -> do
                        atomically $ modifyTVar' (OSCRouter.rsTempo (ctlRouter ctx)) $
                            \tempo -> tempo { OSCRouter.tuBpm = realToFrac bpm }
                        ok <- pushCmd (ctlIpc ctx) [cmdSetBpm, realToFrac bpm]
                        if ok
                            then pure $ okData $ A.object ["bpm" .= bpm]
                            else ringFull
                Nothing -> err "set_bpm requires bpm(number)"

            "set_gain" -> case lookupKey "gain" obj >>= asNumber of
                Just gain
                    | gain < 0 -> err "set_gain requires gain(number >= 0)"
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdSetGain, realToFrac gain]
                        if ok
                            then pure $ okData $ A.object ["gain" .= gain]
                            else ringFull
                Nothing -> err "set_gain requires gain(number)"

            "synth.load" -> case
                ( lookupArg "slot" obj >>= asInt
                , lookupArg "path" obj >>= asString
                ) of
                (Just slot, Just path)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        exists <- doesFileExist path
                        if not exists
                            then err ("synth.load path does not exist: " ++ path)
                            else do
                                realPath <- canonicalizePath path
                                current <- readTVarIO (ctlRtSlots ctx)
                                let nextSlots = take 16 $
                                        replaceAt slot (Just (instrumentSpec realPath))
                                            (current ++ repeat Nothing)
                                ctlApplyRtSlots ctx nextSlots >>= \case
                                    Left applyErr -> err applyErr
                                    Right () -> pure $ okData $ A.object
                                        [ "slot" .= slot
                                        , "path" .= realPath
                                        , "restart_rt" .= True
                                        ]
                _ -> err "synth.load requires slot(int) and path(string)"

            "synth.unload" -> case lookupArg "slot" obj >>= asInt of
                Just slot
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        current <- readTVarIO (ctlRtSlots ctx)
                        let nextSlots = take 16 $
                                replaceAt slot Nothing (current ++ repeat Nothing)
                        ctlApplyRtSlots ctx nextSlots >>= \case
                            Left applyErr -> err applyErr
                            Right () -> pure $ okData $ A.object
                                [ "slot" .= slot
                                , "restart_rt" .= True
                                ]
                Nothing -> err "synth.unload requires slot(int)"

            "synth.mode" -> case lookupArg "mode" obj >>= asString >>= parseMixMode of
                Just mode -> do
                    atomically $
                        modifyTVar' (OSCRouter.rsSynth (ctlRouter ctx))
                            (updateSynthMode mode)
                    ok <- pushCmd (ctlIpc ctx) [cmdSetMixMode, fromIntegral mode]
                    if ok
                        then pure $ okData $ A.object ["mode" .= mode]
                        else ringFull
                Nothing -> err "synth.mode requires mode(sum|dry|synth-only)"

            "synth.gain" -> case lookupArg "value" obj >>= asNumber of
                Just gain
                    | gain < 0 || gain > 1 -> err "synth.gain requires value(number 0..1)"
                    | otherwise -> do
                        atomically $
                            modifyTVar' (OSCRouter.rsSynth (ctlRouter ctx))
                                (updateSynthGain (realToFrac gain))
                        pure $ okData $ A.object ["value" .= gain]
                Nothing -> err "synth.gain requires value(number 0..1)"

            "synth.note_on" -> case
                ( lookupArg "slot" obj >>= asInt
                , lookupArg "note" obj >>= asInt
                , lookupArg "velocity" obj >>= asInt
                ) of
                (Just slot, Just note, Just velocity)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | note < 0 || note > 127 -> invalidRange "note" 0 127
                    | velocity < 1 || velocity > 127 -> invalidRange "velocity" 1 127
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx)
                            [ cmdNoteOn
                            , fromIntegral slot
                            , fromIntegral note
                            , fromIntegral velocity
                            ]
                        if ok
                            then pure $ okData $ A.object
                                [ "slot" .= slot
                                , "note" .= note
                                , "velocity" .= velocity
                                ]
                            else ringFull
                _ -> err "synth.note_on requires slot(int), note(int), velocity(int)"

            "synth.note_off" -> case
                ( lookupArg "slot" obj >>= asInt
                , lookupArg "note" obj >>= asInt
                ) of
                (Just slot, Just note)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | note < 0 || note > 127 -> invalidRange "note" 0 127
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx)
                            [ cmdNoteOff
                            , fromIntegral slot
                            , fromIntegral note
                            ]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "note" .= note]
                            else ringFull
                _ -> err "synth.note_off requires slot(int), note(int)"

            "synth.all_notes_off" -> case lookupArg "slot" obj >>= asInt of
                Just slot
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdAllNotesOff, fromIntegral slot]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot]
                            else ringFull
                Nothing -> err "synth.all_notes_off requires slot(int)"

            -- per-slot mixer (channel strip): forward to demod-rt; no param-bus mirror
            -- (the UI keeps its own shadow of gain/pan/mute/solo for readback).
            "set_slot_gain" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "gain" obj >>= asNumber
                ) of
                (Just slot, Just gain)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdSlotGain, fromIntegral slot, realToFrac gain]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "gain" .= gain]
                            else ringFull
                _ -> err "set_slot_gain requires slot(int) and gain(number)"

            "set_slot_pan" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "pan" obj >>= asNumber
                ) of
                (Just slot, Just pan)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdSlotPan, fromIntegral slot, realToFrac pan]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "pan" .= pan]
                            else ringFull
                _ -> err "set_slot_pan requires slot(int) and pan(number)"

            "set_slot_mute" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "on" obj >>= asBool
                ) of
                (Just slot, Just on)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdSlotMute, fromIntegral slot, if on then 1 else 0]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "on" .= on]
                            else ringFull
                _ -> err "set_slot_mute requires slot(int) and on(bool)"

            "set_slot_solo" -> case
                ( lookupKey "slot" obj >>= asInt
                , lookupKey "on" obj >>= asBool
                ) of
                (Just slot, Just on)
                    | slot < 0 || slot >= 16 -> invalidRange "slot" 0 15
                    | otherwise -> do
                        ok <- pushCmd (ctlIpc ctx) [cmdSlotSolo, fromIntegral slot, if on then 1 else 0]
                        if ok
                            then pure $ okData $ A.object ["slot" .= slot, "on" .= on]
                            else ringFull
                _ -> err "set_slot_solo requires slot(int) and on(bool)"

            other -> err $ "unknown op: " ++ other
dispatch cfg _ _ = pure (errResp (ccVersion cfg) "" "request must be a JSON object")

replaceAt :: Int -> a -> [a] -> [a]
replaceAt idx value = go idx
  where
    go 0 (_:rest) = value : rest
    go n (x:rest) = x : go (n - 1) rest
    go _ [] = []

handleConn :: ControlConfig -> ControlContext -> Socket -> IO ()
handleConn cfg ctx sock = do
    handle <- NS.socketToHandle sock ReadWriteMode
    hSetBuffering handle LineBuffering
    (serveLoop handle `finally` hClose handle)
        `catch` \(e :: SomeException) -> logWarn ("client error: " ++ show e)
  where
    serveLoop :: Handle -> IO ()
    serveLoop handle = do
        eof <- hIsEOF handle
        unless eof $ do
            line <- hGetLine handle
            response <- case A.eitherDecode (BSL.pack line) of
                Left parseErr -> pure $
                    errResp (ccVersion cfg) "" ("parse: " ++ parseErr)
                Right value -> dispatch cfg ctx value
            hPutStrLn handle (BSL.unpack (A.encode response))
            hFlush handle
            serveLoop handle

mkListener :: ControlConfig -> IO Socket
mkListener cfg = do
    let path = ccSocketPath cfg
    createDirectoryIfMissing True (takeDirectory path)
    stale <- doesPathExist path
    when stale (removeFile path)
    sock <- socket AF_UNIX Stream defaultProtocol
    bind sock (SockAddrUnix path)
    setFileMode path (ccSocketMode cfg)
    listen sock 8
    logInfo $ "listening on " ++ path
    pure sock

runControlServer
    :: ControlConfig
    -> FFI.IpcHandle
    -> OSCRouter.RouterState
    -> Supervisor.SupervisorState
    -> TVar [Maybe FilePath]
    -> ([Maybe FilePath] -> IO (Either String ()))
    -> TVar Bool
    -> IO ()
runControlServer cfg ipc router supervisor rtSlots applyRtSlots running =
    bracket (mkListener cfg) shutdown acceptLoop
  where
    ctx = ControlContext ipc router supervisor rtSlots applyRtSlots

    shutdown sock = do
        close sock
        stillThere <- doesPathExist (ccSocketPath cfg)
        when stillThere (removeFile (ccSocketPath cfg))
        logInfo "socket closed"

    acceptLoop sock = do
        alive <- readTVarIO running
        when alive $ do
            (client, _) <- accept sock
            _ <- forkIO (handleConn cfg ctx client)
            acceptLoop sock
