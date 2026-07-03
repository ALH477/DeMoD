{- |
Module      : DeMoD.Marketplace
Description : Embedded Marketplace bridge snapshot publisher
Copyright   : (c) DeMoD LLC, 2025-2026
License     : GPL-3.0-only

This module keeps Marketplace auth bridge-owned. It only observes the local
device bridge, publishes status/catalog/library snapshots to shared memory,
and asks the existing pairing-code utility to mint short-lived physical codes.
-}

{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module DeMoD.Marketplace
    ( MarketplaceConfig(..)
    , defaultMarketplaceConfig
    , runMarketplace
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Exception (SomeException, bracket, try)
import Control.Applicative ((<|>))
import Control.Monad (forM, when)
import Data.Aeson
    ( Value(..)
    , eitherDecodeStrict'
    , encode
    , object
    , toJSON
    , (.=)
    )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isSpace, ord)
import Data.IORef
import Data.List (isPrefixOf)
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Time.Clock
    ( NominalDiffTime
    , UTCTime
    , addUTCTime
    , diffUTCTime
    , getCurrentTime
    )
import Data.Word (Word32)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt(..), CSize(..), CUInt(..))
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Network.Socket
    ( AddrInfo(..)
    , AddrInfoFlag(AI_ADDRCONFIG)
    , Socket
    , SocketType(Stream)
    , close
    , connect
    , defaultHints
    , getAddrInfo
    , socket
    , withSocketsDo
    )
import qualified Network.Socket.ByteString as NSB
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeExtension, takeFileName)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Text.Printf (printf)

data MarketplaceConfig = MarketplaceConfig
    { mcEnabled             :: !Bool
    , mcBridgeUrl           :: !String
    , mcShmName             :: !String
    , mcPollIntervalMs      :: !Int
    , mcOfflineTimeoutMs    :: !Int
    , mcLibraryDir          :: !FilePath
    , mcInstallManifestPath :: !FilePath
    , mcCatalogFile         :: !(Maybe FilePath)
    , mcPairingCodeBin      :: !FilePath
    , mcPairingCodeFile     :: !FilePath
    , mcPairingCodeTtlSec   :: !Int
    , mcQrEncodeBin         :: !(Maybe FilePath)
    } deriving (Show)

defaultMarketplaceConfig :: MarketplaceConfig
defaultMarketplaceConfig = MarketplaceConfig
    { mcEnabled             = False
    , mcBridgeUrl           = "http://127.0.0.1:7635"
    , mcShmName             = "/demod-mkt-shm"
    , mcPollIntervalMs      = 1000
    , mcOfflineTimeoutMs    = 5000
    , mcLibraryDir          = "/var/lib/demod/library"
    , mcInstallManifestPath = "/var/lib/demod/market/install-manifest.json"
    , mcCatalogFile         = Nothing
    , mcPairingCodeBin      = "demod-pairing-code"
    , mcPairingCodeFile     = "/var/lib/demod/market/pairing-code.json"
    , mcPairingCodeTtlSec   = 600
    , mcQrEncodeBin         = Nothing
    }

data BridgeEndpoint = BridgeEndpoint
    { beHost :: !String
    , bePort :: !String
    , beBasePath :: !String
    } deriving (Show)

data PairingCode = PairingCode
    { pcCode :: !Text
    , pcExpiresAt :: !(Maybe UTCTime)
    , pcUri :: !Text
    , pcQrMatrix :: !(Maybe [Text])
    } deriving (Show)

foreign import ccall safe "demod_mkt_shm_create"
    c_mkt_shm_create :: CString -> IO (Ptr ())

foreign import ccall safe "demod_mkt_shm_destroy"
    c_mkt_shm_destroy :: Ptr () -> IO ()

foreign import ccall unsafe "demod_mkt_shm_write_json"
    c_mkt_shm_write_json :: Ptr () -> CUInt -> Ptr () -> CSize -> IO CInt

runMarketplace :: MarketplaceConfig -> TVar Bool -> IO ()
runMarketplace cfg running
    | not (mcEnabled cfg) = pure ()
    | otherwise =
        withCString (mcShmName cfg) $ \name ->
          bracket (c_mkt_shm_create name) destroyHandle $ \handle ->
            if handle == nullPtr
                then logMsg "failed to create Marketplace shared memory"
                else do
                    logMsg $ "Marketplace publisher enabled at " ++ mcBridgeUrl cfg
                    lastOnline <- newIORef Nothing
                    pairingRef <- newIORef Nothing
                    publishLoop cfg running handle lastOnline pairingRef
  where
    destroyHandle handle =
        when (handle /= nullPtr) (c_mkt_shm_destroy handle)

publishLoop
    :: MarketplaceConfig
    -> TVar Bool
    -> Ptr ()
    -> IORef (Maybe UTCTime)
    -> IORef (Maybe PairingCode)
    -> IO ()
