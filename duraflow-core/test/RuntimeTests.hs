{-# LANGUAGE OverloadedStrings #-}

module RuntimeTests (runtimeTests) where

import Control.Exception (SomeException, displayException, fromException, throwIO, try)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , object
  , (.=)
  )
import qualified Data.ByteString as ByteString
import Data.IORef
import qualified Data.Text as Text
import Duraflow
import Duraflow.Internal.Snapshot (decodeSnapshot)
import Duraflow.Internal.Types (Snapshot (..), TaskRecord (..), TaskStatus (..))
import System.FilePath ((</>))
import TestSupport

runtimeTests :: IO ()
runtimeTests = do
  runCase "successful tasks replay without rerunning actions" testSuccessfulReplay
  runCase "failed task retries while prior success is replayed" testFailureRetry
  runCase "metadata and workflow input mismatches run no actions" testIdentityMismatch
  runCase "task ID, order, and input replay mismatches run no actions" testTaskReplayMismatch
  runCase "invalid and duplicate invocation task IDs run no duplicate action" testInvocationIds
  runCase "corrupt, unknown, and invalid snapshots run no actions" testInvalidSnapshots
  runCase "undecodable saved success runs no action" testUndecodableSuccess
  runCase "completed histories reject appended tasks" testCompletedAppend
  runCase "normal shortened orchestration is rejected" testShortenedWorkflow
  runCase "orchestration exceptions are not replaced by replay validation" testOrchestrationException
  runCase "zero tasks persist and replay completion" testZeroTasks
  runCase "application output needs no ToJSON instance" testApplicationOutput
  runCase "workflow JSON object input comparison ignores key order" testStructuralInput
  runCase "input encoding exceptions are not task failures" testInputEncodingFailures
  runCase "task output encoding failures are recorded as failures" testOutputEncodingFailure

