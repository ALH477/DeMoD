{- |
Module      : DeMoD.Orchestrator
Description : Haskell RT Audio Orchestrator
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

The orchestrator runs on non-isolated cores (0-1 with nosmt) as a
soft-real-time coordinator. It creates shared memory IPC, forks and
execs the C RT audio process with SCHED_FIFO + core pinning, monitors
child health, and publishes parameter updates to the triple buffer.

RTS invocation:
  taskset -c 0,1 ./demod-orchestrator +RTS -N2 -qg -qb -qm -I0 -A512k --nonmoving-gc -C0 -V0 -RTS
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

module DeMoD.Orchestrator
    ( -- * Entry point
      runOrchestrator
    , OrchestratorConfig(..)
    , defaultConfig
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Concurrent.Async (withAsync)
import Control.Monad (void, when)
import Data.IORef
import Data.Maybe (isJust)
import Data.Word
import System.IO (hSetBuffering, stdout, stderr, BufferMode(LineBuffering), hPutStrLn)
import System.Posix.Signals

import qualified DeMoD.IPC.FFI as FFI
import qualified DeMoD.Ulation.Engine as Ulation
import DeMoD.Ulation.YIN (YinResult(..), midiToNoteName)
import qualified DeMoD.Control as Control
import qualified DeMoD.Marketplace as Marketplace
import qualified DeMoD.Supervisor as Supervisor
import qualified DeMoD.OSCRouter as OSCRouter
import qualified DeMoD.ProcessTree as ProcessTree
import qualified DeMoD.Note.Tracker as NoteTracker
#ifdef DEMOD_BT_MIDI
import qualified DeMoD.BT.Bridge as BtBridge
#endif

-- ── Configuration ──────────────────────────────────────────────

data OrchestratorConfig = OrchestratorConfig
    { cfgRtBinary       :: !FilePath       -- ^ Path to demod-rt binary
    , cfgRtCore         :: !Int            -- ^ Core to pin RT process (default: 4)
    , cfgRtPriority     :: !Int            -- ^ SCHED_FIFO priority (default: 80)
    , cfgFaustLibs      :: ![FilePath]     -- ^ Faust .so plugins to load
    , cfgHeartbeatMs    :: !Int            -- ^ Heartbeat timeout in ms (default: 500)
    , cfgRestartDelayMs :: !Int            -- ^ Base restart delay in ms (default: 100)
    , cfgMaxRestartMs   :: !Int            -- ^ Max backoff cap in ms (default: 30000)
    , cfgSpscCapacity   :: !Word64         -- ^ SPSC ring capacity (default: 4096)
    , cfgShutdownTimeMs :: !Int            -- ^ SIGTERM → SIGKILL timeout (default: 5000)
    , cfgControlSocket  :: !(Maybe FilePath) -- ^ UDS path for external clients; Nothing disables
    , cfgDataDir        :: !FilePath       -- ^ Persistent DeMoD data root
    , cfgSetupMarker    :: !(Maybe FilePath) -- ^ Optional first-boot completion marker path
    , cfgBtMidiEnable   :: !Bool           -- ^ Publish OSCRouter state as BLE-MIDI via libdemod_bt
    , cfgBtMidiName     :: !String         -- ^ BLE-MIDI advertised local name
    , cfgSynthEnable    :: !Bool           -- ^ Drive Faust instruments from detected pitch
    , cfgMarketplace    :: !Marketplace.MarketplaceConfig
    } deriving (Show)

defaultConfig :: OrchestratorConfig
defaultConfig = OrchestratorConfig
    { cfgRtBinary       = "demod-rt"
    , cfgRtCore         = 4
    , cfgRtPriority     = 80
    , cfgFaustLibs      = []
    , cfgHeartbeatMs    = 500
    , cfgRestartDelayMs = 100
    , cfgMaxRestartMs   = 30_000
    , cfgSpscCapacity   = 4096
    , cfgShutdownTimeMs = 5000
    , cfgControlSocket  = Nothing
    , cfgDataDir        = "/var/lib/demod"
    , cfgSetupMarker    = Nothing
    , cfgBtMidiEnable   = False
    , cfgBtMidiName     = "DeMoD Guitar"
    , cfgSynthEnable    = False
    , cfgMarketplace    = Marketplace.defaultMarketplaceConfig
    }

-- ── Logging ────────────────────────────────────────────────────

logInfo :: String -> IO ()
logInfo msg = hPutStrLn stderr $ "[orchestrator] " ++ msg

logError :: String -> IO ()
logError msg = hPutStrLn stderr $ "[orchestrator] ERROR: " ++ msg

-- ── Status Reporter ───────────────────────────────────────────

{- |
Periodically log RT process health from the heartbeat region.
Runs as a green thread alongside the supervisor.
-}
statusReporter :: FFI.IpcHandle -> TVar Bool -> Ulation.UlationState -> IO ()
statusReporter ipc running ulState = loop
  where
    loop = do
        alive <- readTVarIO running
        when alive $ do
            threadDelay 5_000_000  -- every 5s

            rtAlive <- FFI.heartbeatAlive ipc
            when (rtAlive == 1) $ do
                cbCount <- FFI.heartbeatCallbackCount ipc
                xruns   <- FFI.heartbeatXrunCount ipc
                cpuLoad <- FFI.heartbeatCpuLoad ipc
                let loadPct = realToFrac cpuLoad * 100.0 :: Double
                logInfo $ "RT status: callbacks=" ++ show cbCount
                       ++ " xruns=" ++ show xruns
                       ++ " cpu=" ++ show (round loadPct :: Int) ++ "%"

            -- Ulation Engine stats
            detections <- readIORef (Ulation.usDetections ulState)
            lastPitch  <- readTVarIO (Ulation.usLastResult ulState)
            pongs      <- readIORef (Ulation.usEvtPongs ulState)
            evtXruns   <- readIORef (Ulation.usEvtXruns ulState)
            fxLoaded   <- readIORef (Ulation.usEvtFxLoaded ulState)
            fxErrors   <- readIORef (Ulation.usEvtFxErrors ulState)
            evtUnknown <- readIORef (Ulation.usEvtUnknown ulState)
            when (detections > 0) $ do
                let freq = yinFrequency lastPitch
                    conf = yinConfidence lastPitch
                    note = yinMidiNote lastPitch
                if freq > 0
                    then logInfo $ "pitch: " ++ show (round freq :: Int) ++ "Hz "
                               ++ midiToNoteName note
                               ++ " (conf=" ++ show (round (conf * 100) :: Int) ++ "%)"
                               ++ " detections=" ++ show detections
                    else logInfo $ "pitch: none (detections=" ++ show detections ++ ")"

            when (pongs + evtXruns + fxLoaded + fxErrors + evtUnknown > 0) $
                logInfo $ "evt ring: pong=" ++ show pongs
                       ++ " xrun=" ++ show evtXruns
                       ++ " fx_loaded=" ++ show fxLoaded
                       ++ " fx_error=" ++ show fxErrors
                       ++ " unknown=" ++ show evtUnknown

            loop

-- ── Entry Point ───────────────────────────────────────────────

runOrchestrator :: OrchestratorConfig -> IO ()
runOrchestrator cfg = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    logInfo "DeMoD Orchestrator starting"
    let initialSlots = ProcessTree.normalizeFaustSlots (cfgFaustLibs cfg)
    logInfo $ "config: rt=" ++ cfgRtBinary cfg
           ++ " core=" ++ show (cfgRtCore cfg)
           ++ " prio=" ++ show (cfgRtPriority cfg)
           ++ " faust=" ++ show (length (filter isJust initialSlots)) ++ " plugins"

    -- Shutdown coordination
    running <- newTVarIO True
    let shutdown = do
            logInfo "shutdown requested"
            atomically (writeTVar running False)
    _ <- installHandler sigTERM (Catch shutdown) Nothing
    _ <- installHandler sigINT  (Catch shutdown) Nothing

    -- Create IPC regions
    mIpc <- FFI.ipcCreate (cfgSpscCapacity cfg)
    case mIpc of
        Nothing -> do
            logError "failed to create IPC regions — aborting"
            pure ()
        Just ipc -> do
            logInfo "IPC regions created"

            -- Initialize subsystems
            let ulCfg = Ulation.defaultUlationConfig
            ulState <- Ulation.mkUlationState ulCfg
            logInfo "Ulation Engine initialized"

            routerState <- OSCRouter.newRouterState
            logInfo "OSC Router initialized"

            noteTracker <-
                if cfgSynthEnable cfg
                    then do
                        tracker <- NoteTracker.newNoteTracker
                            NoteTracker.defaultNoteTrackerConfig
                            ipc
                        logInfo "Synth note tracker initialized"
                        pure (Just tracker)
                    else pure Nothing

            sv <- Supervisor.newSupervisor running
            logInfo "Supervisor initialized"

            rtSlots <- newTVarIO initialSlots
            let heartbeatCfg = Just (ipc, fromIntegral (cfgHeartbeatMs cfg) * 1000)
                mkRtSpec slots = ProcessTree.mkRtAudioSpec
                    (cfgRtBinary cfg)
                    (cfgRtCore cfg)
                    (cfgRtPriority cfg)
                    slots
                applyRtSlots slots = do
                    ok <- Supervisor.reconfigureChildWithHeartbeat
                        sv
                        "demod-rt"
                        (mkRtSpec slots)
                        heartbeatCfg
                    if ok
                        then atomically (writeTVar rtSlots slots) >> pure (Right ())
                        else pure (Left "demod-rt is not currently running")

            -- Spawn the RT audio child via supervisor
            Supervisor.spawnChildWithHeartbeat sv (mkRtSpec initialSlots)
                heartbeatCfg
            logInfo "RT audio child spec registered"

            -- Run all subsystems concurrently:
            --   1. Ulation Engine: audio tap → YIN → router pitch TVar
            --   2. OSC Router: aggregates all TVars → triple buffer
            --   3. Status reporter: periodic health + pitch logging
            --   4. Supervisor: manages all child processes
            let routerCfg = OSCRouter.defaultRouterConfig
                routePitchResult result = do
                    atomically $
                        writeTVar (OSCRouter.rsPitch routerState) $
                            OSCRouter.PitchUpdate
                                { OSCRouter.puFrequency  = realToFrac (yinFrequency result)
                                , OSCRouter.puConfidence = realToFrac (yinConfidence result)
                                , OSCRouter.puMidiNote   = yinMidiNote result
                                }
                    case noteTracker of
                        Nothing -> pure ()
                        Just tracker -> void $ NoteTracker.handleYinResult tracker result
                ctlCfg = case cfgControlSocket cfg of
                    Nothing -> Nothing
                    Just socketPath ->
                        Just Control.defaultControlConfig
                            { Control.ccSocketPath = socketPath
                            , Control.ccSetupMarker = cfgSetupMarker cfg
                            }
                withControl action = case ctlCfg of
                    Nothing -> action
                    Just controlCfg ->
                        withAsync
                            (Control.runControlServer
                                controlCfg
                                ipc
                                routerState
                                sv
                                rtSlots
                                applyRtSlots
                                running
                            )
                            (\_ -> action)

#ifdef DEMOD_BT_MIDI
                btBridgeCfg = BtBridge.defaultBridgeConfig
                    { BtBridge.bcDeviceName = cfgBtMidiName cfg }
                withBtBridge action
                    | cfgBtMidiEnable cfg =
                        withAsync (BtBridge.runBridge btBridgeCfg routerState running)
                                  (\_ -> action)
                    | otherwise = action
#else
                withBtBridge action = do
                    when (cfgBtMidiEnable cfg) $
                        logInfo "--bt-midi requested but built without bt-midi flag; ignoring"
                    action
#endif

                withMarketplace action
                    | Marketplace.mcEnabled (cfgMarketplace cfg) =
                        withAsync
                            (Marketplace.runMarketplace (cfgMarketplace cfg) running)
                            (\_ -> action)
                    | otherwise = action

            withAsync (Ulation.runUlationEngine ulCfg ipc running ulState routePitchResult) $ \_ ->
              withAsync (OSCRouter.runRouter routerCfg ipc running routerState) $ \_ ->
                withAsync (statusReporter ipc running ulState) $ \_ ->
                  withBtBridge $
                    withMarketplace $
                      withControl $
                        Supervisor.runSupervisor sv

            -- Cleanup
            logInfo "shutting down children"
            Supervisor.shutdownAll sv

            logInfo "destroying IPC regions"
            FFI.ipcDestroy ipc
            logInfo "shutdown complete"