publishLoop cfg running handle lastOnline pairingRef = loop
  where
    delayUs = max 100 (mcPollIntervalMs cfg) * 1000
    loop = do
        alive <- readTVarIO running
        when alive $ do
            snapshot <- buildSnapshot cfg lastOnline pairingRef
            writePayload handle (payloadType snapshot) (payloadValue snapshot)
            threadDelay delayUs
            loop

data Snapshot = Snapshot
    { payloadType :: !Word32
    , payloadValue :: !Value
    }

buildSnapshot
    :: MarketplaceConfig
    -> IORef (Maybe UTCTime)
    -> IORef (Maybe PairingCode)
    -> IO Snapshot
buildSnapshot cfg lastOnline pairingRef = do
    now <- getCurrentTime
    pairingStatus <- fetchJson cfg "/v1/pairing/status"
    library <- localLibrary (mcLibraryDir cfg)
    manifest <- readJsonFile (mcInstallManifestPath cfg)
    catalog <- readCatalogFile (mcCatalogFile cfg)
    case pairingStatus of
        Left err -> do
            graceOnline <- stillInsideOfflineGrace cfg now lastOnline
            let modeText = if graceOnline then ("degraded" :: Text) else "offline"
                payload = object
                    [ "v" .= (1 :: Int)
                    , "mode" .= modeText
                    , "bridgeUrl" .= mcBridgeUrl cfg
                    , "offline" .= object
                        [ "reason" .= err
                        , "localEffectsOnly" .= True
                        ]
                    , "library" .= library
                    , "manifest" .= manifest
                    , "catalog" .= catalog
                    ]
            pure $ Snapshot 6 payload
        Right pairing -> do
            writeIORef lastOnline (Just now)
            mCode <- ensurePairingCode cfg pairingRef pairing
            capabilities <- fetchJsonOrError cfg "/v1/capabilities"
            slots <- fetchJsonOrError cfg "/v1/slots"
            events <- fetchJsonOrError cfg "/v1/events?limit=24"
            bridgeManifest <- fetchJsonOrDefault cfg "/v1/effects/manifest" manifest
            let payload = object
                    [ "v" .= (1 :: Int)
                    , "mode" .= ("online" :: Text)
                    , "bridgeUrl" .= mcBridgeUrl cfg
                    , "pairing" .= pairingObject pairing mCode
                    , "capabilities" .= capabilities
                    , "slots" .= slots
                    , "events" .= events
                    , "library" .= library
                    , "manifest" .= bridgeManifest
                    , "catalog" .= catalog
                    ]
            pure $ Snapshot 4 payload

stillInsideOfflineGrace
    :: MarketplaceConfig -> UTCTime -> IORef (Maybe UTCTime) -> IO Bool
stillInsideOfflineGrace cfg now lastOnline = do
    mLast <- readIORef lastOnline
    pure $ case mLast of
        Nothing -> False
        Just lastOk ->
            diffUTCTime now lastOk
                <= fromIntegral (max 0 (mcOfflineTimeoutMs cfg)) / 1000

writePayload :: Ptr () -> Word32 -> Value -> IO ()
writePayload handle payloadKind value =
    BS.useAsCStringLen strictPayload $ \(ptr, len) -> do
        rc <- c_mkt_shm_write_json
            handle
            (fromIntegral payloadKind)
            (castPtr ptr)
            (fromIntegral len)
        when (rc /= 0) $
            logMsg $ "Marketplace shared-memory write failed rc=" ++ show rc
  where
    strictPayload = BL.toStrict (encode value)

fetchJsonOrDefault :: MarketplaceConfig -> String -> Value -> IO Value
fetchJsonOrDefault cfg path fallback = do
    result <- fetchJson cfg path
    pure $ either (const fallback) id result

fetchJsonOrError :: MarketplaceConfig -> String -> IO Value
fetchJsonOrError cfg path = do
    result <- fetchJson cfg path
    pure $ case result of
        Right value -> value
        Left err -> object ["ok" .= False, "err" .= err]

fetchJson :: MarketplaceConfig -> String -> IO (Either String Value)
fetchJson cfg path =
    case parseBridgeEndpoint (mcBridgeUrl cfg) of
        Nothing -> pure $ Left $ "unsupported bridge URL: " ++ mcBridgeUrl cfg
        Just endpoint ->
            tryText (httpGetJson endpoint path) >>= \case
                Left err -> pure (Left err)
                Right value -> pure (Right value)

httpGetJson :: BridgeEndpoint -> String -> IO Value
httpGetJson endpoint path = do
    raw <- withTimeout "bridge request timed out" 2_000_000 $
        httpGet endpoint path
    let body = responseBody raw
    case eitherDecodeStrict' body of
        Left err -> fail $ "bridge JSON decode failed: " ++ err
        Right value -> pure value

