module Main (main) where

import DurableFileTests (durableFileTests)
import ProcessTests (childMain, processTests)
import RuntimeTests (runtimeTests)
import SnapshotTests (snapshotTests)
import StorageTests (storageTests)
import System.Environment (getArgs)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "--child" : childArguments -> childMain childArguments
    [] -> durableFileTests >> snapshotTests >> storageTests >> runtimeTests >> processTests
    _ -> fail "unexpected test arguments"
