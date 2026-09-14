{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module IntegrationTests (runIntegrationTests) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict')
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Duraflow (ExecutionId (..), RunConfig (..), runWorkflow)
import GHC.Generics (Generic)
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import TestSupport
import WeatherWorkflow

runIntegrationTests :: IO ()
runIntegrationTests = do
  runCase "three-task workflow resumes offline" workflowResume
  runCase "external effect repeats safely before checkpoint" repeatedExternalEffect

request :: WeatherRequest
request = WeatherRequest 47.6062 (-122.3321) (fromGregorian 2026 9 15) "/tmp/checklist.txt"

timestamp :: UTCTime
timestamp = UTCTime (fromGregorian 2026 9 14) (secondsToDiffTime 45296)

workflowResume :: IO ()
workflowResume = withTestDirectory "resume" $ \directory -> do
  bytes <- ByteString.readFile (fixturePath "forecast.json")
  let output = directory </> "result.txt"
      workflowRequest = request {outputPath = output}
      config = RunConfig directory (ExecutionId "offline-resume") weatherWorkflowName weatherWorkflowVersion
  source <- either (fail . show) pure (parseForecast workflowRequest (forecastUrl workflowRequest) timestamp bytes)
  fetches <- newIORef (0 :: Int)
  writes <- newIORef (0 :: Int)
  let effects = WeatherEffects
        { getForecast = \_ -> modifyIORef' fetches (+ 1) >> pure source
        , putChecklist = \input -> do
            attempt <- modifyAndRead writes
            if attempt == 1 then fail "injected writer failure" else writeChecklist input
        }
  assertThrows "first workflow fails at writer" (runWorkflow config workflowRequest (weatherPreparationWith effects))
  SnapshotView completedAfterFailure records <- readSnapshot (directory </> "offline-resume.json")
  assertEqual "failed execution not complete" False completedAfterFailure
  assertEqual "two successes then failure" ["Success", "Success", "Failed"] (map status records)
  assertEqual "one fetch before resume" 1 =<< readIORef fetches

  result <- runWorkflow config workflowRequest (weatherPreparationWith effects)
  assertEqual "resume output" output result
  assertEqual "one fetch total after resume" 1 =<< readIORef fetches
  assertEqual "writer retried once" 2 =<< readIORef writes
  actual <- ByteString.readFile output
  assertEqual "saved deterministic checklist" (TextEncoding.encodeUtf8 (renderChecklist (prepareAdvice source))) actual
  assertBool "saved original timestamp rendered" (ByteString8.isInfixOf "2026-09-14T12:34:56Z" actual)
  SnapshotView completedAfterResume _ <- readSnapshot (directory </> "offline-resume.json")
  assertEqual "resumed execution complete" True completedAfterResume

  removeFile output
  _ <- runWorkflow config workflowRequest (weatherPreparationWith effects)
  exists <- doesFileExist output
  assertEqual "committed writer skipped when artifact absent" False exists
  assertEqual "fetch remains skipped when artifact absent" 1 =<< readIORef fetches
  assertEqual "write remains skipped when artifact absent" 2 =<< readIORef writes

repeatedExternalEffect :: IO ()
repeatedExternalEffect = withTestDirectory "repeated-effect" $ \directory -> do
  bytes <- ByteString.readFile (fixturePath "forecast.json")
  let output = directory </> "result.txt"
      workflowRequest = request {outputPath = output}
      config = RunConfig directory (ExecutionId "offline-repeated-effect") weatherWorkflowName weatherWorkflowVersion
  source <- either (fail . show) pure (parseForecast workflowRequest (forecastUrl workflowRequest) timestamp bytes)
  fetches <- newIORef (0 :: Int)
  writes <- newIORef (0 :: Int)
  let effects = WeatherEffects
        { getForecast = \_ -> modifyIORef' fetches (+ 1) >> pure source
        , putChecklist = \input -> do
            path <- writeChecklist input
            attempt <- modifyAndRead writes
            if attempt == 1 then fail "effect completed before checkpoint" else pure path
        }
  assertThrows "completed external effect can precede checkpoint failure"
    (runWorkflow config workflowRequest (weatherPreparationWith effects))
  firstBytes <- ByteString.readFile output
  _ <- runWorkflow config workflowRequest (weatherPreparationWith effects)
  secondBytes <- ByteString.readFile output
  assertEqual "repeated effect replaces one complete checklist" firstBytes secondBytes
  assertEqual "forecast fetched once across repeated effect" 1 =<< readIORef fetches
  assertEqual "uncommitted effect repeated once" 2 =<< readIORef writes

data SnapshotView = SnapshotView
  { completed :: Bool
  , tasks :: [TaskView]
  }
  deriving (Generic)

instance FromJSON SnapshotView

data TaskView = TaskView
  { status :: Text
  }
  deriving (Generic)

instance FromJSON TaskView

readSnapshot :: FilePath -> IO SnapshotView
readSnapshot path = do
  decoded <- eitherDecodeFileStrict' path
  either (fail . ("could not decode snapshot: " <>)) pure decoded

modifyAndRead :: IORef Int -> IO Int
modifyAndRead reference = do
  modifyIORef' reference (+ 1)
  readIORef reference
