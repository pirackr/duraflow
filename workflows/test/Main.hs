module Main (main) where

import AdviceTests (runAdviceTests)
import CliTests (runCliTests)
import ForecastTests (runForecastTests)
import IntegrationTests (runIntegrationTests)

main :: IO ()
main = do
  runForecastTests
  runAdviceTests
  runCliTests
  runIntegrationTests
  putStrLn "All weather application tests passed."
