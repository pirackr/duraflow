module Main (main) where

import SnapshotTests (snapshotTests)
import StorageTests (storageTests)

main :: IO ()
main = snapshotTests >> storageTests
