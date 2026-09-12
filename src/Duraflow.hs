{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Duraflow (runCLI) where

import Control.Concurrent (myThreadId, threadDelay)
import Control.Exception hiding (handle)
import Control.Monad (forever, unless, void, when)
import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Duraflow.Store
import System.Directory
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), die)
import System.FileLock (SharedExclusive (Exclusive), tryLockFile, unlockFile)
import System.FilePath (takeExtension, (</>))
import System.IO
import System.Posix.Signals (Handler (Catch), installHandler, sigKILL, sigTERM, signalProcessGroup)
import System.Process
import System.Timeout (timeout)

-- Protocol traffic alone uses the child's stdin/stdout. Diagnostics use stderr.
data Request = Begin Text | Complete Text Value | StepFailed Text Text | Finish Value

instance FromJSON Request where
    parseJSON = withObject "protocol message" $ \o -> do
        version <- o .: "v" :: Parser Int
        unless (version == 1) (fail "Unsupported protocol version")
        kind <- o .: "type" :: Parser Text
        case kind of
            "begin_step" -> Begin <$> o .: "name"
            "complete_step" -> Complete <$> o .: "name" <*> o .: "result"
            "fail_step" -> StepFailed <$> o .: "name" <*> o .: "error"
            "finish" -> Finish <$> o .: "result"
            _ -> fail "Unknown message type"

problem :: String -> IO a
problem = ioError . userError

send :: Handle -> Value -> IO ()
send handle message = BL.hPut handle (encode message <> "\n") >> hFlush handle

reply :: Handle -> Text -> [Pair] -> IO ()
reply handle kind fields = send handle (object (["v" .= (1 :: Int), "type" .= kind] ++ fields))

