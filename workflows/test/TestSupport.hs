{-# LANGUAGE ScopedTypeVariables #-}

module TestSupport
  ( assertBool
  , assertEqual
  , assertLeft
  , assertThrows
  , fixturePath
  , runCase
  , withTestDirectory
  ) where

import Control.Exception (Exception, SomeException, bracket, catch, throwIO)
import Control.Monad (unless)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.IO (hClose, openTempFile)

assertBool :: String -> Bool -> IO ()
assertBool name condition = unless condition (throwIO (TestFailure name))

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  unless (expected == actual) $
    throwIO (TestFailure (name <> ": expected " <> show expected <> ", actual " <> show actual))

assertLeft :: Show b => String -> Either a b -> IO ()
assertLeft name result = case result of
  Left _ -> pure ()
  Right actual -> throwIO (TestFailure (name <> ": expected Left, actual Right " <> show actual))

assertThrows :: String -> IO a -> IO ()
assertThrows name action = do
  threw <- (action >> pure False) `catch` (\(_ :: SomeException) -> pure True)
  unless threw (throwIO (TestFailure (name <> ": expected exception, actual success")))

fixturePath :: FilePath -> FilePath
fixturePath name = "workflows/test/fixtures/" <> name

runCase :: String -> IO () -> IO ()
runCase name action = do
  putStrLn ("[ RUN      ] " <> name)
  action
  putStrLn ("[       OK ] " <> name)

withTestDirectory :: String -> (FilePath -> IO a) -> IO a
withTestDirectory label = bracket acquire removeDirectoryRecursive
 where
  acquire = do
    base <- getTemporaryDirectory
    (path, handle) <- openTempFile base ("weather-" <> label)
    hClose handle
    removeFile path
    createDirectory path
    pure path

newtype TestFailure = TestFailure String deriving (Show)
instance Exception TestFailure
