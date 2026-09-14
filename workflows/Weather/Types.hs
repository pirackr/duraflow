{-# LANGUAGE DeriveGeneric #-}

module Weather.Types
  ( WeatherRequest (..)
  , ForecastUnits (..)
  , Forecast (..)
  , Checklist (..)
  , WeatherEffects (..)
  ) where

import Control.DeepSeq (NFData)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (Day, UTCTime)
import GHC.Generics (Generic)

-- | All choices that determine forecast compatibility and output placement.
data WeatherRequest = WeatherRequest
  { requestedLatitude :: Double
  , requestedLongitude :: Double
  , forecastDate :: Day
  , outputPath :: FilePath
  }
  deriving (Eq, Show, Generic)

instance ToJSON WeatherRequest
instance FromJSON WeatherRequest
instance NFData WeatherRequest

data ForecastUnits = ForecastUnits
  { timeUnit :: Text
  , temperatureUnit :: Text
  , precipitationUnit :: Text
  , windUnit :: Text
  , uvUnit :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON ForecastUnits
instance FromJSON ForecastUnits
instance NFData ForecastUnits

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
  deriving (Eq, Show, Generic)

instance ToJSON Forecast
instance FromJSON Forecast
instance NFData Forecast

data Checklist = Checklist
  { checklistForecast :: Forecast
  , checklistItems :: [Text]
  }
  deriving (Eq, Show, Generic)

instance ToJSON Checklist
instance FromJSON Checklist
instance NFData Checklist

-- | Injectable application effects. Task inputs stay unchanged on replay.
data WeatherEffects = WeatherEffects
  { getForecast :: WeatherRequest -> IO Forecast
  , putChecklist :: (FilePath, Checklist) -> IO FilePath
  }
