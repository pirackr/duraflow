{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Weather.Cli
  ( parseArguments
  , normalizeInvocation
  , runCli
  ) where

import Control.Exception (AsyncException, IOException, SomeException, catch, displayException, fromException, throwIO)
import Control.Monad (unless, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, defaultTimeLocale, formatTime, parseTimeM)
import Duraflow (ExecutionId (..), RunConfig (..), runWorkflow)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (normalise, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus, isRegularFile)
import Text.Read (readMaybe)
import Weather

parseArguments :: [String] -> Either Text (FilePath, ExecutionId, WeatherRequest)
parseArguments arguments = case arguments of
  [state, execution, latitudeText, longitudeText, dateText, output] -> do
    latitude <- parseCoordinate "latitude" (-90) 90 latitudeText
    longitude <- parseCoordinate "longitude" (-180) 180 longitudeText
    day <- parseDate dateText
    pure
      ( state
      , ExecutionId (Text.pack execution)
      , WeatherRequest latitude longitude day output
      )
  _ -> Left "expected six arguments: STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE"

normalizeInvocation :: (FilePath, ExecutionId, WeatherRequest) -> IO (RunConfig, WeatherRequest)
normalizeInvocation (state, execution, request) = do
  requireDirectory "state directory" state
  canonicalState <- canonicalizePath state
  let suppliedOutput = outputPath request
      outputName = takeFileName suppliedOutput
      suppliedParent = takeDirectory suppliedOutput
  when (null outputName || outputName == "." || outputName == "..") $
    ioError (userError "output file must have a filename")
  requireDirectory "output parent directory" suppliedParent
  canonicalParent <- canonicalizePath suppliedParent
  let absoluteOutput = normalise (canonicalParent </> outputName)
  when (sameOrInside canonicalState absoluteOutput) $
    ioError (userError "output file must be outside the state directory")
  validateOutputEntry absoluteOutput
  pure
    ( RunConfig canonicalState execution weatherWorkflowName weatherWorkflowVersion
    , request {outputPath = absoluteOutput}
    )

runCli :: IO ()
runCli = run `catch` reportFailure
 where
  run = do
    arguments <- getArgs
    invocation <- either (ioError . userError . Text.unpack) pure (parseArguments arguments)
    (config, request) <- normalizeInvocation invocation
    result <- runWorkflow config request weatherPreparation
    putStrLn result

  reportFailure :: SomeException -> IO ()
  reportFailure exception = case fromException exception :: Maybe AsyncException of
    Just cancellation -> throwIO cancellation
    Nothing -> hPutStrLn stderr (displayException exception) >> exitFailure

parseCoordinate :: Text -> Double -> Double -> String -> Either Text Double
parseCoordinate label lower upper input = case readMaybe input of
  Nothing -> Left (label <> " must be a number")
  Just value
    | isNaN value || isInfinite value -> Left (label <> " must be finite")
    | value < lower || value > upper -> Left (label <> " is outside its geographic range")
    | otherwise -> Right value

parseDate :: String -> Either Text Day
parseDate input = case parseTimeM True defaultTimeLocale "%F" input of
  Nothing -> Left "forecast date must be a valid YYYY-MM-DD calendar date"
  Just day
    | formatTime defaultTimeLocale "%F" day /= input -> Left "forecast date must use canonical YYYY-MM-DD form"
    | otherwise -> Right day

requireDirectory :: String -> FilePath -> IO ()
requireDirectory label path = do
  exists <- doesDirectoryExist path
  unless exists (ioError (userError (label <> " does not exist or is not a directory")))

sameOrInside :: FilePath -> FilePath -> Bool
sameOrInside parent candidate =
  let parentParts = splitDirectories (normalise parent)
      candidateParts = splitDirectories (normalise candidate)
   in parentParts == take (length parentParts) candidateParts

validateOutputEntry :: FilePath -> IO ()
validateOutputEntry path = do
  result <- (Right <$> getSymbolicLinkStatus path) `catch` missing
  case result of
    Left () -> pure ()
    Right status -> unless (isRegularFile status) (ioError (userError "output entry is not a regular file"))
 where
  missing :: IOException -> IO (Either () FileStatus)
  missing exception
    | isDoesNotExistError exception = pure (Left ())
    | otherwise = ioError exception
