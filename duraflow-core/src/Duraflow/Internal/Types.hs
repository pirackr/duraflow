{-# LANGUAGE OverloadedStrings #-}

module Duraflow.Internal.Types
  ( ExecutionId (..)
  , TaskId (..)
  , RunConfig (..)
  , DuraflowError (..)
  , TaskStatus (..)
  , TaskRecord (..)
  , Snapshot (..)
  , validateRunConfig
  , validateTaskId
  ) where

import Control.Exception (Exception)
import Data.Aeson (Value)
import Data.Char (isAlphaNum, isAscii)
import Data.Text (Text)
import qualified Data.Text as Text

newtype ExecutionId = ExecutionId Text deriving (Eq, Show)
newtype TaskId = TaskId Text deriving (Eq, Show)

data RunConfig = RunConfig
  { stateDirectory :: FilePath
  , executionId :: ExecutionId
  , workflowName :: Text
  , workflowVersion :: Text
  }
  deriving (Eq, Show)

data DuraflowError
  = InvalidConfiguration Text
  | ExecutionBusy ExecutionId
  | ExecutionMismatch ExecutionId Text
  | InvalidState ExecutionId Text
  | ReplayMismatch ExecutionId Int (Maybe TaskId) Text
  | StorageFailure ExecutionId Text
  | TaskFailure ExecutionId Int TaskId Text
  deriving (Eq, Show)

instance Exception DuraflowError

data TaskStatus
  = Running
  | Success Value
  | Failed Text
  deriving (Eq, Show)

data TaskRecord = TaskRecord
  { recordTaskId :: TaskId
  , recordInput :: Value
  , recordStatus :: TaskStatus
  }
  deriving (Eq, Show)

data Snapshot = Snapshot
  { snapshotExecutionId :: ExecutionId
  , snapshotWorkflowName :: Text
  , snapshotWorkflowVersion :: Text
  , snapshotWorkflowInput :: Value
  , snapshotCompleted :: Bool
  , snapshotTasks :: [TaskRecord]
  }
  deriving (Eq, Show)

validateRunConfig :: RunConfig -> Either Text ()
validateRunConfig config = do
  validateExecutionId (executionId config)
  validateNonblank "workflow name" (workflowName config)
  validateNonblank "workflow version" (workflowVersion config)

validateTaskId :: TaskId -> Either Text ()
validateTaskId (TaskId value) = validateNonblank "task ID" value

validateExecutionId :: ExecutionId -> Either Text ()
validateExecutionId (ExecutionId value)
  | lengthValue < 1 || lengthValue > 128 = Left "execution ID must contain between 1 and 128 characters"
  | not (asciiAlphaNumeric (Text.head value)) = Left "execution ID must start with an ASCII letter or digit"
  | not (Text.all validRemainder value) = Left "execution ID contains an invalid character"
  | otherwise = Right ()
 where
  lengthValue = Text.length value
  asciiAlphaNumeric character = isAscii character && isAlphaNum character
  validRemainder character = asciiAlphaNumeric character || character `elem` ("._-" :: String)

validateNonblank :: Text -> Text -> Either Text ()
validateNonblank label value
  | Text.null (Text.strip value) = Left (label <> " must not be blank")
  | otherwise = Right ()
