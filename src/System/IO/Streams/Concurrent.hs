-- | Stream utilities for working with concurrent channels.

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP          #-}

module System.IO.Streams.Concurrent
 ( -- * Channel conversions
   inputToChan
 , chanToInput
 , chanToOutput
 , concurrentMerge
 , makeChanPipe
 ) where

------------------------------------------------------------------------------
#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative        ((<$>), (<*>))
#endif
import           Control.Concurrent         (forkIO)
import           Control.Concurrent.Chan    (Chan, newChan, readChan, writeChan)
import           Control.Concurrent.MVar    (modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import           Control.Exception          (SomeException, mask, throwIO, try)
import           Control.Monad              (forM_)
import           Prelude                    hiding (read)
------------------------------------------------------------------------------
import           System.IO.Streams.Internal (InputStream, OutputStream, makeInputStream, makeOutputStream, nullInput, read)


------------------------------------------------------------------------------
-- | Writes the contents of an input stream to a channel until the input stream
-- yields end-of-stream.
inputToChan :: InputStream a -> Chan (Maybe a) -> IO ()
inputToChan is ch = go
  where
    go = do
        mb <- read is
        writeChan ch mb
        maybe (return $! ()) (const go) mb


------------------------------------------------------------------------------
-- | Turns a 'Chan' into an input stream.
--
chanToInput :: Chan (Maybe a) -> IO (InputStream a)
chanToInput ch = makeInputStream $! readChan ch


------------------------------------------------------------------------------
-- | Turns a 'Chan' into an output stream.
--
chanToOutput :: Chan (Maybe a) -> IO (OutputStream a)
chanToOutput = makeOutputStream . writeChan


------------------------------------------------------------------------------
-- | Concurrently merges a list of 'InputStream's, combining values in the
-- order they become available.
--
-- Note: does /not/ forward individual end-of-stream notifications, the
-- produced stream does not yield end-of-stream until all of the input streams
-- have finished.
--
-- Any exceptions raised in one of the worker threads will be trapped and
-- re-raised in the current thread.
--
-- If the supplied list is empty, `concurrentMerge` will return an empty
-- stream. (/Since: 1.5.0.1/)
--
concurrentMerge :: [InputStream a] -> IO (InputStream a)
concurrentMerge [] = nullInput
concurrentMerge iss = do
    mv    <- newEmptyMVar
    nleft <- newMVar $! length iss
    mask $ \restore -> forM_ iss $ \is -> forkIO $ do
        let producer = do
              emb <- try $ restore $ read is
              case emb of
                  Left exc      -> do putMVar mv (Left (exc :: SomeException))
                                      producer
                  Right Nothing -> putMVar mv $! Right Nothing
                  Right x       -> putMVar mv (Right x) >> producer
        producer
    makeInputStream $ chunk mv nleft

  where
    chunk mv nleft = do
        emb <- takeMVar mv
        case emb of
            Left exc      -> throwIO exc
            Right Nothing -> do x <- modifyMVar nleft $ \n ->
                                     let !n' = n - 1
                                     in return $! (n', n')
                                if x > 0
                                  then chunk mv nleft
                                  else return Nothing
            Right x       -> return x


--------------------------------------------------------------------------------
-- | Create a new pair of streams using an underlying 'Chan'. Everything written
-- to the 'OutputStream' will appear as-is on the 'InputStream'.
--
-- Since reading from the 'InputStream' and writing to the 'OutputStream' are
-- blocking calls, be sure to do so in different threads.
makeChanPipe :: IO (InputStream a, OutputStream a)
makeChanPipe = do
    chan <- newChan
    (,) <$> chanToInput chan <*> chanToOutput chan
