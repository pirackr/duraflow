{-# LANGUAGE OverloadedStrings #-}

module DurableFileTests (durableFileTests) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as ByteString
import Duraflow (writeFileDurably)
import System.Directory (createDirectory, createFileLink)
import System.FilePath ((</>))
import TestSupport

durableFileTests :: IO ()
durableFileTests = do
  runCase "generic durable writer preserves binary bytes" binaryBytes
  runCase "generic durable writer rejects unsafe targets" unsafeTargets

binaryBytes :: IO ()
binaryBytes = withTestDirectory "durable-binary" $ \directory -> do
  let target = directory </> "bytes.bin"
      bytes = ByteString.pack [0, 255, 128, 10, 0, 42]
  writeFileDurably target bytes
  assertEqual "binary content" bytes =<< ByteString.readFile target
  writeFileDurably target "replacement"
  assertEqual "atomic replacement" "replacement" =<< ByteString.readFile target

unsafeTargets :: IO ()
unsafeTargets = withTestDirectory "durable-unsafe" $ \directory -> do
  let real = directory </> "real"; linked = directory </> "linked"; nonregular = directory </> "subdir"
  ByteString.writeFile real "untouched"
  createFileLink real linked
  assertFailure "symlink" (writeFileDurably linked "changed")
  assertEqual "symlink destination untouched" "untouched" =<< ByteString.readFile real
  createDirectory nonregular
  assertFailure "directory" (writeFileDurably nonregular "changed")
 where
  assertFailure label action = do
    result <- try action
    case result :: Either SomeException () of
      Left _ -> pure ()
      Right () -> fail (label <> " unexpectedly accepted")
