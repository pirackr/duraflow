{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception (fromException, toException)
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , bracket
  , catch
  , finally
  , mask
  , onException
  , throwIO
  , try
  )
import Control.Monad (forM_, unless)
import Data.Aeson (FromJSON, eitherDecode, eitherDecodeFileStrict', eitherDecodeStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Duraflow (ExecutionId (..), RunConfig (..), runWorkflow)
import GHC.Generics (Generic)
import System.Directory
  ( Permissions (executable)
  , canonicalizePath
  , createDirectory
  , createDirectoryLink
  , createFileLink
  , doesFileExist
  , getPermissions
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  , setPermissions
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (WriteMode), hClose, openFile, openTempFile)
import System.IO.Error (catchIOError)
import System.Posix.Files (ownerExecuteMode, ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Posix.Types (ProcessID)
import System.Process
  ( CreateProcess (create_group, cwd, env, std_err, std_out)
  , ProcessHandle
  , StdStream (UseHandle)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import WeatherWorkflow hiding (main)

main :: IO ()
main = do
  runSection "Forecast behavior" runForecastTests
  runSection "Advice and rendering" runAdviceTests
  runSection "CLI functions" runCliTests
  runSection "Workflow integration" runIntegrationTests
  runSection "CLI subprocess validation" runCliSubprocessTests
  putStrLn "All weather application tests passed."

runSection :: String -> IO () -> IO ()
runSection name tests = do
  putStrLn ("[----------] " <> name)
  tests

-- Forecast parsing, transport, cancellation, and output safety

runForecastTests :: IO ()
runForecastTests = do
  runCase "forecast parses requested row and round-trips" parsingRoundTrip
  runCase "legacy saved forecast JSON remains replay-decodable" legacyForecastJson
  runCase "forecast rejects malformed and structurally invalid responses" structuralFailures
  runCase "forecast rejects every invalid unit" unitFailures
  runCase "forecast rejects invalid coordinates and metrics" valueFailures
  runCase "forecast reports independent metric failures in rule order" aggregateMetricFailures
  runCase "validation helper and direct metric rules" validationRules
  runCase "forecast validates unselected rows" unselectedRowFailure
  runCase "forecast transport status, deadline, clock, and cancellation" transportFailures
  runCase "checklist writer safely replaces real files" writerCases

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

legacyForecastJson :: IO ()
legacyForecastJson = do
  let legacy :: Text
      legacy = "{\"forecastRequest\":{\"forecastDate\":\"2026-09-15\",\"outputPath\":\"/tmp/checklist.txt\",\"requestedLatitude\":47.6062,\"requestedLongitude\":-122.3321},\"forecastUnits\":{\"precipitationUnit\":\"%\",\"temperatureUnit\":\"°C\",\"timeUnit\":\"iso8601\",\"uvUnit\":\"\",\"windUnit\":\"km/h\"},\"maximumTemperature\":17.5,\"maximumUvIndex\":3.2,\"maximumWindSpeed\":41,\"minimumTemperature\":5,\"provider\":\"Open-Meteo\",\"providerLatitude\":47.625,\"providerLongitude\":-122.375,\"rainProbability\":60,\"requestUrl\":\"legacy-url\",\"retrievedAt\":\"2026-09-14T12:34:56Z\"}"
      decoded = eitherDecodeStrict' (TextEncoding.encodeUtf8 legacy) :: Either String Forecast
  forecast <- either fail pure decoded
  assertEqual "legacy task output fields" ("legacy-url", timestamp, request)
    (requestUrl forecast, retrievedAt forecast, forecastRequest forecast)
  assertEqual "legacy output drives deterministic replay computation"
    ["Bring rain protection.", "Bring warm layers.", "Secure loose outdoor items and prepare for wind.", "Use sun protection."]
    (checklistItems (prepareAdvice forecast))

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

validationRules :: IO ()
validationRules = do
  assertEqual "empty rules return original value" (Right (42 :: Int)) (validate 42 [])
  assertEqual "successful rules return original value" (Right ("weather" :: Text))
    (validate "weather" [(True, "ignored")])
  assertEqual "failed rules preserve order" (Left ["first", "third"])
    (validate () [(False, "first"), (True, "second"), (False, "third")])
  assertBool "equal temperatures are accepted" $
    not (isLeft (validateDailyRow (DailyMetrics (TemperatureRange 10 10) 0 0 0)))
  assertEqual "direct nonfinite metrics are rejected without dependent diagnostics"
    (Left ["forecast metric must be finite"])
    (validateDailyRow (DailyMetrics (TemperatureRange (0 / 0) 10) 0 0 0))

unselectedRowFailure :: IO ()
unselectedRowFailure = do
  bytes <- readFixture
  let invalid = replace "[12.4, 41.0]" "[-1, 41.0]" bytes
  assertEqual "unselected row diagnostic" (Left "Error in $: wind speed is negative")
    (parseForecast request (forecastUrl request) timestamp invalid)

aggregateMetricFailures :: IO ()
aggregateMetricFailures = do
  bytes <- readFixture
  let invalid =
        replace "[2.0, 3.2]" "[2.0, -1]"
          . replace "[12.4, 41.0]" "[12.4, -1]"
          . replace "[20, 60]" "[20, 101]"
          . replace "[11.2, 5.0]" "[11.2, 18]"
          $ bytes
      expected = Left (Text.intercalate "\n"
        [ "Error in $: minimum temperature exceeds maximum temperature"
        , "rain probability is outside 0 through 100"
        , "wind speed is negative"
        , "UV index is negative"
        ])
  assertEqual "aggregate metric diagnostics" expected
    (parseForecast request (forecastUrl request) timestamp invalid)

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
  started <- newEmptyMVar
  blocked <- newEmptyMVar
  result <- newEmptyMVar
  thread <- forkIO $ do
    outcome <- try (fetchForecastWith 10000000 (\_ -> putMVar started () >> takeMVar blocked) clock request)
    putMVar result (outcome :: Either SomeException Forecast)
  within "transport starts" (takeMVar started)
  within "synchronous cancellation delivery" (killThread thread)
  cancelled <- within "cancelled transport completes" (takeMVar result)
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

replaceUtf8 :: Text -> Text -> ByteString.ByteString -> ByteString.ByteString
replaceUtf8 needle replacement = replace (TextEncoding.encodeUtf8 needle) (TextEncoding.encodeUtf8 replacement)

replace :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replace needle replacement source =
  let (before, after) = ByteString.breakSubstring needle source
   in if ByteString.null after
        then error ("test replacement did not match: " <> show needle)
        else before <> replacement <> ByteString.drop (ByteString.length needle) after

-- Advice thresholds and golden rendering

runAdviceTests :: IO ()
runAdviceTests = do
  runCase "advice thresholds and immediate outside values" thresholdCases
  runCase "advice combinations preserve fixed order" combinationCases
  runCase "checklist rendering matches exact UTF-8 golden" renderingCase

mildForecast :: Forecast
mildForecast = Forecast
  { forecastRequest = WeatherRequest 47.6062 (-122.3321) (fromGregorian 2026 9 15) "/tmp/checklist.txt"
  , forecastUnits = ForecastUnits "iso8601" "°C" "%" "km/h" ""
  , providerLatitude = 47.625
  , providerLongitude = -122.375
  , minimumTemperature = 10
  , maximumTemperature = 20
  , rainProbability = 0
  , maximumWindSpeed = 0
  , maximumUvIndex = 0
  , provider = "Open-Meteo"
  , requestUrl = "https://api.open-meteo.com/v1/forecast?fixture"
  , retrievedAt = UTCTime (fromGregorian 2026 9 14) (secondsToDiffTime 45296)
  }

thresholdCases :: IO ()
thresholdCases = do
  assertEqual "fallback" ["No additional preparation was identified by these rules."] (items mildForecast)
  assertEqual "rain threshold" ["Bring rain protection."] (items mildForecast {rainProbability = 50})
  assertEqual "rain just below" ["No additional preparation was identified by these rules."] (items mildForecast {rainProbability = 49.99})
  assertEqual "cold threshold" ["Bring warm layers."] (items mildForecast {minimumTemperature = 5})
  assertEqual "cold just above" ["No additional preparation was identified by these rules."] (items mildForecast {minimumTemperature = 5.01})
  assertEqual "wind threshold" ["Secure loose outdoor items and prepare for wind."] (items mildForecast {maximumWindSpeed = 40})
  assertEqual "wind just below" ["No additional preparation was identified by these rules."] (items mildForecast {maximumWindSpeed = 39.99})
  assertEqual "UV threshold" ["Use sun protection."] (items mildForecast {maximumUvIndex = 3})
  assertEqual "UV just below" ["No additional preparation was identified by these rules."] (items mildForecast {maximumUvIndex = 2.99})

combinationCases :: IO ()
combinationCases = do
  let allWeather = mildForecast
        { rainProbability = 50
        , minimumTemperature = 5
        , maximumWindSpeed = 40
        , maximumUvIndex = 3
        }
  assertEqual "every rule fixed order"
    [ "Bring rain protection."
    , "Bring warm layers."
    , "Secure loose outdoor items and prepare for wind."
    , "Use sun protection."
    ]
    (items allWeather)
  assertEqual "nonadjacent combination"
    ["Bring rain protection.", "Use sun protection."]
    (items mildForecast {rainProbability = 80, maximumUvIndex = 8})
  assertEqual "single fallback only" 1 (length (items mildForecast))

renderingCase :: IO ()
renderingCase = do
  golden <- ByteString.readFile (fixturePath "checklist.txt")
  let renderedForecast = mildForecast
        { minimumTemperature = 5
        , maximumTemperature = 17.5
        , rainProbability = 60
        , maximumWindSpeed = 41
        , maximumUvIndex = 3.2
        }
      actual = TextEncoding.encodeUtf8 (renderChecklist (prepareAdvice renderedForecast))
  assertEqual "exact rendered bytes" golden actual
  let checklist = prepareAdvice renderedForecast
  assertEqual "checklist JSON round trip" (Right checklist) (eitherDecode (encode checklist))
  assertBool "one final newline" (ByteString.isSuffixOf "\n" actual && not (ByteString.isSuffixOf "\n\n" actual))
  assertBool "LF only" (not (ByteString.elem 13 actual))

items :: Forecast -> [Text]
items = checklistItems . prepareAdvice

-- CLI parsing, path validation, and cancellation

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
  takeOutput weatherRequest = outputPath weatherRequest

normalizeUnsafePaths :: IO ()
normalizeUnsafePaths = withTestDirectory "cli-unsafe" $ \root -> do
  let state = root </> "state"
      outside = root </> "outside"
      requestFor path = WeatherRequest 1 2 (fromGregorian 2026 9 15) path
      normalize path = normalizeInvocation (state, ExecutionId "weather-001", requestFor path)
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

-- Offline workflow integration and replay

runIntegrationTests :: IO ()
runIntegrationTests = do
  runCase "three-task workflow resumes offline" workflowResume
  runCase "external effect repeats safely before checkpoint" repeatedExternalEffect

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

-- Real CLI subprocess validation

data CliScenario = CliScenario
  { scenarioLabel :: String
  , scenarioExecution :: String
  , scenarioDiagnostic :: String
  , scenarioArguments :: FilePath -> FilePath -> [String]
  }

runCliSubprocessTests :: IO ()
runCliSubprocessTests = withTestDirectory "cli-subprocess" $ \temporary -> do
  repositoryRoot <- canonicalizePath "."
  let state = temporary </> "state"
      outside = temporary </> "outside"
  createDirectory state
  createDirectory outside
  createDirectoryLink state (temporary </> "state-alias")
  writeFile (outside </> "target.txt") "untouched\n"
  createFileLink (outside </> "target.txt") (outside </> "linked.txt")
  createFileLink (outside </> "missing-target.txt") (outside </> "dangling.txt")
  createDirectory (outside </> "directory-output")
  runCase "CLI assertion rejects compiler startup failure" $
    compilerFailureGuard repositoryRoot temporary state
  forM_ cliScenarios $ \scenario ->
    runCase ("standalone " <> scenarioLabel scenario) $
      runCliScenario repositoryRoot temporary state outside scenario

cliScenarios :: [CliScenario]
cliScenarios =
  [ CliScenario "missing arguments" "missing"
      "expected six arguments: STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE"
      (\_ _ -> [])
  , CliScenario "invalid latitude" "bad-latitude"
      "latitude is outside its geographic range"
      (\state outside -> standardArguments "bad-latitude" "91" "2026-09-15" (outsideReport state outside))
  , CliScenario "invalid date" "bad-date"
      "forecast date must be a valid YYYY-MM-DD calendar date"
      (\state outside -> standardArguments "bad-date" "47.6062" "2026-02-29" (outsideReport state outside))
  , CliScenario "output inside state" "inside-state"
      "output file must be outside the state directory"
      (\state _ -> standardArguments "inside-state" "47.6062" "2026-09-15" (state, state </> "report.txt"))
  , CliScenario "state directory alias" "state-alias"
      "output file must be outside the state directory"
      (\_ outside -> standardArguments "state-alias" "47.6062" "2026-09-15"
        (takeDirectory outside </> "state-alias", takeDirectory outside </> "state" </> "alias-report.txt"))
  , CliScenario "symlink output" "symlink-output"
      "output entry is not a regular file"
      (\state outside -> standardArguments "symlink-output" "47.6062" "2026-09-15" (constOutput "linked.txt" state outside))
  , CliScenario "dangling symlink output" "dangling-output"
      "output entry is not a regular file"
      (\state outside -> standardArguments "dangling-output" "47.6062" "2026-09-15" (constOutput "dangling.txt" state outside))
  , CliScenario "nonregular output" "nonregular-output"
      "output entry is not a regular file"
      (\state outside -> standardArguments "nonregular-output" "47.6062" "2026-09-15" (constOutput "directory-output" state outside))
  , CliScenario "absent output parent" "absent-parent"
      "output parent directory does not exist or is not a directory"
      (\state _ -> standardArguments "absent-parent" "47.6062" "2026-09-15"
        (state, takeDirectory state </> "missing" </> "report.txt"))
  ]
 where
  outsideReport state outside = (state, outside </> "report.txt")
  constOutput name state outside = (state, outside </> name)

standardArguments :: String -> String -> String -> (FilePath, FilePath) -> [String]
standardArguments execution latitude date (state, output) =
  [state, execution, latitude, "-122.3321", date, output]

runCliScenario :: FilePath -> FilePath -> FilePath -> FilePath -> CliScenario -> IO ()
runCliScenario repositoryRoot temporary state outside scenario = do
  result <- runWeatherCommand repositoryRoot temporary Nothing
    (scenarioArguments scenario state outside)
  assertCliResult state (scenarioExecution scenario) (scenarioDiagnostic scenario) result

compilerFailureGuard :: FilePath -> FilePath -> FilePath -> IO ()
compilerFailureGuard repositoryRoot temporary state = do
  let stubDirectory = temporary </> "failure-stub"
      stub = stubDirectory </> "stack"
  createDirectory stubDirectory
  writeFile stub "#!/usr/bin/env sh\nprintf '%s\\n' 'simulated compiler failure before Main loads' >&2\nexit 1\n"
  permissions <- getPermissions stub
  setPermissions stub permissions {executable = True}
  environment <- getEnvironment
  let path = maybe stubDirectory ((stubDirectory <> ":") <>) (lookup "PATH" environment)
      stubEnvironment = ("PATH", path) : filter ((/= "PATH") . fst) environment
      expected = "expected six arguments: STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE"
  result <- runWeatherCommand repositoryRoot temporary (Just stubEnvironment) []
  rejected <- try (assertCliResult state "compiler-failure" expected result)
  case (rejected :: Either TestFailure ()) of
    Left _ -> pure ()
    Right () -> throwIO (TestFailure "CLI result assertion accepted compiler startup failure")
  subprocessCleanupRegressions temporary

subprocessCleanupRegressions :: FilePath -> IO ()
subprocessCleanupRegressions temporary = do
  timeoutProbe <- prepareProbe temporary "timeout-probe"
  testTimeoutCleanup timeoutProbe `finally` forceProbeCleanup timeoutProbe
  cancellationProbe <- prepareProbe temporary "cancellation-probe"
  testCancellationCleanup cancellationProbe `finally` forceProbeCleanup cancellationProbe

data Probe = Probe
  { probeDirectory :: FilePath
  , probeLeaderPath :: FilePath
  , probeDescendantPath :: FilePath
  , probeReadyPath :: FilePath
  }

prepareProbe :: FilePath -> String -> IO Probe
prepareProbe temporary name = do
  let directory = temporary </> name
  createDirectory directory
  pure Probe
    { probeDirectory = directory
    , probeLeaderPath = directory </> "leader.pid"
    , probeDescendantPath = directory </> "descendant.pid"
    , probeReadyPath = directory </> "ready"
    }

probeCommand :: Probe -> CreateProcess
probeCommand probe = proc "sh"
  [ "-c"
  , "trap '' TERM; echo $$ > \"$1\"; sh -c 'trap \"\" TERM; echo $$ > \"$1\"; touch \"$2\"; while :; do sleep 1; done' _ \"$2\" \"$3\" & wait"
  , "_"
  , probeLeaderPath probe
  , probeDescendantPath probe
  , probeReadyPath probe
  ]

awaitProbeReady :: Probe -> IO ()
awaitProbeReady probe = within "cleanup probe readiness" $ do
  ready <- doesFileExist (probeReadyPath probe)
  if ready then pure () else threadDelay 10000 >> awaitProbeReady probe

testTimeoutCleanup :: Probe -> IO ()
testTimeoutCleanup probe = do
  result <- newEmptyMVar
  _ <- forkIO $ do
    outcome <- try (runCapturedCommand 1000000 (probeDirectory probe) (probeCommand probe))
    putMVar result (outcome :: Either TestFailure CliResult)
  awaitProbeReady probe
  outcome <- within "timed out subprocess runner completes" (takeMVar result)
  case outcome of
    Left (TestFailure message) -> assertEqual "timeout remains a test failure" "CLI child process timed out" message
    Right _ -> throwIO (TestFailure "timed out child returned a successful test result")
  assertProbeGroupGone probe

testCancellationCleanup :: Probe -> IO ()
testCancellationCleanup probe = do
  result <- newEmptyMVar
  runner <- forkIO $ do
    outcome <- try (runCapturedCommand (10 * 1000 * 1000) (probeDirectory probe) (probeCommand probe))
    putMVar result (outcome :: Either SomeException CliResult)
  awaitProbeReady probe
  killThread runner
  outcome <- within "cancelled subprocess runner completes" (takeMVar result)
  assertBool "original subprocess cancellation preserved" $ case outcome of
    Left exception -> fromException exception == Just ThreadKilled
    Right _ -> False
  assertProbeGroupGone probe

assertProbeGroupGone :: Probe -> IO ()
assertProbeGroupGone probe = do
  leader <- readProbePid (probeLeaderPath probe)
  descendant <- readProbePid (probeDescendantPath probe)
  within "subprocess group cleanup" $ do
    groupAlive <- processGroupExists leader
    descendantAlive <- processExists descendant
    if groupAlive || descendantAlive
      then threadDelay 10000 >> assertProbeGroupGone probe
      else pure ()

readProbePid :: FilePath -> IO ProcessID
readProbePid path = read <$> readFileStrict path

processGroupExists :: ProcessID -> IO Bool
processGroupExists processId =
  (signalProcessGroup nullSignal processId >> pure True) `catchIOError` \_ -> pure False

processExists :: ProcessID -> IO Bool
processExists processId =
  (signalProcess nullSignal processId >> pure True) `catchIOError` \_ -> pure False

forceProbeCleanup :: Probe -> IO ()
forceProbeCleanup probe = do
  leaderExists <- doesFileExist (probeLeaderPath probe)
  if leaderExists
    then readProbePid (probeLeaderPath probe) >>= signalGroupIgnoringMissing sigKILL
    else pure ()

data CliResult = CliResult ExitCode String String

runWeatherCommand :: FilePath -> FilePath -> Maybe [(String, String)] -> [String] -> IO CliResult
runWeatherCommand repositoryRoot workingDirectory commandEnvironment applicationArguments = do
  let stackYaml = repositoryRoot </> "stack.yaml"
      source = repositoryRoot </> "workflows" </> "WeatherWorkflow.hs"
      includePath = "-i" <> repositoryRoot </> "workflows"
      arguments =
        [ "--stack-yaml", stackYaml
        , "runghc"
        , "--package", "duraflow"
        , "--package", "aeson"
        , "--package", "http-client"
        , "--package", "http-client-tls"
        , "--package", "time"
        , "--"
        , "--ghc-arg=" <> includePath
        , "--ghc-arg=-main-is"
        , "--ghc-arg=WeatherWorkflow.main"
        , source
        ] <> applicationArguments
      stackCommand = case commandEnvironment of
        Nothing -> "stack"
        Just _ -> workingDirectory </> "failure-stub" </> "stack"
      command = (proc stackCommand arguments)
        { cwd = Just workingDirectory
        , env = commandEnvironment
        }
  runCapturedCommand (60 * 1000 * 1000) workingDirectory command

runCapturedCommand :: Int -> FilePath -> CreateProcess -> IO CliResult
runCapturedCommand waitMicros workingDirectory command = do
  let stdoutPath = workingDirectory </> "child.stdout"
      stderrPath = workingDirectory </> "child.stderr"
  exitCode <-
    bracket (openFile stdoutPath WriteMode) hClose $ \stdoutHandle ->
      bracket (openFile stderrPath WriteMode) hClose $ \stderrHandle -> do
        let redirected = command
              { create_group = True
              , std_out = UseHandle stdoutHandle
              , std_err = UseHandle stderrHandle
              }
        mask $ \restore -> do
          (_, _, _, processHandle) <- createProcess redirected
          processId <- getPid processHandle
          restore (waitBounded waitMicros processHandle)
            `onException` stopProcess processId processHandle
  stdoutText <- readFileStrict stdoutPath
  stderrText <- readFileStrict stderrPath
  pure (CliResult exitCode stdoutText stderrText)

waitBounded :: Int -> ProcessHandle -> IO ExitCode
waitBounded waitMicros processHandle = do
  outcome <- timeout waitMicros (waitForProcess processHandle)
  case outcome of
    Just exitCode -> pure exitCode
    Nothing -> throwIO (TestFailure "CLI child process timed out")

stopProcess :: Maybe ProcessID -> ProcessHandle -> IO ()
stopProcess processId processHandle = do
  forM_ processId $ \pid -> signalGroupIgnoringMissing sigTERM pid
  running <- getProcessExitCode processHandle
  reapedAfterTerm <- case running of
    Just exitCode -> pure (Just exitCode)
    Nothing -> timeout 200000 (waitForProcess processHandle)
  groupStillAlive <- case processId of
    Nothing -> pure False
    Just pid -> processGroupExists pid
  if groupStillAlive || reapedAfterTerm == Nothing
    then do
      forM_ processId $ \pid -> signalGroupIgnoringMissing sigKILL pid
      _ <- timeout 1000000 (waitForProcess processHandle)
      pure ()
    else pure ()

signalGroupIgnoringMissing :: Signal -> ProcessID -> IO ()
signalGroupIgnoringMissing signal processId =
  signalProcessGroup signal processId `catchIOError` \_ -> pure ()

readFileStrict :: FilePath -> IO String
readFileStrict path = do
  contents <- readFile path
  length contents `seq` pure contents

assertCliResult :: FilePath -> String -> String -> CliResult -> IO ()
assertCliResult state execution expectedDiagnostic (CliResult exitCode stdoutText stderrText) = do
  assertBool "CLI exits nonzero" (exitCode /= ExitSuccess)
  assertEqual "CLI stdout is empty" "" stdoutText
  let expectedLine = "user error (" <> expectedDiagnostic <> ")"
  assertBool ("CLI exact application diagnostic: " <> expectedDiagnostic)
    (expectedLine `elem` lines stderrText)
  snapshotExists <- doesFileExist (state </> execution <> ".json")
  assertEqual "CLI does not create a snapshot" False snapshotExists

-- Local test support

assertBool :: String -> Bool -> IO ()
assertBool name condition = unless condition (throwIO (TestFailure name))

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  unless (expected == actual) $
    throwIO (TestFailure (name <> ": expected " <> show expected <> ", actual " <> show actual))

assertLeft :: Show b => String -> Either a b -> IO ()
assertLeft name result = case result of
  Left _ -> pure ()
  Right actual -> throwIO (TestFailure (name <> ": expected Left, actual Right " <> show actual))

assertThrows :: String -> IO a -> IO ()
assertThrows name action = do
  threw <- (action >> pure False) `catch` (\(_ :: SomeException) -> pure True)
  unless threw (throwIO (TestFailure (name <> ": expected exception, actual success")))

fixturePath :: FilePath -> FilePath
fixturePath name = "workflows/test/fixtures/" <> name

runCase :: String -> IO () -> IO ()
runCase name action = do
  putStrLn ("[ RUN      ] " <> name)
  action
  putStrLn ("[       OK ] " <> name)

within :: String -> IO value -> IO value
within label action = do
  result <- timeout (10 * 1000 * 1000) action
  case result of
    Nothing -> throwIO (TestFailure (label <> " timed out"))
    Just value -> pure value

withTestDirectory :: String -> (FilePath -> IO a) -> IO a
withTestDirectory label = bracket acquire removeDirectoryRecursive
 where
  acquire = do
    base <- getTemporaryDirectory
    (path, handle) <- openTempFile base ("weather-" <> label)
    hClose handle
    removeFile path
    createDirectory path
    pure path

newtype TestFailure = TestFailure String deriving (Show)
instance Exception TestFailure
