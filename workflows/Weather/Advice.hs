{-# LANGUAGE OverloadedStrings #-}

module Weather.Advice (prepareAdvice) where

import Data.Text (Text)
import Weather.Types

prepareAdvice :: Forecast -> Checklist
prepareAdvice forecast = Checklist forecast selectedItems
 where
  applicable =
    [ (rainProbability forecast >= 50, "Bring rain protection.")
    , (minimumTemperature forecast <= 5, "Bring warm layers.")
    , (maximumWindSpeed forecast >= 40, "Secure loose outdoor items and prepare for wind.")
    , (maximumUvIndex forecast >= 3, "Use sun protection.")
    ]
  advice = [item | (applies, item) <- applicable, applies]
  selectedItems :: [Text]
  selectedItems
    | null advice = ["No additional preparation was identified by these rules."]
    | otherwise = advice
