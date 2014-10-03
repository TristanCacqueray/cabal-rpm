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
import SysCmd (shell, (+-+))

import Distribution.PackageDescription (PackageDescription (..))
import Distribution.Simple.Utils (die)
                                        
import System.Directory (createDirectory)

update :: PackageData -> RpmFlags -> IO ()
update pkgdata flags =
  case specFilename pkgdata of
    Nothing -> die "No (unique) .spec file in directory."
    Just _spec -> do
      withTempDirectory $ do
        let pkg = package $ packageDesc pkgdata
            name = packageName pkg
            ver = packageVersion pkg
            current = name ++ "-" ++ ver
        curspec <- createSpecVersion current
        latest <- latestPkg name
        newspec <- createSpecVersion latest
        if current == latest
          then error $ current +-+ "is latest version."
          else shell $ "diff -u -I \"- spec file generated by cabal-rpm\" -I \"Fedora Haskell SIG <haskell@lists.fedoraproject.org>\"" +-+ curspec +-+ newspec +-+ "|| :"
  where
    createSpecVersion :: String -> IO FilePath
    createSpecVersion ver = do
      pkgdata' <- prepare (Just ver) flags
      createDirectory ver
      spec <- createSpecFile pkgdata' flags (Just ver)
      return (spec)