testSuccessfulReplay :: IO ()
testSuccessfulReplay = withTestDirectory "runtime-success" $ \directory -> do
  calls <- newIORef (0 :: Int)
  let config = testConfig directory "success"
      flow () = do
        first <- task (TaskId "one") () (\() -> modifyIORef' calls (+ 1) >> pure (7 :: Int))
        task (TaskId "two") first (\number -> pure (number + 1))
  first <- runWorkflow config () flow
  saved <- readStoredSnapshot config
  assertEqual "successful snapshot completed" True (snapshotCompleted saved)
  assertEqual "successful snapshot statuses" 2 (length [() | TaskRecord _ _ Success {} <- snapshotTasks saved])
  second <- runWorkflow config () flow
  assertEqual "workflow result" (8, 8) (first, second)
  assertEqual "successful action skipped" 1 =<< readIORef calls

testFailureRetry :: IO ()
testFailureRetry = withTestDirectory "runtime-failure" $ \directory -> do
  oneCalls <- newIORef (0 :: Int)
  twoCalls <- newIORef (0 :: Int)
  thirdMarkers <- newIORef ([] :: [String])
  failTwo <- newIORef True
  let config = testConfig directory "failure"
      flow () = do
        first <- task (TaskId "one") () $ \() -> modifyIORef' oneCalls (+ 1) >> pure (7 :: Int)
        second <- task (TaskId "two") first $ \number -> do
          modifyIORef' twoCalls (+ 1)
          shouldFail <- atomicModifyIORef' failTwo (\value -> (False, value))
          if shouldFail then throwIO (userError "task two failed") else pure (number + 1)
        task (TaskId "three") second $ \number -> modifyIORef' thirdMarkers (<> ["ran"]) >> pure (number + 1)
  firstAttempt <- try (runWorkflow config () flow) :: IO (Either DuraflowError Int)
  assertTaskFailure "first task-two attempt" firstAttempt
  failedSnapshot <- readStoredSnapshot config
  assertEqual "failure snapshot incomplete" False (snapshotCompleted failedSnapshot)
  assertEqual "failure snapshot statuses" ["Success", "Failed"] (map statusName (snapshotTasks failedSnapshot))
  assertEqual "third task does not run after failure" [] =<< readIORef thirdMarkers
  result <- runWorkflow config () flow
  assertEqual "retry result" 9 result
  assertEqual "task one replayed" 1 =<< readIORef oneCalls
  assertEqual "task two tried once per invocation" 2 =<< readIORef twoCalls
  assertEqual "task three runs after retry" ["ran"] =<< readIORef thirdMarkers

testIdentityMismatch :: IO ()
testIdentityMismatch = withTestDirectory "runtime-identity" $ \directory -> do
  let config = testConfig directory "identity"
  _ <- runWorkflow config (object ["a" .= (1 :: Int)]) oneTask
  calls <- newIORef (0 :: Int)
  let counted value = task (TaskId "one") value (\number -> modifyIORef' calls (+ 1) >> pure number)
      changedName = config {workflowName = "other"}
  assertErrorCategory "metadata mismatch" isExecutionMismatch (runWorkflow changedName (object ["a" .= (1 :: Int)]) counted)
  assertErrorCategory "input mismatch" isExecutionMismatch (runWorkflow config (object ["a" .= (2 :: Int)]) counted)
  assertEqual "identity mismatch action count" 0 =<< readIORef calls
 where
  oneTask value = task (TaskId "one") value pure

testTaskReplayMismatch :: IO ()
testTaskReplayMismatch = withTestDirectory "runtime-task-mismatch" $ \directory -> do
  let config = testConfig directory "task-mismatch"
      original () = do
        _ <- task (TaskId "one") (1 :: Int) pure
        task (TaskId "two") (2 :: Int) pure
  _ <- runWorkflow config () original
  calls <- newIORef (0 :: Int)
  let counted taskId value = task taskId value (\number -> modifyIORef' calls (+ 1) >> pure number)
      changedId () = counted (TaskId "changed") (1 :: Int)
      changedOrder () = counted (TaskId "two") (2 :: Int)
      changedInput () = counted (TaskId "one") (9 :: Int)
  mapM_ (\(name, flow) -> assertErrorCategory name isReplayMismatch (runWorkflow config () flow))
    [("changed ID", changedId), ("changed order", changedOrder), ("changed input", changedInput)]
  assertEqual "replay mismatch action count" 0 =<< readIORef calls

testInvocationIds :: IO ()
testInvocationIds = withTestDirectory "runtime-invocation-ids" $ \directory -> do
  invalidCalls <- newIORef (0 :: Int)
  assertErrorCategory "invalid task ID" isReplayMismatch $
    runWorkflow (testConfig directory "invalid-id") () $ \() ->
      task (TaskId " ") () (\() -> modifyIORef' invalidCalls (+ 1))
  assertEqual "invalid ID action count" 0 =<< readIORef invalidCalls
  duplicateCalls <- newIORef (0 :: Int)
  assertErrorCategory "duplicate task ID" isReplayMismatch $
    runWorkflow (testConfig directory "duplicate-id") () $ \() -> do
      _ <- task (TaskId "same") () (\() -> modifyIORef' duplicateCalls (+ 1))
      task (TaskId "same") () (\() -> modifyIORef' duplicateCalls (+ 1))
  assertEqual "only first duplicate action runs" 1 =<< readIORef duplicateCalls

testInvalidSnapshots :: IO ()
testInvalidSnapshots = do
  check "malformed" "{"
  check "unknown-schema" "{\"schemaVersion\":2}"
  check "invalid-history" invalidHistory
 where
  check suffix bytes = withTestDirectory ("runtime-" <> suffix) $ \directory -> do
    let config = testConfig directory suffix
        path = directory </> executionStem config <> ".json"
    ByteString.writeFile path bytes
    calls <- newIORef (0 :: Int)
    assertErrorCategory suffix isInvalidState $
      runWorkflow config () (\() -> task (TaskId "action") () (\() -> modifyIORef' calls (+ 1)))
    assertEqual (suffix <> " action count") 0 =<< readIORef calls
  invalidHistory =
    "{\"schemaVersion\":1,\"executionId\":\"runtime-invalid-history\",\"workflowName\":\"workflow\",\"workflowVersion\":\"1\",\"workflowInput\":[],\"completed\":false,\"tasks\":[{\"taskId\":\"one\",\"input\":[],\"status\":\"Running\"},{\"taskId\":\"two\",\"input\":[],\"status\":\"Success\",\"output\":1}]}"

testUndecodableSuccess :: IO ()
testUndecodableSuccess = withTestDirectory "runtime-decode" $ \directory -> do
  let config = testConfig directory "decode"
  _ <- runWorkflow config () (\() -> task (TaskId "one") () (\() -> pure (1 :: Int)))
  calls <- newIORef (0 :: Int)
  assertErrorCategory "undecodable output" isReplayMismatch $
    runWorkflow config () (\() -> task (TaskId "one") () (\() -> modifyIORef' calls (+ 1) >> pure True))
  assertEqual "undecodable action count" 0 =<< readIORef calls

testCompletedAppend :: IO ()
testCompletedAppend = withTestDirectory "runtime-completed-append" $ \directory -> do
  let config = testConfig directory "completed-append"
  _ <- runWorkflow config () (\() -> task (TaskId "one") () pure)
  calls <- newIORef (0 :: Int)
  assertErrorCategory "completed append" isReplayMismatch $
    runWorkflow config () $ \() -> do
      _ <- task (TaskId "one") () (\() -> modifyIORef' calls (+ 1))
      task (TaskId "two") () (\() -> modifyIORef' calls (+ 1))
  assertEqual "completed append action count" 0 =<< readIORef calls

testShortenedWorkflow :: IO ()
testShortenedWorkflow = withTestDirectory "runtime-shortened" $ \directory -> do
  let config = testConfig directory "shortened"
      full () = task (TaskId "one") () pure >> task (TaskId "two") () pure
  _ <- runWorkflow config () full
  calls <- newIORef (0 :: Int)
  assertErrorCategory "shortened workflow" isReplayMismatch $
    runWorkflow config () (\() -> task (TaskId "one") () (\() -> modifyIORef' calls (+ 1)))
  assertEqual "shortened action count" 0 =<< readIORef calls

testOrchestrationException :: IO ()
testOrchestrationException = withTestDirectory "runtime-orchestration-error" $ \directory -> do
  let config = testConfig directory "orchestration-error"
      full () = task (TaskId "one") () pure >> task (TaskId "two") () pure
  _ <- runWorkflow config () full
  result <- try $ runWorkflow config () $ \() -> do
    _ <- task (TaskId "one") () pure
    error "outside orchestration"
  case result of
    Left exception -> assertBool "original orchestration exception" ("outside orchestration" `Text.isInfixOf` Text.pack (displayException (exception :: SomeException)))
    Right _ -> assertBool "orchestration exception expected" False

testZeroTasks :: IO ()
testZeroTasks = withTestDirectory "runtime-zero" $ \directory -> do
  let config = testConfig directory "zero"
  assertEqual "first zero result" (NoJSON 3) =<< runWorkflow config () (\() -> pure (NoJSON 3))
  assertEqual "replayed zero result" (NoJSON 4) =<< runWorkflow config () (\() -> pure (NoJSON 4))
  snapshot <- readStoredSnapshot config
  assertEqual "zero completed" True (snapshotCompleted snapshot)
  assertEqual "zero history" [] (snapshotTasks snapshot)

testApplicationOutput :: IO ()
testApplicationOutput = withTestDirectory "runtime-output" $ \directory ->
  assertEqual "nonserializable final output" (NoJSON 9) =<<
    runWorkflow (testConfig directory "output") () (\() -> task (TaskId "one") () (\() -> pure (9 :: Int)) >> pure (NoJSON 9))

testStructuralInput :: IO ()
testStructuralInput = withTestDirectory "runtime-structural" $ \directory -> do
  calls <- newIORef (0 :: Int)
  let config = testConfig directory "structural"
      first = object ["a" .= (1 :: Int), "b" .= (2 :: Int)]
      reordered = object ["b" .= (2 :: Int), "a" .= (1 :: Int)]
      flow value = task (TaskId "one") value (\_ -> modifyIORef' calls (+ 1) >> pure (7 :: Int))
  assertEqual "first structural result" (7 :: Int) =<< runWorkflow config first flow
  assertEqual "reordered structural result" (7 :: Int) =<< runWorkflow config reordered flow
  assertEqual "reordered object replays cached task" 1 =<< readIORef calls

testInputEncodingFailures :: IO ()
testInputEncodingFailures = withTestDirectory "runtime-input-encoding" $ \directory -> do
  let workflowConfig = testConfig directory "bad-workflow-input"
  workflowResult <- try (runWorkflow workflowConfig BadInput (const (pure ()))) :: IO (Either SomeException ())
  case workflowResult of
    Left exception -> do
      assertBool "workflow input error propagates intact" ("bad input encoder" `Text.isInfixOf` Text.pack (displayException exception))
      assertEqual "workflow input is not TaskFailure" Nothing (fromException exception :: Maybe DuraflowError)
    Right () -> assertBool "workflow input encoding should fail" False
  taskCalls <- newIORef (0 :: Int)
  assertErrorCategory "task input encoding" isReplayMismatch $
    runWorkflow (testConfig directory "bad-task-input") () (\() -> task (TaskId "one") BadInput (\_ -> modifyIORef' taskCalls (+ 1)))
  assertEqual "bad task input action count" 0 =<< readIORef taskCalls

testOutputEncodingFailure :: IO ()
testOutputEncodingFailure = withTestDirectory "runtime-output-encoding" $ \directory -> do
  let config = testConfig directory "output-encoding"
  calls <- newIORef (0 :: Int)
  result <- try $ runWorkflow config () $ \() ->
    task (TaskId "bad-output") () (\() -> modifyIORef' calls (+ 1) >> pure BadOutput)
  assertTaskFailure "output encoding" result
  assertEqual "encoding action count" 1 =<< readIORef calls
  snapshot <- readStoredSnapshot config
  case snapshotTasks snapshot of
    [TaskRecord _ _ (Failed _)] -> pure ()
    other -> assertBool ("expected persisted Failed, got " <> show other) False

newtype NoJSON = NoJSON Int deriving (Eq, Show)
data BadInput = BadInput deriving (Eq, Show)
data BadOutput = BadOutput deriving (Eq, Show)

instance ToJSON BadInput where
  toJSON _ = error "bad input encoder"

instance ToJSON BadOutput where
  toJSON _ = error "bad output encoder"

instance FromJSON BadOutput where
  parseJSON _ = pure BadOutput

assertTaskFailure :: String -> Either DuraflowError a -> IO ()
assertTaskFailure _ (Left (TaskFailure _ _ _ _)) = pure ()
assertTaskFailure name (Left other) = assertBool (name <> ": wrong error " <> show other) False
assertTaskFailure name (Right _) = assertBool (name <> ": expected failure") False

assertErrorCategory :: String -> (DuraflowError -> Bool) -> IO a -> IO ()
assertErrorCategory name predicate action = do
  result <- try action
  case result of
    Left err -> assertBool (name <> ": wrong error " <> show err) (predicate err)
    Right _ -> assertBool (name <> ": expected error") False

isExecutionMismatch, isReplayMismatch, isInvalidState :: DuraflowError -> Bool
isExecutionMismatch ExecutionMismatch {} = True
isExecutionMismatch _ = False
isReplayMismatch ReplayMismatch {} = True
isReplayMismatch _ = False
isInvalidState InvalidState {} = True
isInvalidState _ = False

testConfig :: FilePath -> String -> RunConfig
testConfig directory suffix =
  RunConfig directory (ExecutionId ("runtime-" <> Text.pack suffix)) "workflow" "1"

executionStem :: RunConfig -> FilePath
executionStem config = case executionId config of ExecutionId value -> Text.unpack value

statusName :: TaskRecord -> String
statusName record = case recordStatus record of
  Running -> "Running"
  Success _ -> "Success"
  Failed _ -> "Failed"

readStoredSnapshot :: RunConfig -> IO Snapshot
readStoredSnapshot config = do
  bytes <- ByteString.readFile (stateDirectory config </> executionStem config <> ".json")
  case decodeSnapshot bytes of
    Left message -> throwIO (userError (Text.unpack message))
    Right snapshot -> pure snapshot
