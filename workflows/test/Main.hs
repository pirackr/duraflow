module Main (main) where

import AdviceTests (runAdviceTests)
import ForecastTests (runForecastTests)

main :: IO ()
main = do
  runForecastTests
  runAdviceTests
  putStrLn "All weather application tests passed."
