{- |
Module      : DeMoD.BT.FFI
Description : FFI to demod-bt's BLE-MIDI peripheral
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

Bindings to the BLE-MIDI surface of @libdemod_bt@. The audio (A2DP)
side of the library is intentionally NOT bound here — that lives in the
demod-bt-daemon process and the orchestrator never touches it.

All calls are 'unsafe' for ~10–20 ns overhead; the underlying Rust
implementations push the work into a tokio task and return immediately.
-}

{-# LANGUAGE ForeignFunctionInterface #-}

module DeMoD.BT.FFI
    ( -- * Lifecycle
      midiStart
    , midiStop

      -- * Sending
    , midiSendBytes
    ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word8)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..), CUInt(..))
import Foreign.Ptr (Ptr, castPtr)

foreign import ccall unsafe "demod_bt_midi_start"
    c_midi_start :: CString -> IO CInt

foreign import ccall unsafe "demod_bt_midi_send"
    c_midi_send :: Ptr Word8 -> CUInt -> IO CInt

foreign import ccall unsafe "demod_bt_midi_stop"
    c_midi_stop :: IO ()

-- | Bring up the BLE-MIDI peripheral. Returns 'True' on success.
-- Idempotent — calling twice is a successful no-op.
midiStart :: String -> IO Bool
midiStart name = withCString name $ \cs -> do
    rc <- c_midi_start cs
    pure (rc == 0)

-- | Tear down the BLE-MIDI peripheral. Safe to call when not running.
midiStop :: IO ()
midiStop = c_midi_stop

-- | Push a raw MIDI message (status + data bytes). Returns 'True' on
-- success. The Rust side adds BLE-MIDI framing and notifies any
-- subscribed peers; if no peer is subscribed, the message is dropped
-- silently and the call still succeeds.
midiSendBytes :: BS.ByteString -> IO Bool
midiSendBytes bs
    | BS.null bs = pure False
    | otherwise = BSU.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
        rc <- c_midi_send (castPtr ptr) (fromIntegral len)
        pure (rc == 0)