httpGet :: BridgeEndpoint -> String -> IO BS.ByteString
httpGet BridgeEndpoint{..} path = withSocketsDo $ do
    let hints = defaultHints
            { addrSocketType = Stream
            , addrFlags = [AI_ADDRCONFIG]
            }
    addrs <- getAddrInfo (Just hints) (Just beHost) (Just bePort)
    case addrs of
        [] -> fail $ "no address for " ++ beHost ++ ":" ++ bePort
        addr:_ ->
            bracket
                (socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr))
                close
                $ \sock -> do
                    connect sock (addrAddress addr)
                    NSB.sendAll sock (requestBytes beHost beBasePath path)
                    recvAll sock [] 0

requestBytes :: String -> String -> String -> BS.ByteString
requestBytes host basePath path =
    B8.pack $ concat
        [ "GET ", normalizePath basePath path, " HTTP/1.1\r\n"
        , "Host: ", host, "\r\n"
        , "Accept: application/json\r\n"
        , "Connection: close\r\n\r\n"
        ]

recvAll :: Socket -> [BS.ByteString] -> Int -> IO BS.ByteString
recvAll sock chunks total
    | total > 512 * 1024 = pure (BS.concat (reverse chunks))
    | otherwise = do
        chunk <- NSB.recv sock 16384
        if BS.null chunk
            then pure (BS.concat (reverse chunks))
            else recvAll sock (chunk:chunks) (total + BS.length chunk)

responseBody :: BS.ByteString -> BS.ByteString
responseBody raw =
    case B8.breakSubstring "\r\n\r\n" raw of
        (_, rest)
            | BS.length rest >= 4 -> BS.drop 4 rest
        _ -> raw

parseBridgeEndpoint :: String -> Maybe BridgeEndpoint
parseBridgeEndpoint raw = do
    rest <- stripPrefixText "http://" raw
    let (hostPort, rawPath) = break (== '/') rest
        basePath = if null rawPath then "/" else rawPath
        (host, port) = splitHostPort hostPort
    if null host
        then Nothing
        else Just BridgeEndpoint
            { beHost = host
            , bePort = port
            , beBasePath = basePath
            }

splitHostPort :: String -> (String, String)
splitHostPort hostPort =
    case break (== ':') hostPort of
        (host, ':' : port) | not (null port) -> (host, port)
        _ -> (hostPort, "80")

stripPrefixText :: String -> String -> Maybe String
stripPrefixText prefix raw =
    if prefix `isPrefixOf` raw
        then Just (drop (length prefix) raw)
        else Nothing

normalizePath :: String -> String -> String
normalizePath basePath path =
    let base = if null basePath || basePath == "/" then "" else dropTrailingSlash basePath
        suffix = if "/" `isPrefixOf` path then path else "/" ++ path
    in base ++ suffix

dropTrailingSlash :: String -> String
dropTrailingSlash value =
    case reverse value of
        '/':rest -> reverse rest
        _ -> value

readCatalogFile :: Maybe FilePath -> IO Value
readCatalogFile Nothing = pure (toJSON ([] :: [Value]))
readCatalogFile (Just path) = do
    exists <- doesFileExist path
    if not exists
        then pure (toJSON ([] :: [Value]))
        else readJsonFile path

readJsonFile :: FilePath -> IO Value
readJsonFile path = do
    exists <- doesFileExist path
    if not exists
        then pure Null
        else do
            decoded <- tryText $ eitherDecodeStrict' <$> BS.readFile path
            pure $ case decoded of
                Right (Right value) -> value
                Right (Left err) -> object ["ok" .= False, "err" .= err]
                Left err -> object ["ok" .= False, "err" .= err]

localLibrary :: FilePath -> IO Value
localLibrary dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then pure $ object ["effects" .= ([] :: [Value])]
        else do
            names <- listDirectory dir
            effects <- forM (filter ((== ".so") . takeExtension) names) $ \name -> do
                let path = dir </> name
                pure $ object
                    [ "name" .= takeFileName name
                    , "path" .= path
                    , "active" .= False
                    , "source" .= ("local" :: Text)
                    ]
            pure $ object ["effects" .= effects]

ensurePairingCode
    :: MarketplaceConfig
    -> IORef (Maybe PairingCode)
    -> Value
    -> IO (Maybe PairingCode)
ensurePairingCode cfg ref statusPayload = do
    now <- getCurrentTime
    cached <- readIORef ref
    case cached of
        Just code | maybe True (> now) (pcExpiresAt code) ->
            pure (Just code)
        _ ->
            if pairingActive statusPayload
                then pure cached
                else mintPairingCode cfg now >>= \case
                    Nothing -> pure cached
                    Just code -> writeIORef ref (Just code) >> pure (Just code)

