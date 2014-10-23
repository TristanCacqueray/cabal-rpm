-- |
-- Module      :  Commands.Update
-- Copyright   :  (C) 2014  Jens Petersen
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
-- Stability   :  alpha
--
-- Explanation: update spec file to a new package version

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

module Commands.Update (
  update
  ) where

import Commands.Spec (createSpecFile)
import FileUtils (withTempDirectory)
import PackageUtils (PackageData (..), latestPkg, packageName, packageVersion,
                    prepare)
import Setup (RpmFlags (..))
import SysCmd (cmd_, shell, (+-+))

import Distribution.PackageDescription (PackageDescription (..))
import Distribution.Simple.Utils (die)
                                        
import System.Directory (createDirectory, getCurrentDirectory)
import System.FilePath ((</>))

update :: PackageData -> RpmFlags -> IO ()
update pkgdata flags =
  case specFilename pkgdata of
    Nothing -> die "No (unique) .spec file in directory."
    Just spec -> do
      withTempDirectory $ do
        let pkg = package $ packageDesc pkgdata
            name = packageName pkg
            ver = packageVersion pkg
            current = name ++ "-" ++ ver
        curspec <- createSpecVersion current spec
        latest <- latestPkg name
        if current == latest
          then error $ current +-+ "is latest version."
          else do
          newspec <- createSpecVersion latest spec
          getCurrentDirectory >>= putStrLn
          shell $ "diff -u -I \"- spec file generated by cabal-rpm\" -I \"Fedora Haskell SIG <haskell@lists.fedoraproject.org>\"" +-+ curspec +-+ newspec +-+ "| patch -d .. -p1"
          cmd_ "sed" ["-i", "-e s/^\\(Release:        \\).*/\\10%{?dist}/", ".." </> spec]
          cmd_ "rpmdev-bumpspec" ["-c", "update to" +-+ latest, ".." </> spec]
  where
    createSpecVersion :: String -> String -> IO FilePath
    createSpecVersion ver spec = do
      pkgdata' <- prepare (Just ver) flags
      let pkgdata'' = pkgdata' { specFilename = Just spec }
      createDirectory ver
      createSpecFile pkgdata'' flags (Just ver)
