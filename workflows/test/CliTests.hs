{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CliTests (runCliTests) where

import Control.Exception
  ( AsyncException
  , Exception (fromException, toException)
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , throwIO
  , try
  )
import Data.Either (isLeft)
import Data.Time (fromGregorian)
import Duraflow (ExecutionId (..), RunConfig (..))
import System.Directory
  ( canonicalizePath
  , createDirectory
  , createDirectoryLink
  , createFileLink
  )
import System.FilePath ((</>))
import TestSupport
import WeatherWorkflow

runCliTests :: IO ()
runCliTests = do
  runCase "CLI parses six canonical positional arguments" parseValid
  runCase "CLI rejects invalid argument values" parseInvalid
  runCase "CLI canonicalizes safe paths" normalizeSafePaths
  runCase "CLI rejects unsafe output paths" normalizeUnsafePaths
  runCase "CLI rethrows cancellation from the broad async hierarchy" rethrowsBroadCancellation

parseValid :: IO ()
parseValid =
  assertEqual
    "parsed invocation"
    (Right ("state", ExecutionId "weather-001", WeatherRequest 47.6062 (-122.3321) (fromGregorian 2026 9 15) "report.txt"))
    (parseArguments ["state", "weather-001", "47.6062", "-122.3321", "2026-09-15", "report.txt"])

parseInvalid :: IO ()
parseInvalid = mapM_ (\(label, arguments) -> assertBool label (isLeft (parseArguments arguments))) cases
 where
  valid = ["state", "weather-001", "47.6062", "-122.3321", "2026-09-15", "report.txt"]
  cases =
    [ ("missing arguments", init valid)
    , ("extra arguments", valid <> ["extra"])
    , ("invalid latitude", replaceAt 2 "north" valid)
    , ("nonfinite latitude", replaceAt 2 "NaN" valid)
    , ("latitude out of range", replaceAt 2 "90.0001" valid)
    , ("longitude out of range", replaceAt 3 "-180.0001" valid)
    , ("invalid calendar date", replaceAt 4 "2026-02-29" valid)
    , ("noncanonical calendar date", replaceAt 4 "2026-9-15" valid)
    ]

normalizeSafePaths :: IO ()
normalizeSafePaths = withTestDirectory "cli-safe" $ \root -> do
  let state = root </> "state"
      outputDirectory = root </> "output"
  createDirectory state
  createDirectory outputDirectory
  stateAlias <- pure (root </> "state-alias")
  createDirectoryLink state stateAlias
  (config, normalized) <- normalizeInvocation
    (stateAlias, ExecutionId "weather-001", WeatherRequest 1 2 (fromGregorian 2026 9 15) (outputDirectory </> "report.txt"))
  canonicalState <- canonicalizePath state
  canonicalOutputDirectory <- canonicalizePath outputDirectory
  assertEqual "canonical state" canonicalState (stateDirectory config)
  assertEqual "workflow name" "weatherPreparation" (workflowName config)
  assertEqual "workflow version" "1" (workflowVersion config)
  assertEqual "absolute output" (canonicalOutputDirectory </> "report.txt") (takeOutput normalized)
  let sibling = root </> "state-other"
  createDirectory sibling
  _ <- normalizeInvocation
    (state, ExecutionId "weather-002", normalized {outputPath = sibling </> "legal.txt"})
  pure ()
 where
  takeOutput request = outputPath request

normalizeUnsafePaths :: IO ()
normalizeUnsafePaths = withTestDirectory "cli-unsafe" $ \root -> do
  let state = root </> "state"
      outside = root </> "outside"
      request path = WeatherRequest 1 2 (fromGregorian 2026 9 15) path
      normalize path = normalizeInvocation (state, ExecutionId "weather-001", request path)
  createDirectory state
  createDirectory outside
  assertIOThrows "output equals state" (normalize state)
  assertIOThrows "output inside state" (normalize (state </> "report.txt"))
  stateAlias <- pure (root </> "state-alias")
  createDirectoryLink state stateAlias
  assertIOThrows "output through state alias" (normalize (stateAlias </> "report.txt"))
  let target = outside </> "target.txt"
      linked = outside </> "linked.txt"
      dangling = outside </> "dangling.txt"
      directoryTarget = outside </> "directory-target"
  writeFile target "untouched"
  createFileLink target linked
  createFileLink (outside </> "missing-target") dangling
  createDirectory directoryTarget
  assertIOThrows "symlink output" (normalize linked)
  assertIOThrows "dangling symlink output" (normalize dangling)
  assertIOThrows "nonregular output" (normalize directoryTarget)
  assertIOThrows "missing output parent" (normalize (root </> "missing" </> "report.txt"))

data TestCancellation = TestCancellation deriving (Show)

instance Exception TestCancellation where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

rethrowsBroadCancellation :: IO ()
rethrowsBroadCancellation = do
  outcome <- try (handleTopLevelErrors (throwIO TestCancellation))
  case (outcome :: Either SomeException ()) of
    Left exception -> do
      assertBool "not a concrete AsyncException" $
        case fromException exception :: Maybe AsyncException of
          Nothing -> True
          Just _ -> False
      assertBool "original custom cancellation preserved" $
        case fromException exception :: Maybe TestCancellation of
          Just TestCancellation -> True
          Nothing -> False
    Right () -> assertBool "custom cancellation unexpectedly returned" False

assertIOThrows :: forall a. String -> IO a -> IO ()
assertIOThrows label action = do
  outcome <- try action
  assertBool label $ case (outcome :: Either SomeException a) of
    Left _ -> True
    Right _ -> False

replaceAt :: Int -> a -> [a] -> [a]
replaceAt index replacement values =
  take index values <> [replacement] <> drop (index + 1) values
