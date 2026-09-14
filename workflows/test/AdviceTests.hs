{-# LANGUAGE OverloadedStrings #-}

module AdviceTests (mildForecast, runAdviceTests) where

import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import TestSupport
import WeatherWorkflow

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
      actual = Text.encodeUtf8 (renderChecklist (prepareAdvice renderedForecast))
  assertEqual "exact rendered bytes" golden actual
  let checklist = prepareAdvice renderedForecast
  assertEqual "checklist JSON round trip" (Right checklist) (eitherDecode (encode checklist))
  assertBool "one final newline" (ByteString.isSuffixOf "\n" actual && not (ByteString.isSuffixOf "\n\n" actual))
  assertBool "LF only" (not (ByteString.elem 13 actual))

items :: Forecast -> [Text]
items = checklistItems . prepareAdvice
