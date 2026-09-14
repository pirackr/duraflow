-- DESIGN SKETCH ONLY. Not part of the Cabal build and not runnable yet.
-- Duraflow's proposed API and the application-specific Weather module
-- shown below have not been implemented.
--
-- task :: (JSON input, JSON output)
--      => TaskId -> input -> (input -> IO output) -> Workflow output
-- runWorkflow :: ExecutionId -> input -> (input -> Workflow output) -> IO output
-- These signatures are schematic. Concrete JSON constraints are omitted.

module WeatherWorkflow where

import Duraflow (Workflow, runWorkflow, task)
import Weather
  ( WeatherRequest (..)
  , fetchForecast
  , prepareAdvice
  , writeChecklist
  )

weatherPreparation :: WeatherRequest -> Workflow FilePath
weatherPreparation request = do
  forecast <- task "fetchForecast" request fetchForecast

  checklist <- task "prepareAdvice" forecast (pure . prepareAdvice)

  task "writeChecklist" (outputPath request, checklist) writeChecklist

main :: IO ()
main = do
  let request = WeatherRequest
        { location = "Seattle"
        , forecastDate = "2026-09-14" -- Illustrative target date.
        , outputPath = "weather-preparation.txt"
        }

  reportPath <- runWorkflow
    "weather-seattle-2026-09-14-v1"
    request
    weatherPreparation

  putStrLn reportPath

-- Application functions, to be defined in Weather:
--
-- fetchForecast :: WeatherRequest -> IO Forecast
-- Fetches weather and includes its retrieval time in the returned value.
--
-- prepareAdvice :: Forecast -> Checklist
-- Pure rules for rain, cold, wind, and UV. Includes forecast provenance.
--
-- writeChecklist :: (FilePath, Checklist) -> IO FilePath
-- Safely replaces the destination rather than appending, so retrying the
-- write after interruption does not duplicate the checklist.
--
-- On resume, task validates its saved inputs and returns its committed
-- result without invoking the action again. Failed or interrupted tasks
-- may run again. An external effect without a committed result may repeat.
-- The runtime owns JSON persistence and the execution lock.
-- Workflow version validation is still an API design requirement; a v1
-- suffix alone does not enforce it. No stack restoration is implied.
-- Use a new execution for a fresh forecast. Resuming an old execution
-- deliberately reuses its saved forecast rather than fetching new weather.
