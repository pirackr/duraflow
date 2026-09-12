{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Duraflow.Store where

import Control.Exception (IOException, bracket, catch, onException)
import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeFileStrict', encode)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, removeFile, renameFile)
import System.FileLock (SharedExclusive (Exclusive), withFileLock)
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.IO (hClose, openBinaryTempFile)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Unistd (fileSynchronise)

-- One document owns all metadata and completed outputs for a run.
data Run = Run
    { schemaVersion :: Int
    , runId :: Text
    , command :: [String]
    , workingDirectory :: FilePath
    , createdAt :: UTCTime
    , inputs :: Value
    , status :: Text
    , steps :: Map Text Value
    , attempts :: Map Text Int
    , result :: Value
    , lastError :: Maybe Text
    }
    deriving (Show, Generic)

instance ToJSON Run
instance FromJSON Run

initStore :: FilePath -> IO ()
initStore home = do
    -- Require an existing parent; persist the two directory creations as well.
    createDirectoryIfMissing False home
    createDirectoryIfMissing False (home </> "runs")
    syncPath (home </> "runs")
    syncPath home
    syncPath (takeDirectory home)

withStore :: FilePath -> IO a -> IO a
withStore home action = withFileLock (home </> "store.lock") Exclusive (const action)

runPath :: FilePath -> Text -> FilePath
runPath home ident = home </> "runs" </> T.unpack ident ++ ".json"

readRun :: FilePath -> IO Run
readRun path = do
    decoded <- eitherDecodeFileStrict' path
    run <- either (ioError . userError . (("Invalid run " ++ path ++ ": ") ++)) pure decoded
    unless
        ( schemaVersion run == 1
            && not (null (command run))
            && status run `elem` ["pending", "running", "failed", "completed"]
            && takeBaseName path == T.unpack (runId run)
        )
        $ ioError (userError ("Unsupported or corrupt run: " ++ path))
    pure run

saveRun :: FilePath -> Run -> IO ()
saveRun home run = withStore home (publish (runPath home (runId run)) run)

-- Caller holds store.lock. Never replace or remove the stable lock files.
-- A failure after rename is an uncertain publication, not a rollback.
publish :: (ToJSON a) => FilePath -> a -> IO ()
publish path value = do
    let directory = takeDirectory path
    (tmp, handle) <- openBinaryTempFile directory ".run.tmp"
    let cleanup = do
            hClose handle `catch` ignoreIO
            removeFile tmp `catch` ignoreIO
    ( do
            BL.hPut handle (encode value)
            hClose handle
            syncPath tmp
            renameFile tmp path
            syncPath directory
        )
        `onException` cleanup

syncPath :: FilePath -> IO ()
syncPath path = bracket (openFd path ReadOnly defaultFileFlags) closeFd fileSynchronise

ignoreIO :: IOException -> IO ()
ignoreIO _ = pure ()
