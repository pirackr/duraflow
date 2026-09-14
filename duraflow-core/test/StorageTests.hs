{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module StorageTests (storageTests) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_, when)
import Data.Aeson (Value (String))
import qualified Data.ByteString as ByteString
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import Duraflow.Internal.Snapshot (decodeSnapshot)
import Duraflow.Internal.Storage
import Duraflow.Internal.Types
import System.Directory
  ( canonicalizePath
  , createDirectory
  , doesPathExist
  )
import System.FilePath ((</>))
import System.Posix.Files
  ( createNamedPipe
  , createSymbolicLink
  , fileID
  , fileMode
  , getFileStatus
  , intersectFileModes
  , ownerReadMode
  , ownerWriteMode
  , unionFileModes
  )
import System.Posix.IO (closeFd)
import TestSupport

data Event = Write | FileSync | Replace | DirectorySync deriving (Eq, Show)
data FailurePoint = FailWrite | FailFileSync | FailReplace | FailDirectorySync deriving (Eq, Show)

storageTests :: IO ()
storageTests = do
  runCase "commit, read, recover, and ignore leftovers" testBasicStorage
  runCase "storage transition ordering" testTransitionOrdering
  runCase "pre-replacement failures preserve old snapshot" testPreReplacementFailures
  runCase "primary write and sync failures survive close failure" testPrimaryFailurePrecedence
  runCase "post-replacement failure leaves new snapshot visible" testPostReplacementFailure
  runCase "recovery barriers report failures" testRecoveryFailures
  runCase "owner-only files and permanent lock inode" testModesAndPermanentLock
  runCase "unsafe snapshot and lock entries are rejected" testUnsafeEntries
  runCase "directory symlinks resolve to the same store" testDirectoryAlias
  runCase "execution lock is nonblocking" testBusyLock

testBasicStorage :: IO ()
testBasicStorage = withTestDirectory "basic-storage" $ \directory -> do
  let config = testConfig directory
      state = snapshot "old"
      leftover = directory </> "example-1.json.tmp.leftover"
  ByteString.writeFile leftover "not a snapshot"
  withExecutionStore productionStorageOps config $ \store -> do
    assertEqual "leftover ignored before canonical exists" Nothing =<< readSnapshot store
    commitSnapshot store state
    assertEqual "canonical snapshot" (Just state) =<< readSnapshot store
    recoverSnapshot store
  assertBool "leftover remains unrelated" =<< doesPathExist leftover

testTransitionOrdering :: IO ()
testTransitionOrdering = withTestDirectory "transition-order" $ \directory -> do
  events <- newIORef []
  let operations = recordingOps events Nothing
  withExecutionStore operations (testConfig directory) $ \store -> commitSnapshot store (snapshot "ordered")
  assertEqual "commit events" [Write, FileSync, Replace, DirectorySync] =<< readIORef events
  writeIORef events []
  withExecutionStore operations (testConfig directory) recoverSnapshot
  assertEqual "recovery events" [FileSync, DirectorySync] =<< readIORef events

testPreReplacementFailures :: IO ()
testPreReplacementFailures =
  forM_ [FailWrite, FailFileSync, FailReplace] $ \failure ->
    withTestDirectory ("failure-" <> show failure) $ \directory -> do
      let config = testConfig directory
          oldState = snapshot "old"
          newState = snapshot "new"
      withExecutionStore productionStorageOps config $ \store -> commitSnapshot store oldState
      events <- newIORef []
      replacementObservedOld <- newIORef False
      temporaryPath <- newIORef Nothing
      let base = recordingOps events (Just failure)
          operations = base
            { storageWrite = \path descriptor bytes -> do
                writeIORef temporaryPath (Just path)
                storageWrite base path descriptor bytes
            , storageReplace = \temporary canonical -> do
                visible <- decodeSnapshot <$> ByteString.readFile canonical
                writeIORef replacementObservedOld (visible == Right oldState)
                storageReplace base temporary canonical
            }
      assertStorageFailure (withExecutionStore operations config $ \store -> commitSnapshot store newState)
      withExecutionStore productionStorageOps config $ \store ->
        assertEqual ("old snapshot after " <> show failure) (Just oldState) =<< readSnapshot store
      maybeTemporary <- readIORef temporaryPath
      case maybeTemporary of
        Nothing -> pure ()
        Just path -> assertEqual "operation temporary cleaned" False =<< doesPathExist path
      when (failure == FailReplace) $ assertEqual "old complete snapshot visible before replacement" True =<< readIORef replacementObservedOld

