{-# LANGUAGE OverloadedStrings #-}

module SnapshotTests (snapshotTests) where

import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text as Text
import Duraflow.Internal.Snapshot (decodeSnapshot, encodeSnapshot)
import Duraflow.Internal.Types
import TestSupport

snapshotTests :: IO ()
snapshotTests = do
  runCase "snapshot round trip and opaque values" testRoundTrip
  runCase "run configuration validation" testRunConfigValidation
  runCase "task id validation" testTaskIdValidation
  runCase "strict snapshot fields" testStrictSnapshotFields
  runCase "snapshot field types and values" testSnapshotFieldTypes
  runCase "strict task status schemas" testTaskSchemas
  runCase "invalid task histories" testInvalidHistories

testRoundTrip :: IO ()
testRoundTrip = do
  let sid = ExecutionId "example-1"
      records =
        [ TaskRecord (TaskId "first") (object ["nested" .= object ["b" .= (2 :: Int), "a" .= (1 :: Int)]]) (Success (toJSON ([1, 2] :: [Int])))
        , TaskRecord (TaskId "second") Null (Failed "diagnostic")
        ]
      state = Snapshot sid " workflow " " 1 " (object ["n" .= (1 :: Int)]) False records
  assertEqual "round trip" (Right state) (decodeSnapshot (encodeSnapshot state))
  let running = state {snapshotTasks = [TaskRecord (TaskId "running") (Bool True) Running]}
  assertEqual "running round trip" (Right running) (decodeSnapshot (encodeSnapshot running))

testRunConfigValidation :: IO ()
testRunConfigValidation = do
  let cfg eid name version = RunConfig "/existing" (ExecutionId eid) name version
      invalidConfigs =
        [ ("empty execution id", cfg "" "w" "1")
        , ("129-character execution id", cfg (Text.replicate 129 "a") "w" "1")
        , ("non-ASCII execution id", cfg "é" "w" "1")
        , ("path execution id", cfg "../escape" "w" "1")
        , ("punctuation first", cfg "_name" "w" "1")
        , ("blank workflow name", cfg "id" " \t\n" "1")
        , ("blank workflow version", cfg "id" "w" " \t")
        ]
      validConfigs =
        [ ("one-character execution id", cfg "a" "w" "1")
        , ("128-character execution id", cfg (Text.replicate 128 "z") "w" "1")
        , ("valid punctuation", cfg "A0._-z" "w" "1")
        , ("untrimmed workflow metadata", cfg "id" " w " " 1 ")
        ]
  mapM_ (\(label, config) -> assertLeft label (validateRunConfig config)) invalidConfigs
  mapM_ (\(label, config) -> assertEqual label (Right ()) (validateRunConfig config)) validConfigs

testTaskIdValidation :: IO ()
testTaskIdValidation = do
  let invalidIds = [("empty task id", ""), ("blank task id", " \t\n")]
      validIds = [("non-ASCII task id", "préparer"), ("untrimmed task id", " task ")]
  mapM_ (\(label, value) -> assertLeft label (validateTaskId (TaskId value))) invalidIds
  mapM_ (\(label, value) -> assertEqual label (Right ()) (validateTaskId (TaskId value))) validIds

testStrictSnapshotFields :: IO ()
testStrictSnapshotFields = do
  mapM_ rejectMissing snapshotKeys
  reject "unexpected snapshot field" (insertField "extra" Null validSnapshotValue)
  assertLeft "unsupported schema" (decodeSnapshot "{\"schemaVersion\":2}")
  assertLeft "malformed JSON" (decodeSnapshot "{")
 where
  rejectMissing key = reject ("missing snapshot field " <> Text.unpack key) (deleteField key validSnapshotValue)

testSnapshotFieldTypes :: IO ()
testSnapshotFieldTypes = do
  mapM_ (uncurry reject)
    [ ("schema type", replaceField "schemaVersion" (String "1") validSnapshotValue)
    , ("fractional schema", replaceField "schemaVersion" (toJSON (1.5 :: Double)) validSnapshotValue)
    , ("execution id type", replaceField "executionId" (toJSON (1 :: Int)) validSnapshotValue)
    , ("workflow name type", replaceField "workflowName" Null validSnapshotValue)
    , ("workflow version type", replaceField "workflowVersion" (Bool True) validSnapshotValue)
    , ("completed type", replaceField "completed" (String "false") validSnapshotValue)
    , ("tasks type", replaceField "tasks" (object []) validSnapshotValue)
    , ("invalid saved execution id", replaceField "executionId" (String "../x") validSnapshotValue)
    , ("blank saved workflow name", replaceField "workflowName" (String " ") validSnapshotValue)
    , ("blank saved workflow version", replaceField "workflowVersion" (String "\n") validSnapshotValue)
    ]
  -- Application-owned JSON has no shape restriction.
  let opaque = replaceField "workflowInput" (toJSON ([Null, object ["x" .= True]])) validSnapshotValue
  assertRight "opaque workflow input" (decodeValue opaque)

testTaskSchemas :: IO ()
testTaskSchemas = do
  mapM_ (uncurry rejectRecord)
    [ ("missing taskId", deleteField "taskId" runningRecord)
    , ("missing input", deleteField "input" runningRecord)
    , ("missing status", deleteField "status" runningRecord)
    , ("running output", insertField "output" Null runningRecord)
    , ("running error", insertField "error" (String "x") runningRecord)
    , ("success missing output", deleteField "output" successRecord)
    , ("success error", insertField "error" (String "x") successRecord)
    , ("failed missing error", deleteField "error" failedRecord)
    , ("failed output", insertField "output" Null failedRecord)
    , ("unexpected task field", insertField "extra" Null runningRecord)
    , ("task id type", replaceField "taskId" Null runningRecord)
    , ("blank task id", replaceField "taskId" (String " ") runningRecord)
    , ("status type", replaceField "status" (toJSON (1 :: Int)) runningRecord)
    , ("unknown status", replaceField "status" (String "Pending") runningRecord)
    , ("error type", replaceField "error" Null failedRecord)
    , ("error over limit", replaceField "error" (String (Text.replicate 2049 "x")) failedRecord)
    ]
  assertRight "2048-character error accepted"
    (decodeRecord (replaceField "error" (String (Text.replicate 2048 "x")) failedRecord))
  mapM_ (uncurry assertRecordStatus)
    [ (Running, runningRecord)
    , (Success (object ["result" .= (3 :: Int)]), successRecord)
    , (Failed "boom", failedRecord)
    ]
 where
  assertRecordStatus expected value = case decodeRecord value of
    Right snapshot -> assertEqual "decoded status" [expected] (map recordStatus (snapshotTasks snapshot))
    Left message -> error (Text.unpack message)

testInvalidHistories :: IO ()
testInvalidHistories = do
  rejectTasks "duplicate task IDs" [successRecord, replaceField "input" Null successRecord]
  rejectTasks "record after running" [runningRecord, withTaskId "later" successRecord]
  rejectTasks "record after failed" [failedRecord, withTaskId "later" successRecord]
  rejectTasks "unfinished middle" [successRecord, withTaskId "middle" runningRecord, withTaskId "later" successRecord]
  reject "completed running history" (replaceField "completed" (Bool True) (withTasks [runningRecord]))
  reject "completed failed history" (replaceField "completed" (Bool True) (withTasks [failedRecord]))
  assertRight "completed successful history"
    (decodeValue (replaceField "completed" (Bool True) (withTasks [successRecord])))

snapshotKeys :: [Text.Text]
snapshotKeys = ["schemaVersion", "executionId", "workflowName", "workflowVersion", "workflowInput", "completed", "tasks"]

validSnapshotValue :: Value
validSnapshotValue = object
  [ "schemaVersion" .= (1 :: Int)
  , "executionId" .= ("example-1" :: Text.Text)
  , "workflowName" .= ("workflow" :: Text.Text)
  , "workflowVersion" .= ("1" :: Text.Text)
  , "workflowInput" .= object ["n" .= (1 :: Int)]
  , "completed" .= False
  , "tasks" .= ([] :: [Value])
  ]

runningRecord, successRecord, failedRecord :: Value
runningRecord = object ["taskId" .= ("task" :: Text.Text), "input" .= object [], "status" .= ("Running" :: Text.Text)]
successRecord = object ["taskId" .= ("task" :: Text.Text), "input" .= object [], "status" .= ("Success" :: Text.Text), "output" .= object ["result" .= (3 :: Int)]]
failedRecord = object ["taskId" .= ("task" :: Text.Text), "input" .= object [], "status" .= ("Failed" :: Text.Text), "error" .= ("boom" :: Text.Text)]

reject :: String -> Value -> IO ()
reject name = assertLeft name . decodeValue

rejectRecord :: String -> Value -> IO ()
rejectRecord name = assertLeft name . decodeRecord

rejectTasks :: String -> [Value] -> IO ()
rejectTasks name = reject name . withTasks

decodeRecord :: Value -> Either Text.Text Snapshot
decodeRecord value = decodeValue (withTasks [value])

decodeValue :: Value -> Either Text.Text Snapshot
decodeValue = decodeSnapshot . Lazy.toStrict . encode

withTasks :: [Value] -> Value
withTasks records = replaceField "tasks" (toJSON records) validSnapshotValue

withTaskId :: Text.Text -> Value -> Value
withTaskId taskId = replaceField "taskId" (String taskId)

deleteField :: Text.Text -> Value -> Value
deleteField key (Object fields) = Object (KeyMap.delete (Key.fromText key) fields)
deleteField _ value = value

insertField :: Text.Text -> Value -> Value -> Value
insertField key fieldValue (Object fields) = Object (KeyMap.insert (Key.fromText key) fieldValue fields)
insertField _ _ value = value

replaceField :: Text.Text -> Value -> Value -> Value
replaceField = insertField
