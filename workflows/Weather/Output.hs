{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Weather.Output
  ( renderChecklist
  , writeChecklist
  ) where

import Control.Exception (IOException, catch, evaluate, mask, onException)
import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time (defaultTimeLocale, formatTime)
import System.Directory (removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files
  ( FileStatus
  , getSymbolicLinkStatus
  , isRegularFile
  , ownerReadMode
  , ownerWriteMode
  , rename
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import qualified System.Posix.IO.ByteString as PosixByteString
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)
import Weather.Types

renderChecklist :: Checklist -> Text
renderChecklist Checklist {checklistForecast = forecast, checklistItems} =
  Text.unlines
    ( [ "Weather preparation checklist"
      , "Forecast date (" <> timeUnit units <> "): " <> showText (forecastDate request)
      , "Requested coordinates: latitude " <> showText (requestedLatitude request) <> ", longitude " <> showText (requestedLongitude request)
      , "Provider coordinates: latitude " <> showText (providerLatitude forecast) <> ", longitude " <> showText (providerLongitude forecast)
      , "Provider: " <> provider forecast
      , "Retrieved at: " <> Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (retrievedAt forecast))
      , metric "Minimum temperature" (minimumTemperature forecast) (temperatureUnit units)
      , metric "Maximum temperature" (maximumTemperature forecast) (temperatureUnit units)
      , metric "Rain probability" (rainProbability forecast) (precipitationUnit units)
      , metric "Maximum wind speed" (maximumWindSpeed forecast) (windUnit units)
      , metric "Maximum UV index" (maximumUvIndex forecast) (uvUnit units)
      , "Preparation:"
      ]
        <> map ("- " <>) checklistItems
    )
 where
  request = forecastRequest forecast
  units = forecastUnits forecast
  metric label value unit = label <> ": " <> showText value <> if Text.null unit then "" else " " <> unit

writeChecklist :: (FilePath, Checklist) -> IO FilePath
writeChecklist (target, checklist) = mask $ \restore -> do
  let bytes = Text.encodeUtf8 (renderChecklist checklist)
      parent = takeDirectory target
  _ <- evaluate (ByteString.length bytes)
  validateTarget target
  (temporary, descriptor) <- createTemporary parent (takeFileName target)
  let cleanup = ignoreIOException (closeFd descriptor) >> ignoreIOException (removeFile temporary)
      writeAndSync = do
        writeAll descriptor bytes
        fileSynchronise descriptor
  restore writeAndSync `onException` cleanup
  closeFd descriptor `onException` cleanup
  validateTarget target `onException` ignoreIOException (removeFile temporary)
  restore (rename temporary target >> synchronizeDirectory parent)
    `onException` ignoreIOException (removeFile temporary)
  pure target

showText :: Show value => value -> Text
showText = Text.pack . show

validateTarget :: FilePath -> IO ()
validateTarget path = do
  result <- (Right <$> getSymbolicLinkStatus path) `catch` missing
  case result of
    Left () -> pure ()
    Right status -> unless (isRegularFile status) (ioError (userError "checklist target is not a regular file"))
 where
  missing :: IOException -> IO (Either () FileStatus)
  missing exception
    | isDoesNotExistError exception = pure (Left ())
    | otherwise = ioError exception

createTemporary :: FilePath -> FilePath -> IO (FilePath, Fd)
createTemporary parent targetName = do
  process <- getProcessID
  tryCandidate process (0 :: Int)
 where
  tryCandidate process sequenceNumber = do
    let path = parent </> ("." <> targetName <> ".tmp." <> show process <> "." <> show sequenceNumber)
    opened <- (Right <$> openFd path WriteOnly creationFlags) `catch` alreadyExists
    case opened of
      Left () -> tryCandidate process (sequenceNumber + 1)
      Right descriptor ->
        (setFdMode descriptor privateMode >> pure (path, descriptor))
          `onException` (ignoreIOException (closeFd descriptor) >> ignoreIOException (removeFile path))
  alreadyExists :: IOException -> IO (Either () Fd)
  alreadyExists exception
    | isAlreadyExistsError exception = pure (Left ())
    | otherwise = ioError exception

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll descriptor bytes = do
  count <- PosixByteString.fdWrite descriptor bytes
  if count == 0
    then ioError (userError "checklist write made no progress")
    else writeAll descriptor (ByteString.drop (fromIntegral count) bytes)

synchronizeDirectory :: FilePath -> IO ()
synchronizeDirectory path = mask $ \restore -> do
  descriptor <- openFd path ReadOnly directoryFlags
  restore (fileSynchronise descriptor) `onException` ignoreIOException (closeFd descriptor)
  closeFd descriptor

ignoreIOException :: IO () -> IO ()
ignoreIOException action = action `catch` (\(_ :: IOException) -> pure ())

privateMode :: FileMode
privateMode = ownerReadMode `unionFileModes` ownerWriteMode

creationFlags :: OpenFileFlags
creationFlags = defaultFileFlags
  { creat = Just privateMode
  , exclusive = True
  , nofollow = True
  , cloexec = True
  }

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags {nofollow = True, cloexec = True, directory = True}