testPrimaryFailurePrecedence :: IO ()
testPrimaryFailurePrecedence =
  forM_ [("write", True), ("synchronize", False)] $ \(operation, failDuringWrite) ->
    withTestDirectory ("primary-" <> operation) $ \directory -> do
      let config = testConfig directory
          oldState = snapshot "old"
          newState = snapshot "new"
          distinctive = operation <> " failed after closing descriptor"
      withExecutionStore productionStorageOps config $ \store -> commitSnapshot store oldState
      temporaryPath <- newIORef Nothing
      let base = productionStorageOps
          closeAndFail path descriptor = do
            writeIORef temporaryPath (Just path)
            closeFd descriptor
            ioError (userError distinctive)
          operations
            | failDuringWrite = base
                { storageWrite = \path descriptor _ -> closeAndFail path descriptor
                }
            | otherwise = base
                { storageWrite = \path descriptor bytes -> do
                    writeIORef temporaryPath (Just path)
                    storageWrite base path descriptor bytes
                , storageFileSync = closeAndFail
                }
      result <- try (withExecutionStore operations config $ \store -> commitSnapshot store newState)
      case result of
        Left (StorageFailure _ message) -> do
          assertBool "primary operation context retained" (Text.pack operation `Text.isPrefixOf` message)
          assertBool "distinctive primary failure retained" (Text.pack distinctive `Text.isInfixOf` message)
          assertBool "secondary close failure omitted" (not ("close temporary snapshot" `Text.isInfixOf` message))
        Left other -> assertBool ("expected StorageFailure, got " <> show other) False
        Right () -> assertBool "double failure unexpectedly succeeded" False
      withExecutionStore productionStorageOps config $ \store ->
        assertEqual "old snapshot survives double failure" (Just oldState) =<< readSnapshot store
      path <- maybe (throwIO (userError "temporary path was not captured")) pure =<< readIORef temporaryPath
      assertEqual "double failure temporary cleaned" False =<< doesPathExist path

testPostReplacementFailure :: IO ()
testPostReplacementFailure = withTestDirectory "post-replace" $ \directory -> do
  let config = testConfig directory
      oldState = snapshot "old"
      newState = snapshot "new"
  withExecutionStore productionStorageOps config $ \store -> commitSnapshot store oldState
  events <- newIORef []
  assertStorageFailure
    (withExecutionStore (recordingOps events (Just FailDirectorySync)) config $ \store -> commitSnapshot store newState)
  withExecutionStore productionStorageOps config $ \store ->
    assertEqual "new complete snapshot after directory sync failure" (Just newState) =<< readSnapshot store
  assertEqual "post-replacement sequence" [Write, FileSync, Replace, DirectorySync] =<< readIORef events

testRecoveryFailures :: IO ()
testRecoveryFailures =
  forM_ [FailFileSync, FailDirectorySync] $ \failure ->
    withTestDirectory ("recovery-" <> show failure) $ \directory -> do
      let config = testConfig directory
          state = snapshot "recover"
      withExecutionStore productionStorageOps config $ \store -> commitSnapshot store state
      events <- newIORef []
      assertStorageFailure (withExecutionStore (recordingOps events (Just failure)) config recoverSnapshot)
      expected <- pure $ case failure of
        FailFileSync -> [FileSync]
        FailDirectorySync -> [FileSync, DirectorySync]
        _ -> []
      assertEqual ("recovery failure events " <> show failure) expected =<< readIORef events
      withExecutionStore productionStorageOps config $ \store ->
        assertEqual "snapshot remains readable after recovery failure" (Just state) =<< readSnapshot store

