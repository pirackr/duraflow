{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Weather.Forecast
  ( forecastUrl
  , parseForecast
  , fetchForecastWith
  , fetchForecast
  ) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Types (Object, Parser)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (findIndex)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (Day, UTCTime (..), fromGregorian, getCurrentTime)
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
import System.Timeout (timeout)
import Weather.Types

forecastUrl :: WeatherRequest -> Text
forecastUrl request = Text.pack (show (getUri configured))
 where
  configured = setQueryString query baseRequest
  baseRequest = defaultRequest
    { secure = True
    , host = "api.open-meteo.com"
    , port = 443
    , path = "/v1/forecast"
    }
  encodedDate = ByteString8.pack (show (forecastDate request))
  query =
    [ ("latitude", Just (number (requestedLatitude request)))
    , ("longitude", Just (number (requestedLongitude request)))
    , ("start_date", Just encodedDate)
    , ("end_date", Just encodedDate)
    , ("timezone", Just "UTC")
    , ("temperature_unit", Just "celsius")
    , ("wind_speed_unit", Just "kmh")
    , ("daily", Just "temperature_2m_min,temperature_2m_max,precipitation_probability_max,wind_speed_10m_max,uv_index_max")
    ]
  number = ByteString8.pack . show

parseForecast :: WeatherRequest -> Text -> UTCTime -> ByteString.ByteString -> Either Text Forecast
parseForecast request url timestamp bytes = do
  validateCoordinates "requested" (requestedLatitude request) (requestedLongitude request)
  response <- firstText (eitherDecodeStrict' bytes)
  validateResponse response
  position <- maybe (Left "requested forecast date is absent") Right
    (findIndex (== forecastDate request) (dailyTimes (rawDaily response)))
  let daily = rawDaily response
      minimumValue = dailyMinimumTemperatures daily !! position
      maximumValue = dailyMaximumTemperatures daily !! position
      rainValue = dailyRainProbabilities daily !! position
      windValue = dailyMaximumWindSpeeds daily !! position
      uvValue = dailyMaximumUvIndices daily !! position
  pure Forecast
    { forecastRequest = request
    , forecastUnits = ForecastUnits "iso8601" "°C" "%" "km/h" ""
    , providerLatitude = rawLatitude response
    , providerLongitude = rawLongitude response
    , minimumTemperature = minimumValue
    , maximumTemperature = maximumValue
    , rainProbability = rainValue
    , maximumWindSpeed = windValue
    , maximumUvIndex = uvValue
    , provider = "Open-Meteo"
    , requestUrl = url
    , retrievedAt = timestamp
    }

fetchForecastWith
  :: Int
  -> (Text -> IO (Int, ByteString.ByteString))
  -> IO UTCTime
  -> WeatherRequest
  -> IO Forecast
fetchForecastWith deadline transport clock request = do
  completed <- timeout deadline $ do
    (status, bytes) <- transport url
    unless (status >= 200 && status < 300) $
      ioError (userError ("forecast request returned HTTP status " <> show status))
    let dummyTimestamp = UTCTime (fromGregorian 1858 11 17) 0
    parsed <- either (ioError . userError . Text.unpack) pure (parseForecast request url dummyTimestamp bytes)
    validated <- evaluate (force parsed)
    timestamp <- clock
    evaluate (force validated {retrievedAt = timestamp})
  maybe (ioError (userError "forecast request exceeded its elapsed-time deadline")) pure completed
 where
  url = forecastUrl request

fetchForecast :: WeatherRequest -> IO Forecast
fetchForecast = fetchForecastWith 30000000 productionTransport getCurrentTime

productionTransport :: Text -> IO (Int, ByteString.ByteString)
productionTransport url = do
  manager <- newManager tlsManagerSettings
  request <- parseRequest (Text.unpack url)
  let configured = request
        { redirectCount = 0
        , responseTimeout = responseTimeoutNone
        , checkResponse = \_ _ -> pure ()
        }
  response <- httpLbs configured manager
  pure (statusCode (responseStatus response), LazyByteString.toStrict (responseBody response))

validateResponse :: RawResponse -> Either Text ()
validateResponse response = do
  when (rawUtcOffsetSeconds response /= 0) (Left "UTC offset must be zero")
  validateCoordinates "provider" (rawLatitude response) (rawLongitude response)
  validateUnits (rawUnits response)
  let daily = rawDaily response
      arrays =
        [ length (dailyTimes daily)
        , length (dailyMinimumTemperatures daily)
        , length (dailyMaximumTemperatures daily)
        , length (dailyRainProbabilities daily)
        , length (dailyMaximumWindSpeeds daily)
        , length (dailyMaximumUvIndices daily)
        ]
  case arrays of
    firstLength : remainingLengths ->
      unless (firstLength > 0 && all (== firstLength) remainingLengths) (Left "daily arrays must have equal nonzero lengths")
    [] -> Left "daily arrays must have equal nonzero lengths"
  mapM_ validateDailyRow (zip5
    (dailyMinimumTemperatures daily)
    (dailyMaximumTemperatures daily)
    (dailyRainProbabilities daily)
    (dailyMaximumWindSpeeds daily)
    (dailyMaximumUvIndices daily))

validateDailyRow :: (Double, Double, Double, Double, Double) -> Either Text ()
validateDailyRow (minimumValue, maximumValue, rainValue, windValue, uvValue) = do
  mapM_ (validateFinite "forecast metric") [minimumValue, maximumValue, rainValue, windValue, uvValue]
  when (minimumValue > maximumValue) (Left "minimum temperature exceeds maximum temperature")
  unless (rainValue >= 0 && rainValue <= 100) (Left "rain probability is outside 0 through 100")
  when (windValue < 0) (Left "wind speed is negative")
  when (uvValue < 0) (Left "UV index is negative")

validateCoordinates :: Text -> Double -> Double -> Either Text ()
validateCoordinates label latitude longitude = do
  validateFinite (label <> " latitude") latitude
  validateFinite (label <> " longitude") longitude
  unless (latitude >= -90 && latitude <= 90) (Left (label <> " latitude is outside geographic bounds"))
  unless (longitude >= -180 && longitude <= 180) (Left (label <> " longitude is outside geographic bounds"))

validateFinite :: Text -> Double -> Either Text ()
validateFinite label value =
  when (isNaN value || isInfinite value) (Left (label <> " must be finite"))

validateUnits :: RawUnits -> Either Text ()
validateUnits units = do
  exact "time" "iso8601" (rawTimeUnit units)
  exact "minimum temperature" "°C" (rawMinimumTemperatureUnit units)
  exact "maximum temperature" "°C" (rawMaximumTemperatureUnit units)
  exact "precipitation probability" "%" (rawRainUnit units)
  exact "wind speed" "km/h" (rawWindUnit units)
  exact "UV index" "" (rawUvUnit units)
 where
  exact label expected actual = unless (actual == expected) (Left (label <> " unit is unexpected"))

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right

data RawResponse = RawResponse
  { rawLatitude :: Double
  , rawLongitude :: Double
  , rawUtcOffsetSeconds :: Int
  , rawUnits :: RawUnits
  , rawDaily :: RawDaily
  }

data RawUnits = RawUnits
  { rawTimeUnit :: Text
  , rawMinimumTemperatureUnit :: Text
  , rawMaximumTemperatureUnit :: Text
  , rawRainUnit :: Text
  , rawWindUnit :: Text
  , rawUvUnit :: Text
  }

data RawDaily = RawDaily
  { dailyTimes :: [Day]
  , dailyMinimumTemperatures :: [Double]
  , dailyMaximumTemperatures :: [Double]
  , dailyRainProbabilities :: [Double]
  , dailyMaximumWindSpeeds :: [Double]
  , dailyMaximumUvIndices :: [Double]
  }

instance FromJSON RawResponse where
  parseJSON = withObject "forecast response" $ \object -> RawResponse
    <$> object .: "latitude"
    <*> object .: "longitude"
    <*> object .: "utc_offset_seconds"
    <*> object .: "daily_units"
    <*> object .: "daily"

instance FromJSON RawUnits where
  parseJSON = withObject "daily units" $ \object -> RawUnits
    <$> object .: "time"
    <*> object .: "temperature_2m_min"
    <*> object .: "temperature_2m_max"
    <*> object .: "precipitation_probability_max"
    <*> object .: "wind_speed_10m_max"
    <*> object .: "uv_index_max"

instance FromJSON RawDaily where
  parseJSON = withObject "daily values" parseDaily
   where
    parseDaily :: Object -> Parser RawDaily
    parseDaily object = RawDaily
      <$> object .: "time"
      <*> object .: "temperature_2m_min"
      <*> object .: "temperature_2m_max"
      <*> object .: "precipitation_probability_max"
      <*> object .: "wind_speed_10m_max"
      <*> object .: "uv_index_max"

zip5 :: [a] -> [b] -> [c] -> [d] -> [e] -> [(a, b, c, d, e)]
zip5 (a : as) (b : bs) (c : cs) (d : ds) (e : es) = (a, b, c, d, e) : zip5 as bs cs ds es
zip5 _ _ _ _ _ = []
