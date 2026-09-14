module Main (main) where

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
    [] -> snapshotTests >> storageTests >> runtimeTests >> processTests
    _ -> fail "unexpected test arguments"