pairingActive :: Value -> Bool
pairingActive value =
    fromMaybe False $
        boolAt ["data", "pairing", "active"] value
        <|> boolAt ["pairing", "active"] value

mintPairingCode :: MarketplaceConfig -> UTCTime -> IO (Maybe PairingCode)
mintPairingCode cfg now
    | null (mcPairingCodeBin cfg) || null (mcPairingCodeFile cfg) = pure Nothing
    | otherwise = do
        result <- tryText $ readProcessWithExitCode
            (mcPairingCodeBin cfg)
            [ "--code-file", mcPairingCodeFile cfg
            , "--ttl-seconds", show (mcPairingCodeTtlSec cfg)
            , "--digits", "6"
            ]
            ""
        case result of
            Left err -> logMsg ("pairing-code mint failed: " ++ err) >> pure Nothing
            Right (ExitFailure code, out, err) -> do
                logMsg $ "pairing-code exited " ++ show code ++ ": " ++ firstLine (err ++ out)
                pure Nothing
            Right (ExitSuccess, out, _) ->
                case lines out of
                    [] -> pure Nothing
                    codeLine:_ -> do
                        let code = T.pack codeLine
                            expires = addUTCTime
                                (fromIntegral (mcPairingCodeTtlSec cfg) :: NominalDiffTime)
                                now
                            uri = pairingUri (mcBridgeUrl cfg) code
                        qr <- renderQrMatrix (mcQrEncodeBin cfg) uri
                        pure $ Just PairingCode
                            { pcCode = code
                            , pcExpiresAt = Just expires
                            , pcUri = uri
                            , pcQrMatrix = qr
                            }

pairingObject :: Value -> Maybe PairingCode -> Value
pairingObject status mCode = object $
    [ "status" .= status
    , "code" .= fmap pcCode mCode
    , "uri" .= fmap pcUri mCode
    ] ++ catMaybes
    [ (\code -> "qr" .= object
        [ "format" .= ("matrix-v1" :: Text)
        , "modules" .= pcQrMatrix code
        ]) <$> mCodeWithQr
    ]
  where
    mCodeWithQr = case mCode of
        Just code | pcQrMatrix code /= Nothing -> Just code
        _ -> Nothing

pairingUri :: String -> Text -> Text
pairingUri bridgeUrl code =
    T.concat
        [ "demod://pair?bridge="
        , T.pack (urlEncode bridgeUrl)
        , "&code="
        , T.pack (urlEncode (T.unpack code))
        ]

renderQrMatrix :: Maybe FilePath -> Text -> IO (Maybe [Text])
renderQrMatrix Nothing _ = pure Nothing
renderQrMatrix (Just bin) payload
    | null bin = pure Nothing
    | otherwise = do
        result <- tryText $
            readProcessWithExitCode bin ["-t", "ASCII", "-m", "1", T.unpack payload] ""
        case result of
            Right (ExitSuccess, out, _) ->
                pure $ normalizeQrAscii out
            Right (ExitFailure code, _, err) -> do
                logMsg $ "qrencode exited " ++ show code ++ ": " ++ firstLine err
                pure Nothing
            Left err -> do
                logMsg $ "qrencode failed: " ++ err
                pure Nothing

normalizeQrAscii :: String -> Maybe [Text]
normalizeQrAscii raw =
    let rows = filter (not . null) (map lineToModules (lines raw))
    in if null rows then Nothing else Just (map T.pack rows)

lineToModules :: String -> String
lineToModules [] = []
lineToModules chars =
    let (cell, rest) = splitAt 2 chars
        bit = if all isSpace cell then '0' else '1'
    in bit : lineToModules rest

boolAt :: [Text] -> Value -> Maybe Bool
boolAt [] (Bool value) = Just value
boolAt (key:rest) (Object obj) = KM.lookup (K.fromText key) obj >>= boolAt rest
boolAt _ _ = Nothing

urlEncode :: String -> String
urlEncode = concatMap encodeChar
  where
    encodeChar c
        | isAlphaNum c || c `elem` ("-_.~" :: String) = [c]
        | otherwise = printf "%%%02X" (ord c)

withTimeout :: String -> Int -> IO a -> IO a
withTimeout message micros action =
    timeout micros action >>= \case
        Nothing -> fail message
        Just value -> pure value

tryText :: IO a -> IO (Either String a)
tryText action = do
    result <- try action
    pure $ case result of
        Left (exc :: SomeException) -> Left (show exc)
        Right value -> Right value

firstLine :: String -> String
firstLine = take 160 . fromMaybe "" . safeHead . lines

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x:_) = Just x

logMsg :: String -> IO ()
logMsg msg = hPutStrLn stderr $ "[marketplace] " ++ msg
