{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Duraflow.Internal.Storage
  ( Store
  , StorageOps (..)
  , withExecutionStore
  , readSnapshot
  , commitSnapshot
  , recoverSnapshot
  , storeRunConfig
  , productionStorageOps
  ) where

import Control.Exception
  ( IOException
  , bracket
  , catch
  , displayException
  , evaluate
  , finally
  , mask
  , onException
  , throwIO
  )
import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Duraflow.Internal.Snapshot (decodeSnapshot, encodeSnapshot)
import Duraflow.Internal.Types
import System.Directory (canonicalizePath, removeFile)
import System.FileLock (FileLock, SharedExclusive (Exclusive), tryLockFile, unlockFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , ownerReadMode
  , ownerWriteMode
  , rename
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import qualified System.Posix.IO.ByteString as PosixByteString
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd)
import qualified System.Posix.Types
import System.Posix.Unistd (fileSynchronise)

-- | Filesystem transitions are injectable only through this internal module.
data StorageOps = StorageOps
  { storageWrite :: FilePath -> Fd -> ByteString.ByteString -> IO ()
  , storageFileSync :: FilePath -> Fd -> IO ()
  , storageReplace :: FilePath -> FilePath -> IO ()
  , storageDirectorySync :: FilePath -> IO ()
  }

data Store = Store
  { storeOperations :: StorageOps
  , storeRunConfig :: RunConfig
  , storeSnapshotPath :: FilePath
  }

withExecutionStore :: StorageOps -> RunConfig -> (Store -> IO a) -> IO a
withExecutionStore operations suppliedConfig callback = mask $ \restore -> do
  case validateRunConfig suppliedConfig of
    Left message -> throwIO (InvalidConfiguration message)
    Right () -> pure ()
  let eid = executionId suppliedConfig
  canonicalDirectory <- storageIO eid "canonicalize state directory" (canonicalizePath (stateDirectory suppliedConfig))
  directoryStatus <- storageIO eid "inspect state directory" (getFileStatus canonicalDirectory)
  unless (isDirectory directoryStatus) $ throwIO (InvalidConfiguration "state directory is not a directory")
  let canonicalConfig = suppliedConfig {stateDirectory = canonicalDirectory}
      stem = Text.unpack (executionIdText eid)
      snapshotPath = canonicalDirectory <> "/" <> stem <> ".json"
      lockPath = canonicalDirectory <> "/" <> stem <> ".lock"
      store = Store operations canonicalConfig snapshotPath
  ensureSafeEntry eid "snapshot" snapshotPath
  provisionLock eid lockPath
  acquired <- storageIO eid "acquire execution lock" (tryLockFile lockPath Exclusive)
  case acquired of
    Nothing -> throwIO (ExecutionBusy eid)
    Just executionLock -> restore (callback store) `finally` releaseLock eid executionLock

readSnapshot :: Store -> IO (Maybe Snapshot)
readSnapshot Store {storeRunConfig = config, storeSnapshotPath} = do
  let eid = executionId config
  status <- entryStatus eid "snapshot" storeSnapshotPath
  case status of
    Nothing -> pure Nothing
    Just _ -> do
      bytes <- storageIO eid "read snapshot" (ByteString.readFile storeSnapshotPath)
      case decodeSnapshot bytes of
        Left message -> throwIO (InvalidState eid message)
        Right snapshot -> pure (Just snapshot)

commitSnapshot :: Store -> Snapshot -> IO ()
commitSnapshot Store {storeOperations, storeRunConfig = config, storeSnapshotPath} snapshot = mask $ \_ -> do
  let eid = executionId config
      bytes = encodeSnapshot snapshot
  _ <- evaluate (ByteString.length bytes)
  validated <- case decodeSnapshot bytes of
    Left message -> throwIO (InvalidState eid message)
    Right value -> pure value
  unless (snapshotExecutionId validated == eid) $
    throwIO (InvalidState eid "snapshot execution ID does not match its store")
  (temporaryPath, descriptor) <- storageIO eid "create temporary snapshot" (createTemporary config)
  let removeTemporary = ignoreIOException (removeFile temporaryPath)
      writeAndClose =
        (do
          storageIO eid "write temporary snapshot" (storageWrite storeOperations temporaryPath descriptor bytes)
          storageIO eid "synchronize temporary snapshot" (storageFileSync storeOperations temporaryPath descriptor)
        ) `finally` storageIO eid "close temporary snapshot" (closeFd descriptor)
      transition = do
        writeAndClose
        storageIO eid "replace snapshot" (storageReplace storeOperations temporaryPath storeSnapshotPath)
        storageIO eid "synchronize snapshot directory" (storageDirectorySync storeOperations (stateDirectory config))
  transition `onException` removeTemporary

recoverSnapshot :: Store -> IO ()
recoverSnapshot Store {storeOperations, storeRunConfig = config, storeSnapshotPath} = mask $ \_ -> do
  let eid = executionId config
  status <- entryStatus eid "snapshot" storeSnapshotPath
  case status of
    Nothing -> pure ()
    Just _ -> do
      bracket
        (storageIO eid "open snapshot for recovery" (openFd storeSnapshotPath ReadOnly recoveryFlags))
        (storageIO eid "close recovered snapshot" . closeFd)
        (\descriptor -> storageIO eid "synchronize recovered snapshot" (storageFileSync storeOperations storeSnapshotPath descriptor))
      storageIO eid "synchronize recovered directory" (storageDirectorySync storeOperations (stateDirectory config))

productionStorageOps :: StorageOps
productionStorageOps = StorageOps
  { storageWrite = \_ -> writeAll
  , storageFileSync = \_ -> fileSynchronise
  , storageReplace = rename
  , storageDirectorySync = synchronizeDirectory
  }

provisionLock :: ExecutionId -> FilePath -> IO ()
provisionLock eid path = do
  existing <- entryStatus eid "lock" path
  case existing of
    Just _ -> pure ()
    Nothing -> do
      opened <- (Right <$> openFd path ReadWrite creationFlags) `catch` handleCreationRace
      case opened of
        Left () -> ensureSafeEntry eid "lock" path
        Right descriptor -> bracket
          (pure descriptor)
          (storageIO eid "close execution lock" . closeFd)
          (\fd -> storageIO eid "set execution lock mode" (setFdMode fd privateMode))
 where
  handleCreationRace :: IOException -> IO (Either () Fd)
  handleCreationRace exception
    | isAlreadyExistsError exception = pure (Left ())
    | otherwise = throwIO (StorageFailure eid ("create execution lock: " <> Text.pack (displayException exception)))

ensureSafeEntry :: ExecutionId -> Text -> FilePath -> IO ()
ensureSafeEntry eid label path = do
  _ <- entryStatus eid label path
  pure ()

entryStatus :: ExecutionId -> Text -> FilePath -> IO (Maybe FileStatus)
entryStatus eid label path = do
  result <- (Right <$> getSymbolicLinkStatus path) `catch` missing
  case result of
    Left () -> pure Nothing
    Right status
      | isRegularFile status -> pure (Just status)
      | otherwise -> throwIO (StorageFailure eid (label <> " entry is not a regular file"))
 where
  missing :: IOException -> IO (Either () FileStatus)
  missing exception
    | isDoesNotExistError exception = pure (Left ())
    | otherwise = throwIO (StorageFailure eid ("inspect " <> label <> " entry: " <> Text.pack (displayException exception)))

createTemporary :: RunConfig -> IO (FilePath, Fd)
createTemporary config = do
  process <- getProcessID
  tryCandidate process (0 :: Int)
 where
  tryCandidate process sequenceNumber = do
    let ExecutionId eid = executionId config
        name = Text.unpack eid <> ".json.tmp." <> show process <> "." <> show sequenceNumber
        path = stateDirectory config <> "/" <> name
    opened <- (Right <$> openFd path WriteOnly creationFlags) `catch` alreadyExists
    case opened of
      Left () -> tryCandidate process (sequenceNumber + 1)
      Right descriptor ->
        (setFdMode descriptor privateMode >> pure (path, descriptor))
          `onException` (ignoreIOException (closeFd descriptor) >> ignoreIOException (removeFile path))
  alreadyExists :: IOException -> IO (Either () Fd)
  alreadyExists exception
    | isAlreadyExistsError exception = pure (Left ())
    | otherwise = throwIO exception

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll descriptor bytes = do
  count <- PosixByteString.fdWrite descriptor bytes
  if count == 0
    then ioError (userError "snapshot write made no progress")
    else writeAll descriptor (ByteString.drop (fromIntegral count) bytes)

synchronizeDirectory :: FilePath -> IO ()
synchronizeDirectory path = bracket
  (openFd path ReadOnly directoryFlags)
  closeFd
  fileSynchronise

releaseLock :: ExecutionId -> FileLock -> IO ()
releaseLock eid = storageIO eid "release execution lock" . unlockFile

storageIO :: ExecutionId -> Text -> IO a -> IO a
storageIO eid operation action = action `catch` handleFilesystemError
 where
  handleFilesystemError :: IOException -> IO a
  handleFilesystemError exception =
    throwIO (StorageFailure eid (operation <> ": " <> Text.pack (displayException exception)))

ignoreIOException :: IO () -> IO ()
ignoreIOException action = action `catch` handler
 where
  handler :: IOException -> IO ()
  handler _ = pure ()

executionIdText :: ExecutionId -> Text
executionIdText (ExecutionId value) = value

privateMode :: System.Posix.Types.FileMode
privateMode = ownerReadMode `unionFileModes` ownerWriteMode

creationFlags :: OpenFileFlags
creationFlags = defaultFileFlags
  { creat = Just privateMode
  , exclusive = True
  , nofollow = True
  , cloexec = True
  }

recoveryFlags :: OpenFileFlags
recoveryFlags = defaultFileFlags {nofollow = True, cloexec = True}

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags {nofollow = True, cloexec = True, directory = True}