-- Only one step may be in flight. A checkpoint is acknowledged AFTER fsync.
conversation :: FilePath -> Handle -> Handle -> Run -> IO Run
conversation home toClient fromClient initial = do
    reply
        toClient
        "hello"
        ["run_id" .= runId initial, "inputs" .= inputs initial, "created_at" .= createdAt initial]
    loop initial Nothing Set.empty
  where
    loop run active visited = do
        line <- BS.hGetLine fromClient
        request <- either (problem . ("Invalid protocol JSON: " ++)) pure (eitherDecodeStrict' line)
        case request of
            Begin name -> do
                unless (active == Nothing && not (T.null name) && Set.notMember name visited) $
                    problem "Step names must be unique and steps cannot be nested"
                let seen = Set.insert name visited
                case Map.lookup name (steps run) of
                    Just output -> do
                        reply toClient "saved" ["result" .= output]
                        loop run Nothing seen
                    Nothing -> do
                        let count = Map.findWithDefault 0 name (attempts run) + 1
                            next = run{attempts = Map.insert name count (attempts run)}
                        saveRun home next
                        reply toClient "execute" ["attempt" .= count]
                        loop next (Just name) seen
            Complete name output -> do
                unless (active == Just name) (problem "Completion does not match active step")
                let next = run{steps = Map.insert name output (steps run)}
                saveRun home next
                reply toClient "committed" ["result" .= output]
                loop next Nothing visited
            StepFailed name message -> do
                unless (active == Just name) (problem "Failure does not match active step")
                problem (T.unpack name ++ ": " ++ T.unpack message)
            Finish output -> do
                unless (active == Nothing) (problem "Cannot finish with a step in flight")
                -- Finish is one-way: the client must exit. Only then is the run complete.
                pure run{result = output}

execute :: FilePath -> Run -> IO ()
execute home run = do
    let running = run{status = "running", lastError = Nothing}
    saveRun home running
    hPutStrLn stderr ("Running " ++ T.unpack (runId run))
    outcome <- try (launch running)
    case outcome of
        Right completed -> do
            saveRun home completed{status = "completed"}
            hPutStrLn stderr ("Completed " ++ T.unpack (runId run))
        Left (err :: SomeException) ->
            case fromException err :: Maybe AsyncException of
                Just _ -> throwIO err -- leave running, with checkpoints, for recovery
                Nothing -> do
                    -- Reload: an exception may have happened after a step was published.
                    latest <- readRun (runPath home (runId run))
                    saveRun home latest{status = "failed", lastError = Just (T.pack (displayException err))}
                    hPutStrLn stderr ("Failed " ++ T.unpack (runId run) ++ ": " ++ displayException err)
  where
    launch running = case command running of
        [] -> problem "Empty workflow command"
        executable : arguments ->
            withCreateProcess
                (proc executable arguments)
                    { cwd = Just (workingDirectory running)
                    , std_in = CreatePipe
                    , std_out = CreatePipe
                    , std_err = Inherit
                    , create_group = True
                    , close_fds = True
                    }
                $ \mIn mOut _ process -> do
                    pid <- getPid process
                    let cleanup = do
                            mapM_ (\p -> signalProcessGroup sigKILL p `catch` ignoreIO) pid
                            void (waitForProcess process)
                    ( case (mIn, mOut) of
                            (Just toClient, Just fromClient) -> do
                                finished <- timeout (180 * 1000000) $ do
                                    completed <- conversation home toClient fromClient running
                                    code <- waitForProcess process
                                    unless (code == ExitSuccess) (problem ("Client exited " ++ show code))
                                    pure completed
                                maybe (problem "Workflow exceeded 180-second timeout") pure finished
                            _ -> problem "Could not open client pipes"
                        )
                        `finally` cleanup

validateId :: String -> IO Text
validateId ident = do
    unless (not (null ident) && all valid ident) $
        problem "Run ID must contain only ASCII letters, digits, hyphens, or underscores"
    pure (T.pack ident)
  where
    valid c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("_-" :: String)

enqueue :: FilePath -> Text -> FilePath -> [String] -> IO ()
enqueue home ident inputFile argv = do
    value <- eitherDecodeFileStrict' inputFile >>= either (problem . ("Invalid input JSON: " ++)) pure
    directory <- getCurrentDirectory
    now <- getCurrentTime
    withStore home $ do
        exists <- doesPathExist (runPath home ident)
        when exists (problem "Run ID already exists; choose a new ID or use retry")
        publish
            (runPath home ident)
            (Run 1 ident argv directory now value "pending" Map.empty Map.empty Null Nothing)
    putStrLn ("Queued " ++ T.unpack ident)

retryRun :: FilePath -> Text -> IO ()
retryRun home ident = withStore home $ do
    run <- readRun (runPath home ident)
    unless (status run == "failed") (problem "Only failed runs can be manually retried")
    publish (runPath home ident) run{status = "pending", lastError = Nothing}

worker :: FilePath -> Bool -> IO ()
worker home once = bracket (tryLockFile (home </> "worker.lock") Exclusive) (mapM_ unlockFile) $ \lock -> do
    when (isNothing lock) (problem "Another worker already owns this store")
    if once then drain else forever (drain >> threadDelay 1000000)
  where
    -- --once drains the current queue; default mode keeps polling.
    drain = do
        paths <- sort . filter ((== ".json") . takeExtension) <$> listDirectory (home </> "runs")
        mapM_
            ( \name -> do
                run <- readRun (home </> "runs" </> name)
                when (status run `elem` ["pending", "running"]) (execute home run)
            )
            paths

runCLI :: IO ()
runCLI = do
    -- Handled shutdown unwinds process/lock brackets; SIGKILL cannot do this.
    tid <- myThreadId
    void (installHandler sigTERM (Catch (throwTo tid UserInterrupt)) Nothing)
    args <- getArgs
    home <- makeAbsolute . maybe ".duraflow" id =<< lookupEnv "DURAFLOW_HOME"
    initStore home
    let dispatch = case args of
            "enqueue" : ident : inputFile : "--" : argv@(_ : _) -> do
                key <- validateId ident
                enqueue home key inputFile argv
            ["worker"] -> worker home False
            ["worker", "--once"] -> worker home True
            ["retry", ident] -> validateId ident >>= retryRun home
            ["show", ident] -> do
                key <- validateId ident
                readRun (runPath home key) >>= BL.putStr . (<> "\n") . encode
            _ -> die "Usage: duraflow enqueue ID INPUT.json -- COMMAND [ARGS...] | worker [--once] | retry ID | show ID"
    dispatch `catch` \(err :: IOException) -> die (displayException err)
