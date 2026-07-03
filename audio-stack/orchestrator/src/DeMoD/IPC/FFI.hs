{- |
Module      : DeMoD.IPC.FFI
Description : Foreign Function Interface to C IPC primitives
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Bindings to demod_ffi_helpers.c. All calls are 'unsafe' for ~10-20ns
overhead instead of ~100ns+ for safe calls. This is critical for the
triple buffer publish path which runs at ~1ms intervals.

SAFETY NOTE: unsafe FFI calls block the GHC capability they run on.
This is acceptable because every call here completes in nanoseconds
(atomic ops, memcpy, clock_gettime). Do NOT add blocking syscalls
(sleep, read, poll) as unsafe imports.
-}

{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module DeMoD.IPC.FFI
    ( -- * Opaque IPC handle
      IpcHandle
    , SnapPtr

      -- * POSIX RT setup
    , setCpuAffinityResult
    , setCpuAffinity
    , setSchedFifoResult
    , setSchedFifo
    , setRlimitMemlockUnlimitedResult
    , setRlimitMemlockUnlimited
    , callMlockAllResult
    , callMlockAll
    , clockUs

      -- * IPC lifecycle
    , ipcCreate
    , ipcOpen
    , ipcDestroy

      -- * Triple buffer
    , tbBeginWrite
    , tbPublish
    , tbReadCopy
    , tbSequence

      -- * SPSC rings
    , cmdPush
    , evtPush
    , evtPop
    , evtAvailable

      -- * Heartbeat
    , heartbeatTimestamp
    , heartbeatCallbackCount
    , heartbeatXrunCount
    , heartbeatAlive
    , heartbeatCpuLoad

      -- * Snapshot field setters
    , snapSetPitch
    , snapSetTempo
    , snapSetFxParam
    , snapSetFxBypass
    , snapSetSynth
    , snapSetBtState
    , snapSetSdr
    , snapSetTimestamp

      -- * Snapshot field getters
    , snapGetPitchHz
    , snapGetPitchConfidence
    , snapGetMidiNote
    , snapGetBpm
    , snapGetBeatCount
    , snapGetFxParam
    , snapGetFxBypass
    , snapGetSynthMixMode
    , snapGetSynthGain

      -- * Constants
    , paramSnapshotSize
    , defaultSpscCapacity
    ) where

import Foreign.C.Types
import Foreign.Ptr (Ptr, nullPtr)
import Data.Word

-- | Size of DemodParamSnapshot (256 bytes)
paramSnapshotSize :: Int
paramSnapshotSize = 256

-- | Default SPSC ring capacity
defaultSpscCapacity :: Word64
defaultSpscCapacity = 4096

-- | Opaque pointer to the C DemodIpc struct
type IpcHandle = Ptr ()

-- | Pointer to a DemodParamSnapshot (within triple buffer or local copy)
type SnapPtr = Ptr ()

-- ── POSIX RT Helpers ──────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_set_cpu_affinity"
    c_set_cpu_affinity :: CInt -> IO CInt

foreign import ccall unsafe "demod_ffi_set_sched_fifo"
    c_set_sched_fifo :: CInt -> IO CInt

foreign import ccall unsafe "demod_ffi_set_rlimit_memlock_unlimited"
    c_set_rlimit_memlock :: IO CInt

foreign import ccall unsafe "demod_ffi_mlockall"
    c_mlockall :: IO CInt

foreign import ccall unsafe "demod_ffi_clock_us"
    clockUs :: IO Word64

-- | Set CPU affinity. Returns True on success.
setCpuAffinityResult :: Int -> IO Int
setCpuAffinityResult core =
    fromIntegral <$> c_set_cpu_affinity (fromIntegral core)

-- | Set CPU affinity. Returns True on success.
setCpuAffinity :: Int -> IO Bool
setCpuAffinity core = (== 0) <$> setCpuAffinityResult core

-- | Set SCHED_FIFO. Returns True on success.
setSchedFifoResult :: Int -> IO Int
setSchedFifoResult prio =
    fromIntegral <$> c_set_sched_fifo (fromIntegral prio)

-- | Set SCHED_FIFO. Returns True on success.
setSchedFifo :: Int -> IO Bool
setSchedFifo prio = (== 0) <$> setSchedFifoResult prio

-- | Raise RLIMIT_MEMLOCK to unlimited. Returns True on success.
setRlimitMemlockUnlimitedResult :: IO Int
setRlimitMemlockUnlimitedResult = fromIntegral <$> c_set_rlimit_memlock

-- | Raise RLIMIT_MEMLOCK to unlimited. Returns True on success.
setRlimitMemlockUnlimited :: IO Bool
setRlimitMemlockUnlimited = (== 0) <$> setRlimitMemlockUnlimitedResult

-- | mlockall(MCL_CURRENT | MCL_FUTURE). Returns True on success.
callMlockAllResult :: IO Int
callMlockAllResult = fromIntegral <$> c_mlockall

-- | mlockall(MCL_CURRENT | MCL_FUTURE). Returns True on success.
callMlockAll :: IO Bool
callMlockAll = (== 0) <$> callMlockAllResult

-- ── IPC Lifecycle ─────────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_ipc_create"
    c_ipc_create :: Word64 -> IO IpcHandle

foreign import ccall unsafe "demod_ffi_ipc_open"
    c_ipc_open :: Word64 -> IO IpcHandle

foreign import ccall unsafe "demod_ffi_ipc_destroy"
    ipcDestroy :: IpcHandle -> IO ()

-- | Create all IPC regions. Returns Nothing on failure.
ipcCreate :: Word64 -> IO (Maybe IpcHandle)
ipcCreate cap = do
    h <- c_ipc_create cap
    pure $ if h == nullPtr then Nothing else Just h

-- | Open all IPC regions (child side). Returns Nothing on failure.
ipcOpen :: Word64 -> IO (Maybe IpcHandle)
ipcOpen cap = do
    h <- c_ipc_open cap
    pure $ if h == nullPtr then Nothing else Just h

-- ── Triple Buffer ─────────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_tb_begin_write"
    tbBeginWrite :: IpcHandle -> IO SnapPtr

foreign import ccall unsafe "demod_ffi_tb_publish"
    tbPublish :: IpcHandle -> IO ()

foreign import ccall unsafe "demod_ffi_tb_read_copy"
    tbReadCopy :: IpcHandle -> SnapPtr -> IO Word64

foreign import ccall unsafe "demod_ffi_tb_sequence"
    tbSequence :: IpcHandle -> IO Word64

-- ── SPSC Rings ────────────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_cmd_push"
    cmdPush :: IpcHandle -> Ptr CFloat -> Word64 -> IO Word64

foreign import ccall unsafe "demod_ffi_evt_push"
    evtPush :: IpcHandle -> Ptr CFloat -> Word64 -> IO Word64

foreign import ccall unsafe "demod_ffi_evt_pop"
    evtPop :: IpcHandle -> Ptr CFloat -> Word64 -> IO Word64

foreign import ccall unsafe "demod_ffi_evt_available"
    evtAvailable :: IpcHandle -> IO Word64

-- ── Heartbeat ─────────────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_heartbeat_timestamp"
    heartbeatTimestamp :: IpcHandle -> IO Word64

foreign import ccall unsafe "demod_ffi_heartbeat_callback_count"
    heartbeatCallbackCount :: IpcHandle -> IO Word64

foreign import ccall unsafe "demod_ffi_heartbeat_xrun_count"
    heartbeatXrunCount :: IpcHandle -> IO Word64

foreign import ccall unsafe "demod_ffi_heartbeat_alive"
    heartbeatAlive :: IpcHandle -> IO Word32

foreign import ccall unsafe "demod_ffi_heartbeat_cpu_load"
    heartbeatCpuLoad :: IpcHandle -> IO CFloat

-- ── Snapshot Setters ──────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_snap_set_pitch"
    snapSetPitch :: SnapPtr -> CFloat -> CFloat -> CInt -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_tempo"
    snapSetTempo :: SnapPtr -> CFloat -> Word32 -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_fx_param"
    snapSetFxParam :: SnapPtr -> CInt -> CFloat -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_fx_bypass"
    snapSetFxBypass :: SnapPtr -> Word32 -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_synth"
    snapSetSynth :: SnapPtr -> Word32 -> CFloat -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_bt_state"
    snapSetBtState :: SnapPtr -> Word8 -> Word8 -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_sdr"
    snapSetSdr :: SnapPtr -> CFloat -> CFloat -> IO ()

foreign import ccall unsafe "demod_ffi_snap_set_timestamp"
    snapSetTimestamp :: SnapPtr -> Word64 -> IO ()

-- ── Snapshot Getters ──────────────────────────────────────────────

foreign import ccall unsafe "demod_ffi_snap_get_pitch_hz"
    snapGetPitchHz :: SnapPtr -> IO CFloat

foreign import ccall unsafe "demod_ffi_snap_get_pitch_confidence"
    snapGetPitchConfidence :: SnapPtr -> IO CFloat

foreign import ccall unsafe "demod_ffi_snap_get_midi_note"
    snapGetMidiNote :: SnapPtr -> IO CInt

foreign import ccall unsafe "demod_ffi_snap_get_bpm"
    snapGetBpm :: SnapPtr -> IO CFloat

foreign import ccall unsafe "demod_ffi_snap_get_beat_count"
    snapGetBeatCount :: SnapPtr -> IO Word32

foreign import ccall unsafe "demod_ffi_snap_get_fx_param"
    snapGetFxParam :: SnapPtr -> CInt -> IO CFloat

foreign import ccall unsafe "demod_ffi_snap_get_fx_bypass"
    snapGetFxBypass :: SnapPtr -> IO Word32

foreign import ccall unsafe "demod_ffi_snap_get_synth_mix_mode"
    snapGetSynthMixMode :: SnapPtr -> IO Word32

foreign import ccall unsafe "demod_ffi_snap_get_synth_gain"
    snapGetSynthGain :: SnapPtr -> IO CFloat
