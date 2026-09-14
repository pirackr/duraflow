{-# LANGUAGE ScopedTypeVariables #-}

module Duraflow.Internal.DurableFile (writeFileDurably) where

import Control.Exception (IOException, catch, evaluate, mask, onException)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
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
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- | Durably and atomically replace a file with private contents.
--
-- The parent directory must already exist. The replacement uses an owner-only
-- temporary file, synchronizes the file and parent directory, and propagates
-- failures. This contract targets Linux on a trusted local filesystem. When
-- called within a task, the external write can occur at least once if the task
-- is interrupted before its successful result is committed.
writeFileDurably :: FilePath -> ByteString -> IO ()
writeFileDurably target bytes = mask $ \restore -> do
    let parent = takeDirectory target
    _ <- evaluate (ByteString.length bytes)
    validateTarget target
    (temporary, descriptor) <- createTemporary parent (takeFileName target)
    let cleanup = do
            ignoreIOException (closeFd descriptor)
            ignoreIOException (removeFile temporary)
        writeAndSync = do
            writeAll descriptor bytes
            fileSynchronise descriptor
    restore writeAndSync `onException` cleanup
    closeFd descriptor `onException` cleanup
    validateTarget target `onException` ignoreIOException (removeFile temporary)
    restore (replaceAndSync temporary target parent)
        `onException` ignoreIOException (removeFile temporary)

replaceAndSync :: FilePath -> FilePath -> FilePath -> IO ()
replaceAndSync temporary target parent = do
    rename temporary target
    synchronizeDirectory parent

validateTarget :: FilePath -> IO ()
validateTarget path = do
    result <- (Right <$> getSymbolicLinkStatus path) `catch` missing
    case result of
        Left () -> pure ()
        Right status ->
            unless
                (isRegularFile status)
                (ioError (userError "durable file target is not a regular file"))
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
        let path =
                parent
                    </> ("." <> targetName <> ".tmp." <> show process <> "." <> show sequenceNumber)
        opened <- (Right <$> openFd path WriteOnly creationFlags) `catch` alreadyExists
        case opened of
            Left () -> tryCandidate process (sequenceNumber + 1)
            Right descriptor ->
                initializeTemporary path descriptor
                    `onException` cleanupTemporary path descriptor

    initializeTemporary path descriptor = do
        setFdMode descriptor privateMode
        pure (path, descriptor)

    cleanupTemporary path descriptor = do
        ignoreIOException (closeFd descriptor)
        ignoreIOException (removeFile path)

    alreadyExists :: IOException -> IO (Either () Fd)
    alreadyExists exception
        | isAlreadyExistsError exception = pure (Left ())
        | otherwise = ioError exception

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll descriptor bytes = do
    count <- PosixByteString.fdWrite descriptor bytes
    if count == 0
        then ioError (userError "durable file write made no progress")
        else writeAll descriptor (ByteString.drop (fromIntegral count) bytes)

synchronizeDirectory :: FilePath -> IO ()
synchronizeDirectory path = mask $ \restore -> do
    descriptor <- openFd path ReadOnly directoryFlags
    restore (fileSynchronise descriptor)
        `onException` ignoreIOException (closeFd descriptor)
    closeFd descriptor

ignoreIOException :: IO () -> IO ()
ignoreIOException action = action `catch` (\(_ :: IOException) -> pure ())

privateMode :: FileMode
privateMode = ownerReadMode `unionFileModes` ownerWriteMode

creationFlags, directoryFlags :: OpenFileFlags
creationFlags =
    defaultFileFlags
        { creat = Just privateMode
        , exclusive = True
        , nofollow = True
        , cloexec = True
        }
directoryFlags =
    defaultFileFlags
        { nofollow = True
        , cloexec = True
        , directory = True
        }
