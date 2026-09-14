{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Duraflow.Internal.Runtime
  ( Workflow
  , runWorkflow
  , runWorkflowWith
  , task
  ) where

import Control.DeepSeq (force)
import Control.Exception
  ( SomeAsyncException
  , SomeException
  , catch
  , displayException
  , evaluate
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (ap, unless, when)
import Data.Aeson (FromJSON, ToJSON, Value, fromJSON, toJSON)
import qualified Data.Aeson as Aeson
import Data.IORef
import qualified Data.Text as Text
import Duraflow.Internal.Storage
import Duraflow.Internal.Types

newtype Workflow output = Workflow
  { executeWorkflow :: RuntimeEnvironment -> IO output
  }

instance Functor Workflow where
  fmap function workflow = Workflow $ \environment ->
    function <$> executeWorkflow workflow environment

instance Applicative Workflow where
  pure value = Workflow $ \_ -> pure value
  (<*>) = ap

instance Monad Workflow where
  workflow >>= next = Workflow $ \environment -> do
    value <- executeWorkflow workflow environment
    executeWorkflow (next value) environment

data RuntimeEnvironment = RuntimeEnvironment
  { runtimeStore :: Store
  , runtimeState :: IORef RuntimeState
  }

data RuntimeState = RuntimeState
  { currentSnapshot :: Snapshot
  , historyCursor :: Int
  , invocationTaskIds :: [TaskId]
  , originalHistoryLength :: Int
  }

runWorkflow
  :: ToJSON input
  => RunConfig
  -> input
  -> (input -> Workflow output)
  -> IO output
runWorkflow = runWorkflowWith productionStorageOps

runWorkflowWith
  :: ToJSON input
  => StorageOps
  -> RunConfig
  -> input
  -> (input -> Workflow output)
  -> IO output
runWorkflowWith operations suppliedConfig input orchestration = do
  encodedInput <- forceJSON input
  withExecutionStore operations suppliedConfig $ \store -> mask $ \restore -> do
    initial <- initializeExecution store encodedInput
    stateReference <- newIORef RuntimeState
      { currentSnapshot = initial
      , historyCursor = 0
      , invocationTaskIds = []
      , originalHistoryLength = length (snapshotTasks initial)
      }
    let environment = RuntimeEnvironment store stateReference
    result <- restore (executeWorkflow (orchestration input) environment)
    finishExecution environment
    pure result

task
  :: (ToJSON input, ToJSON output, FromJSON output)
  => TaskId
  -> input
  -> (input -> IO output)
  -> Workflow output
task taskId input action = Workflow $ \environment -> mask $ \restore -> do
  state <- readIORef (runtimeState environment)
  let position = historyCursor state
      eid = snapshotExecutionId (currentSnapshot state)
  case validateTaskId taskId of
    Left message -> throwIO (ReplayMismatch eid position (Just taskId) message)
    Right () -> pure ()
  encodedInput <- forceJSON input `catch` inputEncodingFailure eid position taskId
  when (taskId `elem` invocationTaskIds state) $
    throwIO (ReplayMismatch eid position (Just taskId) "duplicate task ID in invocation")
  let seenState = state {invocationTaskIds = taskId : invocationTaskIds state}
  writeIORef (runtimeState environment) seenState
  case drop position (snapshotTasks (currentSnapshot seenState)) of
    record : _ -> replayOrRetry environment restore seenState taskId encodedInput input action record
    [] -> appendAndRun environment restore seenState taskId encodedInput input action

initializeExecution :: Store -> Value -> IO Snapshot
initializeExecution store encodedInput = do
  existing <- readSnapshot store
  case existing of
    Nothing -> do
      let config = storeRunConfig store
          initial = Snapshot
            { snapshotExecutionId = executionId config
            , snapshotWorkflowName = workflowName config
            , snapshotWorkflowVersion = workflowVersion config
            , snapshotWorkflowInput = encodedInput
            , snapshotCompleted = False
            , snapshotTasks = []
            }
      commitSnapshot store initial
      pure initial
    Just snapshot -> do
      validateIdentity (storeRunConfig store) encodedInput snapshot
      recoverSnapshot store
      pure snapshot

validateIdentity :: RunConfig -> Value -> Snapshot -> IO ()
validateIdentity config encodedInput snapshot = do
  let eid = executionId config
      mismatch message = throwIO (ExecutionMismatch eid message)
  unless (snapshotExecutionId snapshot == eid) (mismatch "execution ID differs from saved state")
  unless (snapshotWorkflowName snapshot == workflowName config) (mismatch "workflow name differs from saved state")
  unless (snapshotWorkflowVersion snapshot == workflowVersion config) (mismatch "workflow version differs from saved state")
  unless (snapshotWorkflowInput snapshot == encodedInput) (mismatch "workflow input differs from saved state")

replayOrRetry
  :: (ToJSON input, ToJSON output, FromJSON output)
  => RuntimeEnvironment
  -> (forall value. IO value -> IO value)
  -> RuntimeState
  -> TaskId
  -> Value
  -> input
  -> (input -> IO output)
  -> TaskRecord
  -> IO output
replayOrRetry environment restore state taskId encodedInput input action record = do
  let snapshot = currentSnapshot state
      eid = snapshotExecutionId snapshot
      position = historyCursor state
      mismatch message = throwIO (ReplayMismatch eid position (Just taskId) message)
  unless (recordTaskId record == taskId) (mismatch "task ID or order differs from saved history")
  unless (recordInput record == encodedInput) (mismatch "task input differs from saved history")
  case recordStatus record of
    Success encodedOutput -> do
      output <- decodeSavedOutput eid position taskId encodedOutput
      writeIORef (runtimeState environment) state {historyCursor = position + 1}
      pure output
    Running -> retry
    Failed _ -> retry
 where
  retry = do
    let running = record {recordStatus = Running}
        runningSnapshot = replaceRecord (historyCursor state) running (currentSnapshot state)
    commitSnapshot (runtimeStore environment) runningSnapshot
    let runningState = state {currentSnapshot = runningSnapshot}
    writeIORef (runtimeState environment) runningState
    runTaskAction environment restore runningState taskId input action

appendAndRun
  :: (ToJSON input, ToJSON output)
  => RuntimeEnvironment
  -> (forall value. IO value -> IO value)
  -> RuntimeState
  -> TaskId
  -> Value
  -> input
  -> (input -> IO output)
  -> IO output
appendAndRun environment restore state taskId encodedInput input action = do
  let snapshot = currentSnapshot state
      eid = snapshotExecutionId snapshot
      position = historyCursor state
  when (snapshotCompleted snapshot) $
    throwIO (ReplayMismatch eid position (Just taskId) "completed execution cannot append a task")
  let running = TaskRecord taskId encodedInput Running
      runningSnapshot = snapshot {snapshotTasks = snapshotTasks snapshot <> [running]}
  commitSnapshot (runtimeStore environment) runningSnapshot
  let runningState = state {currentSnapshot = runningSnapshot}
  writeIORef (runtimeState environment) runningState
  runTaskAction environment restore runningState taskId input action

runTaskAction
  :: ToJSON output
  => RuntimeEnvironment
  -> (forall value. IO value -> IO value)
  -> RuntimeState
  -> TaskId
  -> input
  -> (input -> IO output)
  -> IO output
runTaskAction environment restore state taskId input action = do
  attempted <- try (restore performAndEncode)
  case attempted of
    Left exception -> handleActionException exception
    Right (output, encodedOutput) -> do
      let position = historyCursor state
          successful = TaskRecord taskId (recordInputAt position state) (Success encodedOutput)
          successfulSnapshot = replaceRecord position successful (currentSnapshot state)
      commitSnapshot (runtimeStore environment) successfulSnapshot
      writeIORef (runtimeState environment) state
        { currentSnapshot = successfulSnapshot
        , historyCursor = position + 1
        }
      pure output
 where
  performAndEncode = do
    output <- action input
    encoded <- forceJSON output
    pure (output, encoded)
  handleActionException exception = case fromException exception :: Maybe SomeAsyncException of
    Just _ -> throwIO exception
    Nothing -> do
      let position = historyCursor state
          eid = snapshotExecutionId (currentSnapshot state)
          diagnostic = Text.take 2048 (Text.pack (displayException exception))
          failed = TaskRecord taskId (recordInputAt position state) (Failed diagnostic)
          failedSnapshot = replaceRecord position failed (currentSnapshot state)
          preserveContext (StorageFailure failedEid message) =
            throwIO (StorageFailure failedEid (message <> "; while recording task failure: " <> diagnostic))
          preserveContext other = throwIO other
      commitSnapshot (runtimeStore environment) failedSnapshot `catch` preserveContext
      writeIORef (runtimeState environment) state {currentSnapshot = failedSnapshot}
      throwIO (TaskFailure eid position taskId diagnostic)

decodeSavedOutput :: forall output. FromJSON output => ExecutionId -> Int -> TaskId -> Value -> IO output
decodeSavedOutput eid position taskId encodedOutput = do
  decoded <- evaluate (fromJSON encodedOutput) `catch` decodeException
  case decoded of
    Aeson.Error message -> replayFailure (Text.pack message)
    Aeson.Success output -> evaluate output `catch` decodeException
 where
  replayFailure message =
    throwIO (ReplayMismatch eid position (Just taskId) ("saved task output cannot be decoded: " <> message))
  decodeException :: SomeException -> IO value
  decodeException exception = case fromException exception :: Maybe SomeAsyncException of
    Just _ -> throwIO exception
    Nothing -> replayFailure (Text.pack (displayException exception))

finishExecution :: RuntimeEnvironment -> IO ()
finishExecution environment = do
  state <- readIORef (runtimeState environment)
  let snapshot = currentSnapshot state
      position = historyCursor state
      eid = snapshotExecutionId snapshot
  when (position < originalHistoryLength state) $
    throwIO (ReplayMismatch eid position Nothing "workflow returned before consuming saved task history")
  unless (snapshotCompleted snapshot) $ do
    let completed = snapshot {snapshotCompleted = True}
    commitSnapshot (runtimeStore environment) completed
    writeIORef (runtimeState environment) state {currentSnapshot = completed}

forceJSON :: ToJSON value => value -> IO Value
forceJSON value = evaluate (force (toJSON value))

inputEncodingFailure :: ExecutionId -> Int -> TaskId -> SomeException -> IO Value
inputEncodingFailure eid position taskId exception =
  case fromException exception :: Maybe SomeAsyncException of
    Just _ -> throwIO exception
    Nothing -> throwIO (ReplayMismatch eid position (Just taskId) ("task input cannot be encoded: " <> Text.pack (displayException exception)))

recordInputAt :: Int -> RuntimeState -> Value
recordInputAt position state = recordInput (snapshotTasks (currentSnapshot state) !! position)

replaceRecord :: Int -> TaskRecord -> Snapshot -> Snapshot
replaceRecord position replacement snapshot =
  snapshot {snapshotTasks = replaceAt position replacement (snapshotTasks snapshot)}

replaceAt :: Int -> value -> [value] -> [value]
replaceAt position replacement values =
  take position values <> [replacement] <> drop (position + 1) values
