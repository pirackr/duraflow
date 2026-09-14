{-# LANGUAGE OverloadedStrings #-}

module Weather
  ( WeatherRequest (..)
  , ForecastUnits (..)
  , Forecast (..)
  , Checklist (..)
  , WeatherEffects (..)
  , weatherWorkflowName
  , weatherWorkflowVersion
  , weatherPreparationWith
  , weatherPreparation
  , fetchForecast
  , prepareAdvice
  , renderChecklist
  , writeChecklist
  ) where

import Data.Text (Text)
import Duraflow (TaskId (..), Workflow, task)
import Weather.Advice (prepareAdvice)
import Weather.Forecast (fetchForecast)
import Weather.Output (renderChecklist, writeChecklist)
import Weather.Types

weatherWorkflowName :: Text
weatherWorkflowName = "weatherPreparation"

weatherWorkflowVersion :: Text
weatherWorkflowVersion = "1"

weatherPreparationWith :: WeatherEffects -> WeatherRequest -> Workflow FilePath
weatherPreparationWith effects request = do
  forecast <- task (TaskId "fetchForecast") request (getForecast effects)
  checklist <- task (TaskId "prepareAdvice") forecast (pure . prepareAdvice)
  task (TaskId "writeChecklist") (outputPath request, checklist) (putChecklist effects)

weatherPreparation :: WeatherRequest -> Workflow FilePath
weatherPreparation = weatherPreparationWith WeatherEffects
  { getForecast = fetchForecast
  , putChecklist = writeChecklist
  }