testModesAndPermanentLock :: IO ()
testModesAndPermanentLock = withTestDirectory "modes" $ \directory -> do
  temporaryModeOk <- newIORef False
  let config = testConfig directory
      base = productionStorageOps
      checkingOps = base
        { storageWrite = \path descriptor bytes -> do
            mode <- privateMode path
            writeIORef temporaryModeOk mode
            storageWrite base path descriptor bytes
        }
      lockPath = directory </> "example-1.lock"
      snapshotPath = directory </> "example-1.json"
  withExecutionStore checkingOps config $ \store -> commitSnapshot store (snapshot "mode")
  assertEqual "temporary mode while writing" True =<< readIORef temporaryModeOk
  assertEqual "lock mode" True =<< privateMode lockPath
  assertEqual "snapshot mode" True =<< privateMode snapshotPath
  firstInode <- fileID <$> getFileStatus lockPath
  withExecutionStore productionStorageOps config (const (pure ()))
  secondInode <- fileID <$> getFileStatus lockPath
  assertEqual "permanent lock inode" firstInode secondInode

testUnsafeEntries :: IO ()
testUnsafeEntries = do
  forM_ ["snapshot", "lock"] $ \entry ->
    forM_ ["symlink", "directory", "fifo"] $ \kind ->
      withTestDirectory (entry <> "-" <> kind) $ \directory -> do
        let config = testConfig directory
            suffix = if entry == "snapshot" then ".json" else ".lock"
            path = directory </> ("example-1" <> suffix)
            target = directory </> "target"
        case kind of
          "symlink" -> do
            ByteString.writeFile target "target"
            createSymbolicLink target path
          "directory" -> createDirectory path
          "fifo" -> createNamedPipe path 0o600
          _ -> pure ()
        actionRan <- newIORef False
        assertStorageFailure (withExecutionStore productionStorageOps config (const (writeIORef actionRan True)))
        assertEqual "unsafe entry rejected before callback" False =<< readIORef actionRan

testDirectoryAlias :: IO ()
testDirectoryAlias = withTestDirectory "directory-alias" $ \outer -> do
  let realDirectory = outer </> "real"
      alias = outer </> "alias"
  createDirectory realDirectory
  createSymbolicLink realDirectory alias
  canonical <- canonicalizePath realDirectory
  withExecutionStore productionStorageOps (testConfig alias) $ \store -> do
    assertEqual "canonical state directory" canonical (stateDirectory (storeRunConfig store))
    commitSnapshot store (snapshot "alias")
  withExecutionStore productionStorageOps (testConfig realDirectory) $ \store ->
    assertEqual "alias snapshot shared" (Just (snapshot "alias")) =<< readSnapshot store

testBusyLock :: IO ()
testBusyLock = withTestDirectory "busy" $ \directory -> do
  let config = testConfig directory
      sid = executionId config
  withExecutionStore productionStorageOps config $ \_ -> do
    result <- try (withExecutionStore productionStorageOps config (const (pure ()))) :: IO (Either DuraflowError ())
    assertEqual "busy error" (Left (ExecutionBusy sid)) result

recordingOps :: IORef [Event] -> Maybe FailurePoint -> StorageOps
recordingOps events failure =
  StorageOps
    { storageWrite = \path descriptor bytes -> record Write FailWrite >> storageWrite productionStorageOps path descriptor bytes
    , storageFileSync = \path descriptor -> record FileSync FailFileSync >> storageFileSync productionStorageOps path descriptor
    , storageReplace = \temporary canonical -> record Replace FailReplace >> storageReplace productionStorageOps temporary canonical
    , storageDirectorySync = \directory -> record DirectorySync FailDirectorySync >> storageDirectorySync productionStorageOps directory
    }
 where
  record event point = do
    modifyIORef' events (<> [event])
    when (failure == Just point) (throwIO (userError ("injected " <> show point)))

assertStorageFailure :: IO () -> IO ()
assertStorageFailure action = do
  result <- try action :: IO (Either DuraflowError ())
  case result of
    Left (StorageFailure _ _) -> pure ()
    Left other -> assertEqual "storage error category" "StorageFailure" (show other)
    Right () -> assertBool "expected StorageFailure" False

privateMode :: FilePath -> IO Bool
privateMode path = do
  mode <- fileMode <$> getFileStatus path
  pure (mode `intersectFileModes` 0o777 == ownerReadMode `unionFileModes` ownerWriteMode)

testConfig :: FilePath -> RunConfig
testConfig directory = RunConfig directory (ExecutionId "example-1") "workflow" "1"

snapshot :: Text -> Snapshot
snapshot label = Snapshot (ExecutionId "example-1") "workflow" "1" (String label) False []
