{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ForecastTests (runForecastTests) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, try)
import Control.Monad (forM_)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Duraflow (ExecutionId (..), RunConfig (..), runWorkflow)
import System.Directory (createDirectory, createFileLink, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.Posix.Files (ownerExecuteMode, ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import TestSupport
import Weather
import Weather.Forecast (fetchForecastWith, forecastUrl, parseForecast)

runForecastTests :: IO ()
runForecastTests = do
  runCase "forecast parses requested row and round-trips" parsingRoundTrip
  runCase "forecast rejects malformed and structurally invalid responses" structuralFailures
  runCase "forecast rejects every invalid unit" unitFailures
  runCase "forecast rejects invalid coordinates and metrics" valueFailures
  runCase "forecast transport status, deadline, clock, and cancellation" transportFailures
  runCase "checklist writer safely replaces real files" writerCases
  runCase "three-task workflow resumes offline" workflowResume

request :: WeatherRequest
request = WeatherRequest 47.6062 (-122.3321) (fromGregorian 2026 9 15) "/tmp/checklist.txt"

timestamp :: UTCTime
timestamp = UTCTime (fromGregorian 2026 9 14) (secondsToDiffTime 45296)

readFixture :: IO ByteString.ByteString
readFixture = ByteString.readFile (fixturePath "forecast.json")

parsingRoundTrip :: IO ()
parsingRoundTrip = do
  bytes <- readFixture
  let expectedUrl =
        "https://api.open-meteo.com/v1/forecast?latitude=47.6062&longitude=-122.3321&start_date=2026-09-15&end_date=2026-09-15&timezone=UTC&temperature_unit=celsius&wind_speed_unit=kmh&daily=temperature_2m_min%2Ctemperature_2m_max%2Cprecipitation_probability_max%2Cwind_speed_10m_max%2Cuv_index_max"
  assertEqual "encoded forecast URL" expectedUrl (forecastUrl request)
  forecast <- either (fail . show) pure (parseForecast request (forecastUrl request) timestamp bytes)
  assertEqual "selected date" (forecastDate request) (forecastDate (forecastRequest forecast))
  assertEqual "request coordinates" (47.6062, -122.3321) (requestedLatitude (forecastRequest forecast), requestedLongitude (forecastRequest forecast))
  assertEqual "provider coordinates" (47.625, -122.375) (providerLatitude forecast, providerLongitude forecast)
  assertEqual "selected metrics" (5, 17.5, 60, 41, 3.2)
    (minimumTemperature forecast, maximumTemperature forecast, rainProbability forecast, maximumWindSpeed forecast, maximumUvIndex forecast)
  assertEqual "normalized units" (ForecastUnits "iso8601" "°C" "%" "km/h" "") (forecastUnits forecast)
  assertEqual "provider" "Open-Meteo" (provider forecast)
  assertEqual "request URL" expectedUrl (requestUrl forecast)
  assertEqual "timestamp" timestamp (retrievedAt forecast)
  assertEqual "forecast JSON round trip" (Right forecast) (eitherDecode (encode forecast))
  assertEqual "request JSON round trip" (Right request) (eitherDecode (encode request))

structuralFailures :: IO ()
structuralFailures = do
  bytes <- readFixture
  let failures =
        [ ("malformed", "{")
        , ("absent date", replace "\"2026-09-15\"" "\"2026-09-16\"" bytes)
        , ("mismatched arrays", replace "[11.2, 5.0]" "[11.2]" bytes)
        , ("missing daily", replace "\"daily\":" "\"not_daily\":" bytes)
        , ("null metric", replace "[11.2, 5.0]" "[11.2, null]" bytes)
        , ("nonzero UTC offset", replace "\"utc_offset_seconds\": 0" "\"utc_offset_seconds\": 3600" bytes)
        ]
  forM_ failures $ \(label, body) -> assertLeft label (parseForecast request (forecastUrl request) timestamp body)

unitFailures :: IO ()
unitFailures = do
  bytes <- readFixture
  let units :: [(String, Text, Text)]
      units =
        [ ("time", "\"time\": \"iso8601\"", "\"time\": \"unix\"")
        , ("minimum temperature", "\"temperature_2m_min\": \"°C\"", "\"temperature_2m_min\": \"°F\"")
        , ("maximum temperature", "\"temperature_2m_max\": \"°C\"", "\"temperature_2m_max\": \"°F\"")
        , ("rain", "\"precipitation_probability_max\": \"%\"", "\"precipitation_probability_max\": \"fraction\"")
        , ("wind", "\"wind_speed_10m_max\": \"km/h\"", "\"wind_speed_10m_max\": \"m/s\"")
        , ("UV", "\"uv_index_max\": \"\"", "\"uv_index_max\": \"index\"")
        ]
  forM_ units $ \(label, original, wrong) -> do
    assertLeft (label <> " wrong") (parseForecast request (forecastUrl request) timestamp (replaceUtf8 original wrong bytes))
    let renamed = "\"missing_" <> Text.drop 1 original
    assertLeft (label <> " missing") (parseForecast request (forecastUrl request) timestamp (replaceUtf8 original renamed bytes))

valueFailures :: IO ()
valueFailures = do
  bytes <- readFixture
  let malformedValues =
        [ ("provider latitude", "\"latitude\": 47.625", "\"latitude\": 91")
        , ("provider longitude", "\"longitude\": -122.375", "\"longitude\": -181")
        , ("negative wind", "[12.4, 41.0]", "[12.4, -0.1]")
        , ("negative UV", "[2.0, 3.2]", "[2.0, -0.1]")
        , ("rain low", "[20, 60]", "[20, -0.1]")
        , ("rain high", "[20, 60]", "[20, 100.1]")
        , ("inverted temperatures", "[11.2, 5.0]", "[11.2, 18.0]")
        , ("invalid numeric type", "[2.0, 3.2]", "[2.0, \"high\"]")
        , ("non-finite numeric", "[2.0, 3.2]", "[2.0, 1e400]")
        ]
  forM_ malformedValues $ \(label, original, wrong) ->
    assertLeft label (parseForecast request (forecastUrl request) timestamp (replace original wrong bytes))
  let invalidRequests =
        [ request {requestedLatitude = 0 / 0}
        , request {requestedLatitude = 90.01}
        , request {requestedLongitude = -180.01}
        ]
  forM_ invalidRequests $ \invalid -> assertLeft "invalid request coordinates" (parseForecast invalid (forecastUrl invalid) timestamp bytes)

transportFailures :: IO ()
transportFailures = do
  bytes <- readFixture
  clockCalled <- newIORef False
  let clock = writeIORef clockCalled True >> pure timestamp
      statusTransport status _ = pure (status, bytes)
  assertThrows "non-2xx" (fetchForecastWith 1000000 (statusTransport 500) clock request)
  assertThrows "redirect" (fetchForecastWith 1000000 (statusTransport 302) clock request)
  assertEqual "clock not called for statuses" False =<< readIORef clockCalled
  assertThrows "malformed before clock" (fetchForecastWith 1000000 (\_ -> pure (200, "{")) clock request)
  assertEqual "clock not called before validation" False =<< readIORef clockCalled
  saved <- fetchForecastWith 1000000 (statusTransport 200) clock request
  assertEqual "injected clock timestamp" timestamp (retrievedAt saved)
  assertThrows "response acquisition deadline" (fetchForecastWith 1000 (\_ -> threadDelay 100000 >> pure (200, bytes)) clock request)
  let huge = replace "\"GMT\"" ("\"" <> ByteString8.replicate 20000000 'x' <> "\"") bytes
  assertThrows "validation deadline" (fetchForecastWith 1000 (\_ -> pure (200, huge)) clock request)
  result <- newEmptyMVar
  thread <- forkIO $ do
    outcome <- try (fetchForecastWith 10000000 (\_ -> threadDelay 10000000 >> pure (200, bytes)) clock request)
    putMVar result (outcome :: Either SomeException Forecast)
  threadDelay 20000
  killThread thread
  cancelled <- takeMVar result
  assertBool "external cancellation propagated" $ case cancelled of
    Left exception -> fromException exception == Just ThreadKilled
    Right _ -> False

writerCases :: IO ()
writerCases = withTestDirectory "writer" $ \directory -> do
  bytes <- readFixture
  forecast <- either (fail . show) pure (parseForecast request (forecastUrl request) timestamp bytes)
  let checklist = prepareAdvice forecast
      target = directory </> "checklist.txt"
  first <- writeChecklist (target, checklist)
  expected <- ByteString.readFile (fixturePath "checklist.txt")
  actualFirst <- ByteString.readFile target
  assertEqual "writer return" target first
  assertEqual "first complete bytes" expected actualFirst
  _ <- writeChecklist (target, checklist)
  actualSecond <- ByteString.readFile target
  assertEqual "retry replaces without append" expected actualSecond
  let linked = directory </> "linked.txt"
      linkTarget = directory </> "link-target.txt"
  ByteString.writeFile linkTarget "untouched"
  createFileLink linkTarget linked
  assertThrows "reject symlink" (writeChecklist (linked, checklist))
  assertEqual "symlink target untouched" "untouched" =<< ByteString.readFile linkTarget
  let nonregular = directory </> "directory-target"
  createDirectory nonregular
  assertThrows "reject nonregular" (writeChecklist (nonregular, checklist))
  ByteString.writeFile target "old-complete-content"
  let readExecute = ownerReadMode `unionFileModes` ownerExecuteMode
      readWriteExecute = readExecute `unionFileModes` ownerWriteMode
  setFileMode directory readExecute
  failed <- try (writeChecklist (target, checklist))
  setFileMode directory readWriteExecute
  case (failed :: Either SomeException FilePath) of
    Left _ -> pure ()
    Right _ -> fail "write unexpectedly succeeded in non-writable directory"
  assertEqual "failed write preserved target" "old-complete-content" =<< ByteString.readFile target

workflowResume :: IO ()
workflowResume = withTestDirectory "resume" $ \directory -> do
  bytes <- readFixture
  let output = directory </> "result.txt"
      workflowRequest = request {outputPath = output}
      config = RunConfig directory (ExecutionId "offline-resume") weatherWorkflowName weatherWorkflowVersion
  source <- either (fail . show) pure (parseForecast workflowRequest (forecastUrl workflowRequest) timestamp bytes)
  fetches <- newIORef (0 :: Int)
  writes <- newIORef (0 :: Int)
  let effects = WeatherEffects
        { getForecast = \_ -> writeIORef fetches 1 >> pure source
        , putChecklist = \input -> do
            count <- readIORef writes
            writeIORef writes (count + 1)
            if count == 0 then fail "injected writer failure" else writeChecklist input
        }
  assertThrows "first workflow fails at writer" (runWorkflow config workflowRequest (weatherPreparationWith effects))
  assertEqual "one fetch before resume" 1 =<< readIORef fetches
  result <- runWorkflow config workflowRequest (weatherPreparationWith effects)
  assertEqual "resume output" output result
  assertEqual "fetch replayed" 1 =<< readIORef fetches
  assertEqual "writer retried once" 2 =<< readIORef writes
  assertEqual "saved timestamp rendered" True . ByteString8.isInfixOf "2026-09-14T12:34:56Z" =<< ByteString.readFile output
  removeFile output
  _ <- runWorkflow config workflowRequest (weatherPreparationWith effects)
  exists <- doesFileExist output
  assertEqual "committed writer skipped when artifact absent" False exists
  assertEqual "writer still not rerun" 2 =<< readIORef writes

  let repeatedOutput = directory </> "repeated-effect.txt"
      repeatedRequest = request {outputPath = repeatedOutput}
      repeatedConfig = RunConfig directory (ExecutionId "offline-repeated-effect") weatherWorkflowName weatherWorkflowVersion
      repeatedSource = source {forecastRequest = repeatedRequest}
  repeatedWrites <- newIORef (0 :: Int)
  let repeatedEffects = WeatherEffects
        { getForecast = const (pure repeatedSource)
        , putChecklist = \input -> do
            path <- writeChecklist input
            count <- readIORef repeatedWrites
            writeIORef repeatedWrites (count + 1)
            if count == 0 then fail "effect completed before checkpoint failure" else pure path
        }
  assertThrows "completed external effect can precede checkpoint failure"
    (runWorkflow repeatedConfig repeatedRequest (weatherPreparationWith repeatedEffects))
  firstEffectBytes <- ByteString.readFile repeatedOutput
  _ <- runWorkflow repeatedConfig repeatedRequest (weatherPreparationWith repeatedEffects)
  secondEffectBytes <- ByteString.readFile repeatedOutput
  assertEqual "repeated effect remains one complete checklist" firstEffectBytes secondEffectBytes
  assertEqual "uncommitted effect repeated once" 2 =<< readIORef repeatedWrites

replaceUtf8 :: Text -> Text -> ByteString.ByteString -> ByteString.ByteString
replaceUtf8 needle replacement = replace (TextEncoding.encodeUtf8 needle) (TextEncoding.encodeUtf8 replacement)

replace :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replace needle replacement source =
  let (before, after) = ByteString.breakSubstring needle source
   in if ByteString.null after
        then error ("test replacement did not match: " <> show needle)
        else before <> replacement <> ByteString.drop (ByteString.length needle) after
