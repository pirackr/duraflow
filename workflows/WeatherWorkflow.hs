{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module WeatherWorkflow where

import Control.DeepSeq (NFData, force)
import Control.Exception
    ( IOException
    , SomeAsyncException
    , SomeException
    , catch
    , displayException
    , evaluate
    , fromException
    , throwIO
    )
import Control.Monad (unless, when)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (findIndex, zip5)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time
    ( Day
    , UTCTime (..)
    , defaultTimeLocale
    , formatTime
    , fromGregorian
    , getCurrentTime
    , parseTimeM
    )
import Duraflow
    ( ExecutionId (..)
    , RunConfig (..)
    , TaskId (..)
    , Workflow
    , runWorkflow
    , task
    , writeFileDurably
    )
import GHC.Generics (Generic)
import Network.HTTP.Client
    ( Request (..)
    , defaultRequest
    , getUri
    , httpLbs
    , newManager
    , parseRequest
    , responseBody
    , responseStatus
    , responseTimeoutNone
    , setQueryString
    )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (normalise, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus, isRegularFile)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- All weather application code intentionally lives in this runnable module.
data WeatherRequest = WeatherRequest
    { requestedLatitude :: Double
    , requestedLongitude :: Double
    , forecastDate :: Day
    , outputPath :: FilePath
    }
    deriving (Eq, Show, Generic, ToJSON, FromJSON, NFData)

data ForecastUnits = ForecastUnits
    { timeUnit :: Text
    , temperatureUnit :: Text
    , precipitationUnit :: Text
    , windUnit :: Text
    , uvUnit :: Text
    }
    deriving (Eq, Show, Generic, ToJSON, FromJSON, NFData)

data Forecast = Forecast
    { forecastRequest :: WeatherRequest
    , forecastUnits :: ForecastUnits
    , providerLatitude :: Double
    , providerLongitude :: Double
    , minimumTemperature :: Double
    , maximumTemperature :: Double
    , rainProbability :: Double
    , maximumWindSpeed :: Double
    , maximumUvIndex :: Double
    , provider :: Text
    , requestUrl :: Text
    , retrievedAt :: UTCTime
    }
    deriving (Eq, Show, Generic, ToJSON, FromJSON, NFData)

data Checklist = Checklist
    { checklistForecast :: Forecast
    , checklistItems :: [Text]
    }
    deriving (Eq, Show, Generic, ToJSON, FromJSON, NFData)

data WeatherEffects = WeatherEffects
    { getForecast :: WeatherRequest -> IO Forecast
    , putChecklist :: (FilePath, Checklist) -> IO FilePath
    }

weatherWorkflowName, weatherWorkflowVersion :: Text
weatherWorkflowName = "weatherPreparation"
weatherWorkflowVersion = "1"

weatherPreparationWith :: WeatherEffects -> WeatherRequest -> Workflow FilePath
weatherPreparationWith effects request = do
    forecast <- task (TaskId "fetchForecast") request effects.getForecast
    checklist <- task (TaskId "prepareAdvice") forecast (pure . prepareAdvice)
    task (TaskId "writeChecklist") (request.outputPath, checklist) effects.putChecklist

weatherPreparation :: WeatherRequest -> Workflow FilePath
weatherPreparation =
    weatherPreparationWith
        WeatherEffects
            { getForecast = fetchForecast
            , putChecklist = writeChecklist
            }

forecastUrl :: WeatherRequest -> Text
forecastUrl request = Text.pack (show (getUri configured))
  where
    configured =
        setQueryString
            query
            defaultRequest
                { secure = True
                , host = "api.open-meteo.com"
                , port = 443
                , path = "/v1/forecast"
                }
    encodedDate = ByteString8.pack (show request.forecastDate)
    query =
        [ ("latitude", Just (number request.requestedLatitude))
        , ("longitude", Just (number request.requestedLongitude))
        , ("start_date", Just encodedDate)
        , ("end_date", Just encodedDate)
        , ("timezone", Just "UTC")
        , ("temperature_unit", Just "celsius")
        , ("wind_speed_unit", Just "kmh")
        , ("daily", Just "temperature_2m_min,temperature_2m_max,precipitation_probability_max,wind_speed_10m_max,uv_index_max")
        ]
    number = ByteString8.pack . show

parseForecast :: WeatherRequest -> Text -> UTCTime -> ByteString.ByteString -> Either Text Forecast
parseForecast request url timestamp bytes =
    firstText (eitherDecodeStrict' bytes) >>= \value ->
        firstText (parseEither (forecastParser request url timestamp) value)

forecastParser :: WeatherRequest -> Text -> UTCTime -> Value -> Parser Forecast
forecastParser request url timestamp = withObject "forecast response" $ \object -> do
    latitude <- object .: "latitude"
    longitude <- object .: "longitude"
    offset <- object .: "utc_offset_seconds"
    units <- object .: "daily_units"
    daily <- object .: "daily"
    either (fail . Text.unpack . Text.intercalate "\n") pure $
        validate () $
            [ (offset == (0 :: Int), "UTC offset must be zero")
            ]
                <> coordinateRules "requested" request.requestedLatitude request.requestedLongitude
                <> coordinateRules "provider" latitude longitude
    parseDaily request url timestamp latitude longitude units daily

parseDaily :: WeatherRequest -> Text -> UTCTime -> Double -> Double -> Object -> Object -> Parser Forecast
parseDaily request url timestamp latitude longitude units daily = do
    timeU <- units .: "time"
    minU <- units .: "temperature_2m_min"
    maxU <- units .: "temperature_2m_max"
    rainU <- units .: "precipitation_probability_max"
    windU <- units .: "wind_speed_10m_max"
    uvU <- units .: "uv_index_max"
    dates <- daily .: "time"
    mins <- daily .: "temperature_2m_min"
    maxs <- daily .: "temperature_2m_max"
    rains <- daily .: "precipitation_probability_max"
    winds <- daily .: "wind_speed_10m_max"
    uvs <- daily .: "uv_index_max"
    either (fail . Text.unpack . Text.intercalate "\n") pure $ do
        validateUnits [timeU, minU, maxU, rainU, windU, uvU]
        let lengths = [length dates, length mins, length maxs, length rains, length winds, length uvs]
        validate ()
            [ (not (null dates) && all (== length dates) lengths, "daily arrays must have equal nonzero lengths")
            ]
        validateDailyRows (zip5 mins maxs rains winds uvs)
        position <- maybe (Left ["requested forecast date is absent"]) Right (findIndex (== request.forecastDate) dates)
        let at xs = xs !! position
        pure
            Forecast
                { forecastRequest = request
                , forecastUnits = ForecastUnits timeU minU rainU windU uvU
                , providerLatitude = latitude
                , providerLongitude = longitude
                , minimumTemperature = at mins
                , maximumTemperature = at maxs
                , rainProbability = at rains
                , maximumWindSpeed = at winds
                , maximumUvIndex = at uvs
                , provider = "Open-Meteo"
                , requestUrl = url
                , retrievedAt = timestamp
                }

data TemperatureRange = TemperatureRange
    { minimum :: Double
    , maximum :: Double
    }
    deriving (Eq, Show)

data DailyMetrics = DailyMetrics
    { temperature :: TemperatureRange
    , rain :: Double
    , wind :: Double
    , uv :: Double
    }
    deriving (Eq, Show)

validate :: value -> [(Bool, Text)] -> Either [Text] value
validate value rules =
    case [message | (passed, message) <- rules, not passed] of
        [] -> Right value
        errors -> Left errors

validateDailyRows :: [(Double, Double, Double, Double, Double)] -> Either [Text] ()
validateDailyRows rows =
    case concatMap (either id (const []) . validateDailyRow . toMetrics) rows of
        [] -> Right ()
        errors -> Left errors
  where
    toMetrics (minimumValue, maximumValue, rainValue, windValue, uvValue) =
        DailyMetrics (TemperatureRange minimumValue maximumValue) rainValue windValue uvValue

validateDailyRow :: DailyMetrics -> Either [Text] DailyMetrics
validateDailyRow metrics = validate metrics
    [ (finite temperature.minimum, "forecast metric must be finite")
    , (finite temperature.maximum, "forecast metric must be finite")
    , (finite metrics.rain, "forecast metric must be finite")
    , (finite metrics.wind, "forecast metric must be finite")
    , (finite metrics.uv, "forecast metric must be finite")
    , (not temperaturesFinite || temperature.maximum >= temperature.minimum, "minimum temperature exceeds maximum temperature")
    , (not (finite metrics.rain) || metrics.rain >= 0 && metrics.rain <= 100, "rain probability is outside 0 through 100")
    , (not (finite metrics.wind) || metrics.wind >= 0, "wind speed is negative")
    , (not (finite metrics.uv) || metrics.uv >= 0, "UV index is negative")
    ]
  where
    temperature = metrics.temperature
    temperaturesFinite = finite temperature.minimum && finite temperature.maximum

validateCoordinates :: Text -> Double -> Double -> Either [Text] ()
validateCoordinates label latitude longitude =
    validate () (coordinateRules label latitude longitude)

coordinateRules :: Text -> Double -> Double -> [(Bool, Text)]
coordinateRules label latitude longitude =
    [ (finite latitude, label <> " latitude must be finite")
    , (finite longitude, label <> " longitude must be finite")
    , (not (finite latitude) || latitude >= -90 && latitude <= 90, label <> " latitude is outside geographic bounds")
    , (not (finite longitude) || longitude >= -180 && longitude <= 180, label <> " longitude is outside geographic bounds")
    ]

finite :: Double -> Bool
finite value = not (isNaN value || isInfinite value)

validateUnits :: [Text] -> Either [Text] ()
validateUnits actual = validate ()
    [ (wanted == found, label <> " unit is unexpected")
    | (label, wanted, found) <- zip3 labels expected actual
    ]
  where
    labels = ["time", "minimum temperature", "maximum temperature", "precipitation probability", "wind speed", "UV index"]
    expected = ["iso8601", "°C", "°C", "%", "km/h", ""]

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right

fetchForecastWith :: Int -> (Text -> IO (Int, ByteString.ByteString)) -> IO UTCTime -> WeatherRequest -> IO Forecast
fetchForecastWith deadline transport clock request = do
    completed <- timeout deadline $ do
        (status, bytes) <- transport url
        unless (status >= 200 && status < 300) $ ioError (userError ("forecast request returned HTTP status " <> show status))
        let dummyTimestamp = UTCTime (fromGregorian 1858 11 17) 0
        parsed <- either (ioError . userError . Text.unpack) pure (parseForecast request url dummyTimestamp bytes)
        validated <- evaluate (force parsed)
        timestamp <- clock
        evaluate (force validated{retrievedAt = timestamp})
    maybe (ioError (userError "forecast request exceeded its elapsed-time deadline")) pure completed
  where
    url = forecastUrl request

fetchForecast :: WeatherRequest -> IO Forecast
fetchForecast = fetchForecastWith 30000000 productionTransport getCurrentTime

productionTransport :: Text -> IO (Int, ByteString.ByteString)
productionTransport url = do
    manager <- newManager tlsManagerSettings
    request <- parseRequest (Text.unpack url)
    response <- httpLbs request{redirectCount = 0, responseTimeout = responseTimeoutNone, checkResponse = \_ _ -> pure ()} manager
    pure (statusCode (responseStatus response), LazyByteString.toStrict (responseBody response))

prepareAdvice :: Forecast -> Checklist
prepareAdvice forecast = Checklist forecast (if null advice then ["No additional preparation was identified by these rules."] else advice)
  where
    advice =
        [ item
        | (applies, item) <-
            [ (rainProbability forecast >= 50, "Bring rain protection.")
            , (minimumTemperature forecast <= 5, "Bring warm layers.")
            , (maximumWindSpeed forecast >= 40, "Secure loose outdoor items and prepare for wind.")
            , (maximumUvIndex forecast >= 3, "Use sun protection.")
            ]
        , applies
        ]

renderChecklist :: Checklist -> Text
renderChecklist Checklist{checklistForecast = forecast, checklistItems} =
    Text.unlines
        ( [ "Weather preparation checklist"
          , "Forecast date (" <> timeUnit units <> "): " <> showText (forecastDate request)
          , "Requested coordinates: latitude " <> showText (requestedLatitude request) <> ", longitude " <> showText (requestedLongitude request)
          , "Provider coordinates: latitude " <> showText (providerLatitude forecast) <> ", longitude " <> showText (providerLongitude forecast)
          , "Provider: " <> provider forecast
          , "Retrieved at: " <> Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (retrievedAt forecast))
          , metric "Minimum temperature" (minimumTemperature forecast) (temperatureUnit units)
          , metric "Maximum temperature" (maximumTemperature forecast) (temperatureUnit units)
          , metric "Rain probability" (rainProbability forecast) (precipitationUnit units)
          , metric "Maximum wind speed" (maximumWindSpeed forecast) (windUnit units)
          , metric "Maximum UV index" (maximumUvIndex forecast) (uvUnit units)
          , "Preparation:"
          ]
            <> map ("- " <>) checklistItems
        )
  where
    request = forecastRequest forecast
    units = forecastUnits forecast
    metric label value unit = label <> ": " <> showText value <> if Text.null unit then "" else " " <> unit

writeChecklist :: (FilePath, Checklist) -> IO FilePath
writeChecklist (target, checklist) = do
    writeFileDurably target (Text.encodeUtf8 (renderChecklist checklist))
    pure target

showText :: (Show value) => value -> Text
showText = Text.pack . show

parseArguments :: [String] -> Either Text (FilePath, ExecutionId, WeatherRequest)
parseArguments arguments = case arguments of
    [state, execution, latitudeText, longitudeText, dateText, output] -> do
        latitude <- parseCoordinate "latitude" (-90) 90 latitudeText
        longitude <- parseCoordinate "longitude" (-180) 180 longitudeText
        day <- parseDate dateText
        pure (state, ExecutionId (Text.pack execution), WeatherRequest latitude longitude day output)
    _ -> Left "expected six arguments: STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE"

normalizeInvocation :: (FilePath, ExecutionId, WeatherRequest) -> IO (RunConfig, WeatherRequest)
normalizeInvocation (state, execution, request) = do
    requireDirectory "state directory" state
    canonicalState <- canonicalizePath state
    let suppliedOutput = outputPath request
        outputName = takeFileName suppliedOutput
        suppliedParent = takeDirectory suppliedOutput
    when (null outputName || outputName == "." || outputName == "..") $ ioError (userError "output file must have a filename")
    requireDirectory "output parent directory" suppliedParent
    canonicalParent <- canonicalizePath suppliedParent
    let absoluteOutput = normalise (canonicalParent </> outputName)
    when (sameOrInside canonicalState absoluteOutput) $ ioError (userError "output file must be outside the state directory")
    validateOutputEntry absoluteOutput
    pure (RunConfig canonicalState execution weatherWorkflowName weatherWorkflowVersion, request{outputPath = absoluteOutput})

parseCoordinate :: Text -> Double -> Double -> String -> Either Text Double
parseCoordinate label lower upper input = case readMaybe input of
    Nothing -> Left (label <> " must be a number")
    Just value -> firstValidationError $ validate value
        [ (finite value, label <> " must be finite")
        , (not (finite value) || value >= lower && value <= upper, label <> " is outside its geographic range")
        ]

firstValidationError :: Either [Text] value -> Either Text value
firstValidationError = either (Left . Text.intercalate "\n") Right
parseDate :: String -> Either Text Day
parseDate input = case parseTimeM True defaultTimeLocale "%F" input of
    Nothing -> Left "forecast date must be a valid YYYY-MM-DD calendar date"
    Just day
        | formatTime defaultTimeLocale "%F" day /= input -> Left "forecast date must use canonical YYYY-MM-DD form"
        | otherwise -> Right day
requireDirectory :: String -> FilePath -> IO ()
requireDirectory label path = doesDirectoryExist path >>= \exists -> unless exists (ioError (userError (label <> " does not exist or is not a directory")))
sameOrInside :: FilePath -> FilePath -> Bool
sameOrInside parent candidate = let parts = splitDirectories (normalise parent) in parts == take (length parts) (splitDirectories (normalise candidate))
validateOutputEntry :: FilePath -> IO ()
validateOutputEntry path = do
    result <- (Right <$> getSymbolicLinkStatus path) `catch` missing
    case result of
        Left () -> pure ()
        Right status ->
            unless
                (isRegularFile status)
                (ioError (userError "output entry is not a regular file"))
  where
    missing :: IOException -> IO (Either () FileStatus)
    missing exception
        | isDoesNotExistError exception = pure (Left ())
        | otherwise = ioError exception

handleTopLevelErrors :: IO () -> IO ()
handleTopLevelErrors action =
    action `catch` \exception -> case fromException exception :: Maybe SomeAsyncException of
        Just _ -> throwIO exception
        Nothing -> do
            hPutStrLn stderr (displayException (exception :: SomeException))
            exitFailure

runCli :: IO ()
runCli = handleTopLevelErrors $ do
    invocation <- getArgs >>= either (ioError . userError . Text.unpack) pure . parseArguments
    (config, request) <- normalizeInvocation invocation
    result <- runWorkflow config request weatherPreparation
    putStrLn result

main :: IO ()
main = runCli
