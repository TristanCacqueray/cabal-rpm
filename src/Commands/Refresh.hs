-- |
-- Module      :  Commands.Refresh
-- Copyright   :  (C) 2016  Jens Petersen
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
--
-- Explanation: refresh spec file to newer cabal-rpm

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

module Commands.Refresh (
  refresh
  ) where

import Paths_cabal_rpm (version)
import Commands.Spec (createSpecFile)
import FileUtils (withTempDirectory)
import Options (RpmFlags (..))
import PackageUtils (PackageData (..), cabal_, isGitDir, patchSpec,
                     removePrefix)
import SysCmd (cmd, cmd_, die, grep_, notNull, optionalProgram)

#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,8,2))
#else
import Control.Applicative ((<$>))
#endif
import Control.Monad (unless, when)
import Data.List (isPrefixOf)
import Data.Version (showVersion)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist,
                         getCurrentDirectory, setCurrentDirectory)
import System.Environment (getEnv)
--import System.Exit (exitSuccess)
import System.FilePath ((</>), (<.>))

refresh :: PackageData -> RpmFlags -> IO ()
refresh pkgdata flags =
  case specFilename pkgdata of
    Nothing -> die "No (unique) .spec file in directory."
    Just spec -> do
      gitDir <- getCurrentDirectory >>= isGitDir
      rwGit <- if gitDir then grep_ "url = ssh://" ".git/config" else return False
      when rwGit $ do
        local <- cmd "git" ["diff"]
        when (notNull local) $
          putStrLn "Working dir contain local changes!"
          -- exitSuccess
      first <- head . lines <$> readFile spec
      do
        let cblrpmver =
              if "# generated by cabal-rpm-" `isPrefixOf` first
              then removePrefix "# generated by cabal-rpm-" first
              else "0.9.11"
        when (cblrpmver == showVersion version) $
          error "Packaging is up to date"
        oldspec <- createOldSpec cblrpmver spec
        newspec <- createSpecFile pkgdata flags Nothing
        patchSpec Nothing oldspec newspec
--          setCurrentDirectory cwd
--          when rwGit $
--            cmd_ "git" ["commit", "-a", "-m", "update to" +-+ newver]
  where
    createOldSpec :: String -> FilePath -> IO FilePath
    createOldSpec crVer spec = do
      cblrpmVersion crVer
      let backup = spec <.> "cblrpm"
          backup' = backup ++ "-" ++ crVer
      cmd_ "mv" [backup, backup']
      return backup'

    cblrpmVersion :: String -> IO ()
    cblrpmVersion crver = do
      let cblrpmver = "cabal-rpm-" ++ crver
      inpath <- optionalProgram cblrpmver
      if inpath
        then cmd_ cblrpmver ["spec"]
        else do
        home <- getEnv "HOME"
        let bindir = home </> ".cblrpm/versions/"
        haveExe <- doesFileExist $ bindir </> cblrpmver
        unless haveExe $
          withTempDirectory $ \cwd -> do
          cabal_ "unpack" [cblrpmver]
          setCurrentDirectory cblrpmver
          cabal_ "configure" []
          cabal_ "build" []
          createDirectoryIfMissing True bindir
          let bin = "dist/build/cabal-rpm" </>
                    -- this should really be <= 0.9.11 (and >= 0.7.0)
                    -- but anyway before 0.9.11 we didn't version .spec files
                    if crver == "0.9.11" then "cblrpm" else "cabal-rpm"
          cmd_ "strip" [bin]
          copyFile bin $ bindir </> cblrpmver
          setCurrentDirectory cwd
        cmd_ (bindir </> cblrpmver) ["spec"]
