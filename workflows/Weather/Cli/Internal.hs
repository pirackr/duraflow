module Weather.Cli.Internal
  ( handleTopLevelErrors
  ) where

import Control.Exception (SomeAsyncException, SomeException, catch, displayException, fromException, throwIO)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

handleTopLevelErrors :: IO () -> IO ()
handleTopLevelErrors action = action `catch` reportFailure
 where
  reportFailure :: SomeException -> IO ()
  reportFailure exception = case fromException exception :: Maybe SomeAsyncException of
    Just _ -> throwIO exception
    Nothing -> hPutStrLn stderr (displayException exception) >> exitFailure
