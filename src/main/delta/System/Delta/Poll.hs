module System.Delta.Poll ( createPollWatcher
                         ) where

import Control.Applicative ((<$>))
import Control.Concurrent
import Control.Monad (foldM)

import qualified Data.Map as M
import Data.Maybe (catMaybes)

import FRP.Sodium

import System.Delta.Base
import System.Delta.Class

import System.Directory
import System.FilePath

import Data.List (isPrefixOf)

-- | Watch files in this directory recursively for changes every
-- n seconds.
createPollWatcher :: Int      -- ^ seconds interval
                  -> FilePath -- ^ path to watch
                  -> IO FileWatcher
createPollWatcher secs path = do
  (changedEvent, pushChanged) <- sync $ newEvent
  (deletedEvent, pushDeleted) <- sync $ newEvent
  (newFileEvent, pushNewFile) <- sync $ newEvent
  canonPath <- canonicalizePath path
  watcherId <- startWatchThread canonPath pushNewFile pushDeleted pushChanged secs
  return $ FileWatcher newFileEvent deletedEvent changedEvent (killThread watcherId)

-- | Recursively traverse a folder, follow symbolic links but don't
-- visit a file twice.
recursiveDescent path =
  M.filterWithKey (\_ -> not . fileInfoIsDir) <$> -- files only
    recursiveDescent' M.empty path

-- | Recursively traverse a folder, follows symbolic links,
-- doesn't loop however.
recursiveDescent' :: M.Map FilePath FileInfo
                  -> FilePath
                  -> IO (M.Map FilePath FileInfo)
recursiveDescent' visited path | M.member path visited = return visited
recursiveDescent' visited path = do
  isDir  <- doesDirectoryExist path
  inf <- mkFileInfo path
  let visitedWithCurrent = M.insert path inf visited
  if not isDir
  then return $ visitedWithCurrent
  else do
    contentsUnfiltered <- getDirectoryContents path
    let contentsFiltered = filter (\x -> x /= "." && x /= "..") contentsUnfiltered
        contentsAbs = (combine path) <$> contentsFiltered
    foldM recursiveDescent' visitedWithCurrent contentsAbs


-- | List all files that have a larger modification time in the second
-- map than in the first
diffChangedFiles :: M.Map FilePath FileInfo 
             -> M.Map FilePath FileInfo
             -> [FileInfo]
diffChangedFiles before after =
  catMaybes . M.elems $ M.intersectionWith f before after
  where
    f beforeInfo afterInfo =
      if fileInfoTimestamp beforeInfo < fileInfoTimestamp afterInfo
      then Just afterInfo
      else Nothing

-- | List all files that occur in the second map but not the first
diffNewFiles :: M.Map FilePath FileInfo
             -> M.Map FilePath FileInfo
             -> [FileInfo]
diffNewFiles before after = M.elems $ M.difference after before

-- | List all files that occur in the first map but not the second
diffDeletedFiles :: M.Map FilePath FileInfo
                 -> M.Map FilePath FileInfo
                 -> [FileInfo]
diffDeletedFiles before after = M.elems $ M.difference before after

-- | Fork a thread that continuously polls the given paht and compares
-- the results of two polls.
startWatchThread :: FilePath
                 -> (FilePath -> PReactive ()) -- ^ Push new files / dirs
                 -> (FilePath -> PReactive ()) -- ^ Push deleted files / dirs
                 -> (FilePath -> PReactive ()) -- ^ Push changed files / dirs
                 -> Int -- ^ Seconds between polls
                 -> IO ThreadId
startWatchThread path pushNew pushDeleted pushChanged secs = do
  curr <- recursiveDescent path
  forkIO $ go curr
  where
    go last = do
      threadDelay $ secs * 1000 * 1000
      curr <- recursiveDescent path
      sync $ mapM_ (pushChanged) (fileInfoPath <$> diffChangedFiles last curr)
      sync $ mapM_ (pushNew    ) (fileInfoPath <$> diffNewFiles last curr    )
      sync $ mapM_ (pushDeleted) (fileInfoPath <$> diffDeletedFiles last curr)
      go curr
