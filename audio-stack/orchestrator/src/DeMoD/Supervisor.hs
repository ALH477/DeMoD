{- |
Module      : DeMoD.Supervisor
Description : Multi-process supervisor with health tracking
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Manages the DeMoD process tree:

  Orchestrator (Haskell, cores 0-1)
  ├── demod-rt        (C, core 4, SCHED_FIFO 80) — RT audio
  ├── demod-ui        (C/Lua, core 5) — framebuffer GUI
  ├── demod-lyrics    (C, supervised) — lyrics display (TCP 7709)
  └── demod-hydramesh (C, cores 6-7) — P2P mesh networking

Each child gets:
  - Independent restart with exponential backoff
  - Heartbeat monitoring (where applicable)
  - Pre-exec RT setup (CPU affinity, scheduling policy)
  - Clean shutdown: SIGTERM → timeout → SIGKILL → reap
-}

{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module DeMoD.Supervisor
    ( -- * Types
      ChildSpec(..)
    , ChildState(..)
    , ChildStatus(..)
    , SupervisorState

      -- * Lifecycle
    , newSupervisor
    , spawnChild
    , spawnChildWithHeartbeat
    , reconfigureChildWithHeartbeat
    , runSupervisor
    , shutdownAll

      -- * Query
    , getChildStatus
    , allChildStates
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Concurrent.Async (async, cancel, race, Async)
import Control.Exception (try, SomeException, IOException)
import Control.Monad (when, unless, forM_, forM)
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word
import System.Exit (ExitCode(ExitSuccess), ExitCode(ExitFailure))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Process
    ( forkProcess
    , executeFile
    , getProcessStatus
    , exitImmediately
    , ProcessStatus(Exited)
    )
import System.Posix.Signals (signalProcess, sigTERM, sigKILL)
import System.Posix.Types (ProcessID)

import qualified DeMoD.IPC.FFI as FFI

-- ── Child Specification ────────────────────────────────────────

data ChildSpec = ChildSpec
    { csName          :: !String       -- ^ Human-readable name
    , csBinary        :: !FilePath     -- ^ Executable path
    , csArgs          :: ![String]     -- ^ Command-line arguments
    , csCpuCore       :: !(Maybe Int)  -- ^ Pin to core (Nothing = no pin)
    , csSchedFifo     :: !(Maybe Int)  -- ^ SCHED_FIFO priority (Nothing = normal)
    , csMlockAll      :: !Bool         -- ^ mlockall before exec
    , csRestartBaseMs :: !Int          -- ^ Base restart delay (default: 200)
    , csRestartMaxMs  :: !Int          -- ^ Max backoff cap (default: 30000)
    , csShutdownMs    :: !Int          -- ^ SIGTERM → SIGKILL timeout (default: 5000)
    , csMaxRestarts   :: !Int          -- ^ Max restarts before giving up (-1 = infinite)
    } deriving (Show)

-- ── Child State ────────────────────────────────────────────────

data ChildStatus
    = Starting
    | Running ProcessID
    | Stopped
    | Failed String
    | Restarting Int     -- ^ Restart count
    deriving (Show)

data ChildState = ChildState
    { childSpec       :: !(TVar ChildSpec)
    , childStatus     :: !(TVar ChildStatus)
    , childRestarts   :: !(IORef Int)
    , childLastStart  :: !(IORef Word64)
    , childTotalUp    :: !(IORef Word64)   -- ^ Total uptime in microseconds
    , childHeartbeat  :: !(TVar (Maybe (FFI.IpcHandle, Word64)))  -- ^ Handle + timeout (μs)
    }

-- ── Supervisor ─────────────────────────────────────────────────

data SupervisorState = SupervisorState
    { svChildren :: !(TVar (Map String ChildState))
    , svRunning  :: !(TVar Bool)
    , svWorkers  :: !(IORef [Async ()])
    }

newSupervisor :: TVar Bool -> IO SupervisorState
newSupervisor running = do
    children <- newTVarIO Map.empty
    workers  <- newIORef []
    pure $ SupervisorState children running workers

-- ── Spawn ──────────────────────────────────────────────────────

spawnChild :: SupervisorState -> ChildSpec -> IO ()
spawnChild sv spec = spawnChildWithHeartbeat sv spec Nothing

spawnChildWithHeartbeat :: SupervisorState
                       -> ChildSpec
                       -> Maybe (FFI.IpcHandle, Word64)
                       -> IO ()
spawnChildWithHeartbeat sv spec hb = do
    specVar <- newTVarIO spec
    status   <- newTVarIO Starting
    restarts <- newIORef 0
    lastStart <- newIORef 0
    totalUp  <- newIORef 0
    heartbeatVar <- newTVarIO hb

    let cs = ChildState specVar status restarts lastStart totalUp heartbeatVar

    atomically $ modifyTVar' (svChildren sv) (Map.insert (csName spec) cs)

    worker <- async $ childLoop sv cs
    modifyIORef' (svWorkers sv) (worker :)

reconfigureChildWithHeartbeat
    :: SupervisorState
    -> String
    -> ChildSpec
    -> Maybe (FFI.IpcHandle, Word64)
    -> IO Bool
reconfigureChildWithHeartbeat sv name spec hb = do
    children <- readTVarIO (svChildren sv)
    case Map.lookup name children of
        Nothing -> pure False
        Just cs -> do
            oldSpec <- readTVarIO (childSpec cs)
            atomically $ do
                writeTVar (childSpec cs) spec
                writeTVar (childHeartbeat cs) hb
            writeIORef (childRestarts cs) 0
            status <- readTVarIO (childStatus cs)
            case status of
                Running pid -> killGracefully oldSpec pid >> pure True
                Starting -> pure True
                Restarting _ -> pure True
                _ -> pure False

-- ── Child Lifecycle Loop ───────────────────────────────────────

childLoop :: SupervisorState -> ChildState -> IO ()
childLoop sv cs = do
    initialSpec <- readTVarIO (childSpec cs)
    go (csRestartBaseMs initialSpec)
  where
    go delay = do
        alive <- readTVarIO (svRunning sv)
        unless alive $ do
            atomically $ writeTVar (childStatus cs) Stopped
            pure ()

        when alive $ do
            spec <- readTVarIO (childSpec cs)
            logChild spec "launching"
            atomically $ writeTVar (childStatus cs) Starting

            startTime <- FFI.clockUs
            writeIORef (childLastStart cs) startTime

            pid <- launchChild spec
            logChild spec $ "pid=" ++ show pid
            atomically $ writeTVar (childStatus cs) (Running pid)

            -- Monitor until exit or heartbeat timeout
            exitStatus <- monitorChild cs pid startTime

            endTime <- FFI.clockUs
            let uptimeUs = endTime - startTime
                uptimeSec = fromIntegral uptimeUs / 1_000_000 :: Double
            modifyIORef' (childTotalUp cs) (+ uptimeUs)

            logChild spec $ "exited after " ++ show (round uptimeSec :: Int) ++ "s: " ++ show exitStatus

            case launchFailureMessage exitStatus of
                Just err -> do
                    logChild spec $ "launch failed: " ++ err
                    atomically $ writeTVar (childStatus cs) (Failed err)
                Nothing -> do
                    -- Decide whether to restart
                    stillAlive <- readTVarIO (svRunning sv)
                    restartCount <- readIORef (childRestarts cs)

                    let maxR = csMaxRestarts spec
                        canRestart = stillAlive && (maxR < 0 || restartCount < maxR)

                    if canRestart
                        then do
                            modifyIORef' (childRestarts cs) (+ 1)
                            let newCount = restartCount + 1
                            atomically $ writeTVar (childStatus cs) (Restarting newCount)

                            -- Reset backoff if child ran > 10s
                            let nextDelay = if uptimeSec > 10.0
                                    then csRestartBaseMs spec
                                    else min (delay * 2) (csRestartMaxMs spec)

                            logChild spec $ "restart #" ++ show newCount ++ " in " ++ show nextDelay ++ "ms"
                            threadDelay (nextDelay * 1000)
                            go nextDelay
                        else do
                            if stillAlive
                                then do
                                    logChild spec "max restarts reached — giving up"
                                    atomically $ writeTVar (childStatus cs) (Failed "max restarts")
                                else
                                    atomically $ writeTVar (childStatus cs) Stopped

launchChild :: ChildSpec -> IO ProcessID
launchChild spec = forkProcess $ runChildLaunch spec

runChildLaunch :: ChildSpec -> IO ()
runChildLaunch spec = do
    applyPreExecSetupOrExit spec
    execResult <- try (executeFile (csBinary spec) True (csArgs spec) Nothing)
        :: IO (Either IOException ())
    case execResult of
        Left err ->
            launchFailure spec launchExecFailureCode $
                "executeFile failed for " ++ csBinary spec ++ ": " ++ show err
        Right () -> pure ()

applyPreExecSetupOrExit :: ChildSpec -> IO ()
applyPreExecSetupOrExit spec = do
    case csCpuCore spec of
        Nothing -> pure ()
        Just core ->
            requireSuccessOrExit
                spec
                launchAffinityFailureCode
                ("set CPU affinity to core " ++ show core)
                (FFI.setCpuAffinityResult core)

    case csSchedFifo spec of
        Nothing -> pure ()
        Just prio ->
            requireSuccessOrExit
                spec
                launchSchedFifoFailureCode
                ("set SCHED_FIFO priority " ++ show prio)
                (FFI.setSchedFifoResult prio)

    when (csMlockAll spec) $ do
        requireSuccessOrExit
            spec
            launchMemlockLimitFailureCode
            "raise RLIMIT_MEMLOCK to unlimited"
            FFI.setRlimitMemlockUnlimitedResult
        requireSuccessOrExit
            spec
            launchMlockAllFailureCode
            "mlockall current and future pages"
            FFI.callMlockAllResult

requireSuccessOrExit :: ChildSpec -> Int -> String -> IO Int -> IO ()
requireSuccessOrExit spec exitCode action io = do
    rc <- io
    unless (rc == 0) $
        launchFailure spec exitCode (action ++ " failed (" ++ describeErrno (-rc) ++ ")")

describeErrno :: Int -> String
describeErrno errno =
    case errno of
        1  -> "EPERM / operation not permitted"
        12 -> "ENOMEM / insufficient locked memory"
        13 -> "EACCES / permission denied"
        22 -> "EINVAL / invalid argument"
        38 -> "ENOSYS / operation not supported"
        _  -> "errno " ++ show errno

launchFailure :: ChildSpec -> Int -> String -> IO a
launchFailure spec exitCode err = do
    logChild spec $ "launch failed: " ++ err
    exitImmediately (ExitFailure exitCode)

launchFailureMessage :: ChildExit -> Maybe String
launchFailureMessage (ChildExited (Exited (ExitFailure code))) =
    case code of
        200 -> Just "CPU affinity setup failed before exec"
        201 -> Just "SCHED_FIFO setup failed before exec"
        202 -> Just "RLIMIT_MEMLOCK setup failed before exec"
        203 -> Just "mlockall failed before exec"
        204 -> Just "child exec failed before startup completed"
        _   -> Nothing
launchFailureMessage _ = Nothing

launchAffinityFailureCode, launchSchedFifoFailureCode, launchMemlockLimitFailureCode :: Int
launchMlockAllFailureCode, launchExecFailureCode :: Int
launchAffinityFailureCode = 200
launchSchedFifoFailureCode = 201
launchMemlockLimitFailureCode = 202
launchMlockAllFailureCode = 203
launchExecFailureCode = 204

data ChildExit
    = ChildExited ProcessStatus
    | ChildHeartbeatTimeout Word64  -- ^ stale duration in microseconds
    deriving (Show)

getProcessStatusSafe :: ProcessID -> IO (Maybe ProcessStatus)
getProcessStatusSafe pid = do
    result <- try (getProcessStatus False False pid) :: IO (Either IOException (Maybe ProcessStatus))
    case result of
        Right status -> pure status
        Left err
            | isDoesNotExistError err -> pure (Just (Exited ExitSuccess))
            | otherwise -> ioError err

monitorChild :: ChildState -> ProcessID -> Word64 -> IO ChildExit
monitorChild cs pid startTime = loop
  where
    loop = do
        spec <- readTVarIO (childSpec cs)
        mStatus <- getProcessStatusSafe pid
        case mStatus of
            Just ps -> pure (ChildExited ps)
            Nothing -> do
                heartbeat <- readTVarIO (childHeartbeat cs)
                case heartbeat of
                    Nothing -> do
                        threadDelay 50_000
                        loop
                    Just (ipc, timeoutUs) -> do
                        now <- FFI.clockUs
                        lastHb <- FFI.heartbeatTimestamp ipc
                        let heartbeatReady = lastHb /= 0 && lastHb >= startTime
                            staleByUs = now - lastHb
                        if heartbeatReady && staleByUs > timeoutUs
                            then do
                                logChild spec $
                                    "heartbeat stale by " ++ show (staleByUs `div` 1000) ++ "ms"
                                killGracefully spec pid
                                pure (ChildHeartbeatTimeout staleByUs)
                            else do
                                threadDelay 50_000
                                loop

monitorUntilExit :: ProcessID -> IO ProcessStatus
monitorUntilExit pid = loop
  where
    loop = do
        mStatus <- getProcessStatusSafe pid
        case mStatus of
            Just ps -> pure ps
            Nothing -> do
                threadDelay 50_000
                loop

-- ── Shutdown ───────────────────────────────────────────────────

shutdownAll :: SupervisorState -> IO ()
shutdownAll sv = do
    logSupervisor "shutting down all children"
    atomically $ writeTVar (svRunning sv) False

    children <- readTVarIO (svChildren sv)
    forM_ (Map.elems children) $ \cs -> do
        status <- readTVarIO (childStatus cs)
        case status of
            Running pid -> readTVarIO (childSpec cs) >>= \spec -> killGracefully spec pid
            _           -> pure ()

    -- Cancel worker threads
    workers <- readIORef (svWorkers sv)
    mapM_ cancel workers

killGracefully :: ChildSpec -> ProcessID -> IO ()
killGracefully spec pid = do
    logChild spec $ "SIGTERM → " ++ show pid
    result <- try $ signalProcess sigTERM pid :: IO (Either SomeException ())
    case result of
        Left _ -> pure ()  -- already dead
        Right _ -> do
            outcome <- race
                (monitorUntilExit pid)
                (threadDelay (csShutdownMs spec * 1000))
            case outcome of
                Left _  -> logChild spec "exited after SIGTERM"
                Right _ -> do
                    logChild spec "SIGKILL"
                    _ <- try $ signalProcess sigKILL pid :: IO (Either SomeException ())
                    _ <- try $ monitorUntilExit pid :: IO (Either SomeException ProcessStatus)
                    logChild spec "reaped"

-- ── Query ──────────────────────────────────────────────────────

getChildStatus :: SupervisorState -> String -> IO (Maybe ChildStatus)
getChildStatus sv name = do
    children <- readTVarIO (svChildren sv)
    case Map.lookup name children of
        Nothing -> pure Nothing
        Just cs -> Just <$> readTVarIO (childStatus cs)

allChildStates :: SupervisorState -> IO [(String, ChildStatus, Int, Word64)]
allChildStates sv = do
    children <- readTVarIO (svChildren sv)
    forM (Map.toList children) $ \(name, cs) -> do
        status   <- readTVarIO (childStatus cs)
        restarts <- readIORef (childRestarts cs)
        uptime   <- readIORef (childTotalUp cs)
        pure (name, status, restarts, uptime)

-- ── Logging ────────────────────────────────────────────────────

logSupervisor :: String -> IO ()
logSupervisor msg = hPutStrLn stderr $ "[supervisor] " ++ msg

logChild :: ChildSpec -> String -> IO ()
logChild spec msg = hPutStrLn stderr $ "[" ++ csName spec ++ "] " ++ msg

-- ── Run All ────────────────────────────────────────────────────

{- |
Run the supervisor, blocking until the running TVar becomes False.
Call spawnChild for each child before calling this.
-}
runSupervisor :: SupervisorState -> IO ()
runSupervisor sv = do
    logSupervisor "supervisor active"
    loop
    logSupervisor "supervisor exiting"
  where
    loop = do
        alive <- readTVarIO (svRunning sv)
        when alive $ do
            threadDelay 1_000_000  -- 1s status check
            states <- allChildStates sv
            let running = length [() | (_, Running _, _, _) <- states]
                failed  = length [() | (_, Failed _, _, _) <- states]
            when (failed > 0) $
                logSupervisor $ show running ++ " running, " ++ show failed ++ " failed"
            loop
