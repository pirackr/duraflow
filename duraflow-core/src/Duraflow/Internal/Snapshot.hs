{-# LANGUAGE OverloadedStrings #-}

module Duraflow.Internal.Snapshot
  ( encodeSnapshot
  , decodeSnapshot
  ) where

import Data.Aeson
  ( Object
  , Value
  , encode
  , eitherDecodeStrict'
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (traverse_)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Duraflow.Internal.Types

encodeSnapshot :: Snapshot -> ByteString.ByteString
encodeSnapshot snapshot = Lazy.toStrict (encode (snapshotValue snapshot))

decodeSnapshot :: ByteString.ByteString -> Either Text Snapshot
decodeSnapshot bytes = do
  value <- mapLeft Text.pack (eitherDecodeStrict' bytes :: Either String Value)
  snapshot <- mapLeft Text.pack (parseEither parseSnapshot value)
  validateSnapshot snapshot
  pure snapshot

snapshotValue :: Snapshot -> Value
snapshotValue snapshot = object
  [ "schemaVersion" .= (1 :: Int)
  , "executionId" .= executionText (snapshotExecutionId snapshot)
  , "workflowName" .= snapshotWorkflowName snapshot
  , "workflowVersion" .= snapshotWorkflowVersion snapshot
  , "workflowInput" .= snapshotWorkflowInput snapshot
  , "completed" .= snapshotCompleted snapshot
  , "tasks" .= map taskValue (snapshotTasks snapshot)
  ]

taskValue :: TaskRecord -> Value
taskValue record = case recordStatus record of
  Running -> object (commonFields <> ["status" .= ("Running" :: Text)])
  Success output -> object (commonFields <> ["status" .= ("Success" :: Text), "output" .= output])
  Failed message -> object (commonFields <> ["status" .= ("Failed" :: Text), "error" .= message])
 where
  commonFields =
    [ "taskId" .= taskText (recordTaskId record)
    , "input" .= recordInput record
    ]

parseSnapshot :: Value -> Parser Snapshot
parseSnapshot = withObject "snapshot" $ \fields -> do
  exactKeys snapshotKeys fields
  schemaVersion <- fields .: "schemaVersion" :: Parser Int
  if schemaVersion == 1 then pure () else fail "unsupported schema version"
  parsedExecutionId <- ExecutionId <$> fields .: "executionId"
  parsedWorkflowName <- fields .: "workflowName"
  parsedWorkflowVersion <- fields .: "workflowVersion"
  Snapshot
    parsedExecutionId
    parsedWorkflowName
    parsedWorkflowVersion
    <$> fields .: "workflowInput"
    <*> fields .: "completed"
    <*> (fields .: "tasks" >>= traverse parseTask)

parseTask :: Value -> Parser TaskRecord
parseTask = withObject "task record" $ \fields -> do
  status <- fields .: "status" :: Parser Text
  case status of
    "Running" -> do
      exactKeys runningKeys fields
      parseCommon fields Running
    "Success" -> do
      exactKeys successKeys fields
      output <- fields .: "output"
      parseCommon fields (Success output)
    "Failed" -> do
      exactKeys failedKeys fields
      message <- fields .: "error"
      if Text.length message <= 2048
        then parseCommon fields (Failed message)
        else fail "task error exceeds 2048 characters"
    _ -> fail "unknown task status"

parseCommon :: Object -> TaskStatus -> Parser TaskRecord
parseCommon fields status =
  TaskRecord
    <$> (TaskId <$> fields .: "taskId")
    <*> fields .: "input"
    <*> pure status

validateSnapshot :: Snapshot -> Either Text ()
validateSnapshot snapshot = do
  validateRunConfig
    RunConfig
      { stateDirectory = ""
      , executionId = snapshotExecutionId snapshot
      , workflowName = snapshotWorkflowName snapshot
      , workflowVersion = snapshotWorkflowVersion snapshot
      }
  traverse_ (validateTaskId . recordTaskId) records
  if length taskIds == length (nub taskIds)
    then Right ()
    else Left "snapshot contains duplicate task IDs"
  validateHistory records
  if snapshotCompleted snapshot && any (not . isSuccess . recordStatus) records
    then Left "completed snapshot contains an unfinished task"
    else Right ()
 where
  records = snapshotTasks snapshot
  taskIds = map recordTaskId records

validateHistory :: [TaskRecord] -> Either Text ()
validateHistory [] = Right ()
validateHistory (record : rest) = case recordStatus record of
  Success _ -> validateHistory rest
  Running -> requireEnd rest
  Failed _ -> requireEnd rest
 where
  requireEnd [] = Right ()
  requireEnd _ = Left "snapshot contains a record after an unfinished task"

isSuccess :: TaskStatus -> Bool
isSuccess (Success _) = True
isSuccess _ = False

exactKeys :: [Key] -> Object -> Parser ()
exactKeys expected actual
  | sort expected == sort (KeyMap.keys actual) = pure ()
  | otherwise = fail "object has missing or unexpected fields"

snapshotKeys, runningKeys, successKeys, failedKeys :: [Key]
snapshotKeys = ["schemaVersion", "executionId", "workflowName", "workflowVersion", "workflowInput", "completed", "tasks"]
runningKeys = ["taskId", "input", "status"]
successKeys = runningKeys <> ["output"]
failedKeys = runningKeys <> ["error"]

executionText :: ExecutionId -> Text
executionText (ExecutionId value) = value

taskText :: TaskId -> Text
taskText (TaskId value) = value

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft function = either (Left . function) Right
