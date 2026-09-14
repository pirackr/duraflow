{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module ProcessTests
  ( childMain
  , processTests
  ) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Control.Monad (forM_, when)
import Data.Aeson (toJSON)
import qualified Data.ByteString as ByteString
import Data.IORef
import qualified Data.Text as Text
import Duraflow
import Duraflow.Internal.Runtime (runWorkflowWith)
import Duraflow.Internal.Snapshot (decodeSnapshot)
import Duraflow.Internal.Storage
import Duraflow.Internal.Types (Snapshot (..), TaskRecord (..), TaskStatus (..))
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), Handle, hFlush, hGetLine, hPutStrLn, hSetBuffering, stdout)
import System.Process
  ( CreateProcess (std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
  )
import TestSupport

processTests :: IO ()
processTests = do
  runCase "process locks reject same ID and allow different IDs" testProcessLocks
  runCase "killed Running task resumes and keeps complete canonical JSON" testKilledResume
  runCase "asynchronous cancellation releases lock and is not saved Failed" testCancellation
  runCase "injected Running commits gate actions at every phase" testRunningCommitFailures
  runCase "injected Success commits gate dependent actions at every phase" testSuccessCommitFailures
  runCase "injected Failed commits preserve task failure context" testFailedCommitFailures
  runCase "failed success commit repeats an external effect on rerun" testRepeatedEffect
  runCase "recovery barrier failures prevent replay and new actions" testRecoveryBarrierFailures

childMain :: [String] -> IO ()
childMain [mode, directory, identifier] = do
  hSetBuffering stdout LineBuffering
  let config = RunConfig directory (ExecutionId (Text.pack identifier)) "process-workflow" "1"
  case mode of
    "hold" -> do
      _ <- runWorkflow config () $ \() -> task (TaskId "hold") () $ \() -> do
        putStrLn "ACTION_STARTED"
        _ <- getLine
        pure ()
      putStrLn "DONE"
    "attempt" -> do
      result <- try $ runWorkflow config () $ \() -> task (TaskId "hold") () $ \() -> putStrLn "ACTION_STARTED"
      case result of
        Left ExecutionBusy {} -> putStrLn "BUSY"
        Left errorValue -> throwIO (errorValue :: DuraflowError)
        Right () -> putStrLn "DONE"
    "kill-run" -> do
      let effects = directory </> "effects.log"
      _ <- runWorkflow config () $ \() -> do
        _ <- task (TaskId "one") () (\() -> appendFile effects "one\n")
        task (TaskId "two") () $ \() -> do
          appendFile effects "two\n"
          putStrLn "ACTION_STARTED"
          _ <- getLine
          pure ()
      putStrLn "DONE"
    _ -> fail ("unknown child mode: " <> mode)
childMain _ = fail "invalid child arguments"

testProcessLocks :: IO ()
testProcessLocks = withTestDirectory "process-locks" $ \directory -> do
  holder <- spawnChild "hold" directory "shared"
  assertEqual "holder handshake" "ACTION_STARTED" =<< childLine holder
  contender <- spawnChild "attempt" directory "shared"
  assertEqual "same execution reports busy" "BUSY" =<< childLine contender
  assertEqual "busy child exits" ExitSuccess =<< childExit contender
  independent <- spawnChild "attempt" directory "independent"
  assertEqual "different execution action starts" "ACTION_STARTED" =<< childLine independent
  assertEqual "different execution completes" "DONE" =<< childLine independent
  assertEqual "independent child exits" ExitSuccess =<< childExit independent
  continueChild holder
  assertEqual "holder completes" "DONE" =<< childLine holder
  assertEqual "holder exits" ExitSuccess =<< childExit holder

testKilledResume :: IO ()
testKilledResume = withTestDirectory "process-kill" $ \directory -> do
  child <- spawnChild "kill-run" directory "killed"
  assertEqual "kill handshake after Running commit" "ACTION_STARTED" =<< childLine child
  terminateProcess (childProcess child)
  _ <- childExit child
  bytes <- ByteString.readFile (directory </> "killed.json")
  snapshot <- case decodeSnapshot bytes of
    Left message -> throwIO (userError (Text.unpack message))
    Right value -> pure value
  assertEqual "killed snapshot remains complete" [Success (toJSON ()), Running] (map recordStatus (snapshotTasks snapshot))
  let effects = directory </> "effects.log"
      config = RunConfig directory (ExecutionId "killed") "process-workflow" "1"
  _ <- runWorkflow config () $ \() -> do
    _ <- task (TaskId "one") () (\() -> appendFile effects "one\n")
    task (TaskId "two") () (\() -> appendFile effects "two\n")
  assertEqual "completed task skipped and Running task repeated" ["one", "two", "two"] . lines =<< readFile effects

testCancellation :: IO ()
testCancellation = withTestDirectory "runtime-cancel" $ \directory -> do
  started <- newEmptyMVar
  blocked <- newEmptyMVar
  finished <- newEmptyMVar
  let config = RunConfig directory (ExecutionId "cancelled") "process-workflow" "1"
      flow () = task (TaskId "cancel") () $ \() -> putMVar started () >> takeMVar blocked
  thread <- forkIO $ do
    result <- try (runWorkflow config () flow) :: IO (Either SomeException ())
    putMVar finished result
  within "cancel action starts" (takeMVar started)
  throwTo thread ThreadKilled
  result <- within "cancel invocation exits" (takeMVar finished)
  case result of
    Left exception -> assertBool "ThreadKilled propagates" (show exception == "thread killed")
    Right () -> assertBool "cancellation unexpectedly succeeded" False
  snapshot <- readRuntimeSnapshot directory "cancelled"
  assertEqual "cancellation remains Running" [Running] (map recordStatus (snapshotTasks snapshot))
  rerunCalls <- newIORef (0 :: Int)
  _ <- runWorkflow config () (\() -> task (TaskId "cancel") () (\() -> modifyIORef' rerunCalls (+ 1)))
  assertEqual "lock released and Running retried" 1 =<< readIORef rerunCalls

testRunningCommitFailures :: IO ()
testRunningCommitFailures =
  forM_ storageSteps $ \step -> withTestDirectory ("inject-running-" <> show step) $ \directory -> do
    let config = injectedConfig directory
    seedSnapshot config []
    actions <- newIORef (0 :: Int)
    operations <- failingTransitionOps RunningTransition step
    assertStorageError ("Running " <> show step) $
      runWorkflowWith operations config () (\() -> task (TaskId "one") () (\() -> modifyIORef' actions (+ 1)))
    assertEqual "action gated by Running commit" 0 =<< readIORef actions

testSuccessCommitFailures :: IO ()
testSuccessCommitFailures =
  forM_ storageSteps $ \step -> withTestDirectory ("inject-success-" <> show step) $ \directory -> do
    let config = injectedConfig directory
    seedSnapshot config []
    firstCalls <- newIORef (0 :: Int)
    dependentCalls <- newIORef (0 :: Int)
    operations <- failingTransitionOps SuccessTransition step
    assertStorageError ("Success " <> show step) $
      runWorkflowWith operations config () $ \() -> do
        _ <- task (TaskId "one") () (\() -> modifyIORef' firstCalls (+ 1))
        task (TaskId "two") () (\() -> modifyIORef' dependentCalls (+ 1))
    assertEqual "effect happened before failed success commit" 1 =<< readIORef firstCalls
    assertEqual "dependent action gated by success commit" 0 =<< readIORef dependentCalls

testFailedCommitFailures :: IO ()
testFailedCommitFailures =
  forM_ storageSteps $ \step -> withTestDirectory ("inject-failed-" <> show step) $ \directory -> do
    let config = injectedConfig directory
    seedSnapshot config []
    operations <- failingTransitionOps FailedTransition step
    result <- try $ runWorkflowWith operations config () $ \() ->
      task (TaskId "one") () (\() -> throwIO (userError "original task context") :: IO ())
    case result of
      Left (StorageFailure _ message) ->
        assertBool "storage error retains original failure" ("original task context" `Text.isInfixOf` message)
      Left other -> assertBool ("expected StorageFailure, got " <> show other) False
      Right _ -> assertBool "failed recording unexpectedly succeeded" False

testRepeatedEffect :: IO ()
testRepeatedEffect = withTestDirectory "inject-repeat" $ \directory -> do
  let config = injectedConfig directory
  seedSnapshot config []
  effects <- newIORef (0 :: Int)
  operations <- failingTransitionOps SuccessTransition ReplaceStep
  assertStorageError "failed success replacement" $
    runWorkflowWith operations config () (\() -> task (TaskId "one") () (\() -> modifyIORef' effects (+ 1)))
  _ <- runWorkflow config () (\() -> task (TaskId "one") () (\() -> modifyIORef' effects (+ 1)))
  assertEqual "effect repeats after uncommitted success" 2 =<< readIORef effects

testRecoveryBarrierFailures :: IO ()
testRecoveryBarrierFailures =
  forM_ [FileSyncStep, DirectorySyncStep] $ \step -> withTestDirectory ("inject-recovery-" <> show step) $ \directory -> do
    let config = injectedConfig directory
        saved = TaskRecord (TaskId "one") (toJSON ()) (Success (toJSON (7 :: Int)))
    seedSnapshot config [saved]
    cachedContinuation <- newIORef (0 :: Int)
    newActions <- newIORef (0 :: Int)
    operations <- failingRecoveryOps step
    assertStorageError ("recovery " <> show step) $
      runWorkflowWith operations config () $ \() -> do
        value <- task (TaskId "one") () (\() -> modifyIORef' cachedContinuation (+ 100) >> pure (7 :: Int))
        when (value == 7) (pure ())
        task (TaskId "two") () (\() -> modifyIORef' newActions (+ 1))
    assertEqual "cached task action not rerun" 0 =<< readIORef cachedContinuation
    assertEqual "new action blocked by recovery" 0 =<< readIORef newActions

data Child = Child
  { childInput :: Handle
  , childOutput :: Handle
  , childProcess :: ProcessHandle
  }

spawnChild :: String -> FilePath -> String -> IO Child
spawnChild mode directory identifier = do
  executable <- getExecutablePath
  (Just inputHandle, Just outputHandle, _, processHandle) <-
    createProcess (proc executable ["--child", mode, directory, identifier])
      {std_in = CreatePipe, std_out = CreatePipe}
  hSetBuffering inputHandle LineBuffering
  pure Child {childInput = inputHandle, childOutput = outputHandle, childProcess = processHandle}

childLine :: Child -> IO String
childLine child = within "child output" (hGetLine (childOutput child))

continueChild :: Child -> IO ()
continueChild child = hPutStrLn (childInput child) "continue" >> hFlush (childInput child)

childExit :: Child -> IO ExitCode
childExit child = within "child exit" (waitForProcess (childProcess child))

data Transition = RunningTransition | SuccessTransition | FailedTransition deriving (Eq, Show)
data StorageStep = WriteStep | FileSyncStep | ReplaceStep | DirectorySyncStep deriving (Eq, Show)

storageSteps :: [StorageStep]
storageSteps = [WriteStep, FileSyncStep, ReplaceStep, DirectorySyncStep]

failingTransitionOps :: Transition -> StorageStep -> IO StorageOps
failingTransitionOps target targetStep = do
  active <- newIORef Nothing
  let base = productionStorageOps
      shouldFail step = do
        transition <- readIORef active
        when (transition == Just target && step == targetStep) (throwIO (userError ("injected " <> show target <> " " <> show step)))
  pure base
    { storageWrite = \path descriptor bytes -> do
        writeIORef active (classifyTransition bytes)
        shouldFail WriteStep
        storageWrite base path descriptor bytes
    , storageFileSync = \path descriptor -> shouldFail FileSyncStep >> storageFileSync base path descriptor
    , storageReplace = \temporary canonical -> shouldFail ReplaceStep >> storageReplace base temporary canonical
    , storageDirectorySync = \path -> shouldFail DirectorySyncStep >> storageDirectorySync base path
    }

failingRecoveryOps :: StorageStep -> IO StorageOps
failingRecoveryOps target = do
  writes <- newIORef False
  let base = productionStorageOps
      failBeforeWrite step = do
        transitionStarted <- readIORef writes
        when (not transitionStarted && step == target) (throwIO (userError ("injected recovery " <> show step)))
  pure base
    { storageWrite = \path descriptor bytes -> writeIORef writes True >> storageWrite base path descriptor bytes
    , storageFileSync = \path descriptor -> failBeforeWrite FileSyncStep >> storageFileSync base path descriptor
    , storageDirectorySync = \path -> failBeforeWrite DirectorySyncStep >> storageDirectorySync base path
    }

classifyTransition :: ByteString.ByteString -> Maybe Transition
classifyTransition bytes = case decodeSnapshot bytes of
  Left _ -> Nothing
  Right snapshot -> case reverse (snapshotTasks snapshot) of
    TaskRecord _ _ Running : _ -> Just RunningTransition
    TaskRecord _ _ Success {} : _ -> Just SuccessTransition
    TaskRecord _ _ Failed {} : _ -> Just FailedTransition
    [] -> Nothing

injectedConfig :: FilePath -> RunConfig
injectedConfig directory = RunConfig directory (ExecutionId "injected") "workflow" "1"

seedSnapshot :: RunConfig -> [TaskRecord] -> IO ()
seedSnapshot config records =
  withExecutionStore productionStorageOps config $ \store ->
    commitSnapshot store Snapshot
      { snapshotExecutionId = executionId config
      , snapshotWorkflowName = workflowName config
      , snapshotWorkflowVersion = workflowVersion config
      , snapshotWorkflowInput = toJSON ()
      , snapshotCompleted = False
      , snapshotTasks = records
      }

readRuntimeSnapshot :: FilePath -> String -> IO Snapshot
readRuntimeSnapshot directory identifier = do
  bytes <- ByteString.readFile (directory </> identifier <> ".json")
  case decodeSnapshot bytes of
    Left message -> throwIO (userError (Text.unpack message))
    Right snapshot -> pure snapshot

assertStorageError :: String -> IO a -> IO ()
assertStorageError label action = do
  result <- try action
  case result of
    Left StorageFailure {} -> pure ()
    Left other -> assertBool (label <> ": expected StorageFailure, got " <> show (other :: DuraflowError)) False
    Right _ -> assertBool (label <> ": expected failure") False
