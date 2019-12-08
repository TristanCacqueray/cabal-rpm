-- |
-- Module      :  PackageUtils
-- Copyright   :  (C) 2013-2019  Jens Petersen
--
-- Maintainer  :  Jens Petersen <petersen@fedoraproject.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: functions related to Cabal dependency generation.

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

module PackageUtils (
  bringTarball,
  cabal_,
  editSpecField,
  getRevisedCabal,
  getSpecField,
  latestPackage,
  PackageData (..),
  packageManager,
  patchSpec,
  prepare,
  repoquery,
  rpmbuild,
  rpmInstall,
  RpmStage (..)
  ) where

import FileUtils (filesWithExtension, fileWithExtension,
                  getDirectoryContents_, mktempdir, withCurrentDirectory,
                  withTempDirectory)
import SimpleCabal (finalPackageDescription, licenseFiles, mkPackageName,
                    PackageDescription, PackageIdentifier(..), PackageName,
                    tryFindPackageDesc)
import SimpleCmd (cmd, cmd_, cmdIgnoreErr, cmdLines, grep_, removePrefix,
                  sudo, sudo_, (+-+))
import SimpleCmd.Git (isGitDir, grepGitConfig)
import SimpleCmd.Rpm (rpmspec)
import SysCmd (optionalProgram, requireProgram, rpmEval)
import Stackage (latestStackage)
import Types

#if (defined(MIN_VERSION_base) && MIN_VERSION_base(4,8,0))
#else
import Control.Applicative ((<$>))
#endif
import Control.Monad    (filterM, unless, when)

import Data.Char (toLower)
import Data.List (isPrefixOf, isSuffixOf, nub, sort)
import Data.Maybe (isNothing, isJust, fromJust)
import Data.Time.Clock (diffUTCTime, getCurrentTime)

import Distribution.Text (display, simpleParse)
import Distribution.Types.Version (nullVersion)

import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist,
                         doesFileExist, getCurrentDirectory,
                         getDirectoryContents, getModificationTime,
                         removeDirectoryRecursive, renameFile,
                         setCurrentDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>), (<.>), dropFileName, takeExtensions,
                        takeFileName)
import System.IO (hIsTerminalDevice, stdout)
import System.Posix.Files (accessTime, fileMode, getFileStatus,
                           modificationTime, setFileMode)

simplePackageDescription :: Flags -> FilePath
                         -> IO (PackageDescription, [FilePath], [FilePath])
simplePackageDescription flags cabalfile = do
  final <- finalPackageDescription flags cabalfile
  (docs, licensefiles) <- findDocsLicenses (dropFileName cabalfile) final
  return (final, docs, licensefiles)

findDocsLicenses :: FilePath -> PackageDescription -> IO ([FilePath], [FilePath])
findDocsLicenses dir pkgDesc = do
  contents <- getDirectoryContents dir
  let docs = sort $ filter unlikely $ filter (likely docNames) contents
  let licenses = sort $ nub $ licenseFiles pkgDesc
        ++ filter (likely licenseNames) contents
      docfiles = if null licenses then docs else filter (`notElem` licenses) docs
  return (docfiles, licenses)
  where docNames = ["announce", "author", "bugs", "changelog", "changes",
                    "contribut", "example", "news", "readme", "todo"]
        licenseNames = ["copying", "licence", "license"]
        likely names name = let lowerName = map toLower name
                      in any (`isPrefixOf` lowerName) names
        unlikely name = not $ any (`isSuffixOf` name) ["~", ".cabal"]

cabalFromSpec :: FilePath -> Bool -> IO FilePath
cabalFromSpec specFile revise = do
  namever <- removePrefix "ghc-" . head <$> rpmspec ["--srpm"] (Just "%{name}-%{version}") specFile
  case simpleParse namever of
    Nothing -> error "pkgid could not be parsed"
    Just pkgid -> bringTarball pkgid revise specFile
  dExists <- doesDirectoryExist namever
  if dExists
    then do
    specTime <- modificationTime <$> getFileStatus specFile
    dirTime <- accessTime <$> getFileStatus namever
    when (specTime > dirTime) $ do
      rpmbuild Prep specFile
      dExists' <- doesDirectoryExist namever
      when dExists' $ cmd_ "touch" [namever]
    else
    rpmbuild Prep specFile
  tryFindPackageDesc namever

bringTarball :: PackageIdentifier -> Bool -> FilePath -> IO ()
bringTarball pkgid revise spec = do
  havespec <- doesFileExist spec
  sources <- if havespec
             then map sourceFieldFile <$> cmdLines "spectool" ["-S", spec]
             else return [tarfile]
  srcdir <- getSourceDir
  allExist <- and <$> mapM (doesFileExist . (srcdir </>)) sources
  unless allExist $ do
    pkggit <- grepGitConfig "\\(pkgs\\|src\\)."
    when pkggit $ do
      srcnv <- grep_ tarfile "sources"
      when srcnv $
        cmd_ "fedpkg" ["sources"]
    when havespec $
      createDirectoryIfMissing True srcdir
    mapM_ (copyTarball False srcdir) sources
    haveLocalCabal <- doesFileExist $ srcdir </> display pkgid <.> "cabal"
    when (not haveLocalCabal && revise) $
      getRevisedCabal pkgid
    allExist' <- and <$> mapM (doesFileExist . (srcdir </>)) sources
    unless allExist' $
      cmd_ "spectool" ["-g", "-S", "-C", srcdir, spec]
 where
  tarfile = display pkgid <.> "tar.gz"

  sourceFieldFile :: String -> FilePath
  sourceFieldFile field =
    if null field then
      -- should be impossible
      error "Empty source field!"
    else (takeFileName . last . words) field

  copyTarball :: Bool -> FilePath -> FilePath -> IO ()
  copyTarball ranFetch dir file =
   when (takeExtensions file == ".tar.gz") $ do
    let dest = dir </> file
    already <- doesFileExist dest
    unless already $ do
      home <- getEnv "HOME"
      let cacheparent = home </> ".cabal" </> "packages"
      havecache <- doesDirectoryExist cacheparent
      unless havecache cabalUpdate
      remotes <- getDirectoryContents_ cacheparent

      let tarpath = display (pkgName pkgid) </> display (pkgVersion pkgid) </> tarfile
          paths = map (\ repo -> cacheparent </> repo </> tarpath) remotes
      -- if more than one tarball, should maybe warn if they are different
      tarballs <- filterM doesFileExist paths
      if null tarballs
        then if ranFetch
             then error $ "No" +-+ tarfile +-+ "found"
             else do
             cabal_ "fetch" ["-v0", "--no-dependencies", display pkgid]
             copyTarball True dir file
        else do
        createDirectoryIfMissing True dir
        copyFile (head tarballs) dest
        -- cabal-1.18 fetch creates tarballs with mode 0600
        stat <- getFileStatus dest
        when (fileMode stat /= 0o100644) $
          setFileMode dest 0o0644

getSourceDir :: IO FilePath
getSourceDir = do
    git <- isGitDir "."
    if git
      then getCurrentDirectory
      else fromJust <$> rpmEval "%{_sourcedir}"

getRevisedCabal :: PackageIdentifier -> IO ()
getRevisedCabal pkgid = do
  let file = display (pkgName pkgid) <.> "cabal"
  dir <- getSourceDir
  withTempDirectory $ \ _ -> do
    cmd_ "wget" ["--quiet", "https://hackage.haskell.org/package" </> display pkgid </> file]
    revised <- grep_ "x-revision" file
    when revised $ do
      cmd_ "dos2unix" ["--keepdate", file]
      renameFile file $ dir </> display pkgid <.> "cabal"

data RpmStage = Binary | Source | Prep deriving Eq

rpmbuild :: RpmStage -> FilePath -> IO ()
rpmbuild mode spec = do
  let rpmCmd = case mode of
        Binary -> "a"
        Source -> "s"
        Prep -> "p"
  cwd <- getCurrentDirectory
  gitDir <- isGitDir "."
  let rpmdirs_override =
        [ "--define="++ mcr +-+ cwd | gitDir,
          mcr <- ["_builddir", "_rpmdir", "_srcrpmdir", "_sourcedir"]]
  cmd_ "rpmbuild" $ ["-b" ++ rpmCmd] ++
    ["--nodeps" | mode == Prep] ++
    rpmdirs_override ++
    [spec]

cabalUpdate :: IO ()
cabalUpdate = do
  home <- getEnv "HOME"
  let dir = home </> ".cabal/packages/hackage.haskell.org"
  done <- checkTimestamp $ dir </> "01-index.timestamp"
  unless done $ do
    done' <- checkTimestamp $ dir </> "00-index.cache"
    unless done' $ cmd_ "cabal" ["update"]
  where
    checkTimestamp tsfile = do
      haveFile <- doesFileExist tsfile
      if haveFile then do
        ts <- getModificationTime tsfile
        t <- getCurrentTime
        -- less than 3 hours
        when (diffUTCTime t ts > 10000) $ cmd_ "cabal" ["update"]
        return True
        else
        return False

cabal :: String -> [String] -> IO [String]
cabal c args = do
  cabalUpdate
  cmdLines "cabal" (c:args)

cabal_ :: String -> [String] -> IO ()
cabal_ c args = do
  cabalUpdate
  cmd_ "cabal" (c:args)


tryUnpack :: PackageIdentifier -> Bool ->
             IO (FilePath, Maybe FilePath) -- (cabalfile, mtmpdir)
tryUnpack pkgid revise = do
  let dir = display pkgid
  isdir <- doesDirectoryExist dir
  if isdir
    then do
    mcabal <- withCurrentDirectory dir $ checkForCabalFile (Just pkgid)
    if isJust mcabal then do
      pth <- tryFindPackageDesc dir
      return (pth, Nothing)
      else
      error $ "could not find" +-+ display (pkgName pkgid) <.> "cabal"
    else do
    cwd <- getCurrentDirectory
    tmpdir <- mktempdir
    setCurrentDirectory tmpdir
    cabal_ "unpack" $ ["-v0"] ++ ["--pristine" | not revise] ++ [display pkgid]
    pth <- tryFindPackageDesc dir
    setCurrentDirectory cwd
    return (tmpdir </> pth, Just tmpdir)

latestPackage :: Stream -> PackageName -> IO PackageIdentifier
latestPackage Hackage pkg = latestHackage pkg
latestPackage stream pkg = do
  stk <- latestStackage stream pkg
  case stk of
    Just pkgid -> return pkgid
    Nothing -> latestHackage pkg

latestHackage :: PackageName -> IO PackageIdentifier
latestHackage pkgname = do
  let pkg = display pkgname
  contains_pkg <- cabal "list" ["-v0", pkg]
  let top = dropWhile (/= "*" +-+ pkg) contains_pkg
  if null top
    then error $ pkg +-+ "hackage not found"
    else do
    let field = "    Default available version: "
    let avails = map (removePrefix field) $ filter (isPrefixOf field) top
    if null avails
      then error $ pkg +-+ "latest available version not found"
      else do
      let res = pkg ++ "-" ++ head avails
      putStrLn $ res +-+ "in Hackage"
      return $ PackageIdentifier (mkPackageName pkg) $ readVersion $ head avails

checkForSpecFile :: Maybe PackageIdentifier -> IO (Maybe FilePath)
checkForSpecFile mpkgid = do
  let mpkg = display .  pkgName <$> mpkgid
  allSpecs <- filesWithExtension "." ".spec"
  -- emacs makes ".#*.spec" tmp files
  let predicate = maybe ((/= '.') . head) (\ pkg -> (`elem` [pkg <.> "spec", "ghc-" ++ pkg <.> "spec"])) mpkg
      specs = filter predicate allSpecs
  when (specs /= allSpecs && isNothing mpkg) $
    putStrLn "Warning: dir contains a hidden spec file"
  case specs of
    [one] -> return $ Just one
    [] -> return Nothing
    _ -> error "More than one spec file found!"

checkForCabalFile :: Maybe PackageIdentifier -> IO (Maybe FilePath)
checkForCabalFile mpkgid = do
  let mpkg = display . pkgName <$> mpkgid
  allCabals <- filesWithExtension "." ".cabal"
  let predicate = maybe (const True) (\ pkg -> (== pkg <.> "cabal")) mpkg
      cabals = filter predicate allCabals
  case cabals of
    [one] -> return $ Just one
    [] -> return Nothing
    _ -> error "More than one cabal file found!"

checkForPkgCabalFile :: PackageIdentifier -> IO (Maybe FilePath)
checkForPkgCabalFile pkgid = do
  let pkg = pkgName pkgid
      cabalfile = display pkg <.> "cabal"
  pkgcabal <- doesFileExist cabalfile
  if pkgcabal
    then return $ Just cabalfile
    else do
    exists <- doesDirectoryExist $ display pkgid
    if exists
      then fileWithExtension (display pkg) ".cabal"
      else return Nothing

-- findSpecFile :: PackageDescription -> RpmFlags -> IO (FilePath, Bool)
-- findSpecFile pkgDesc flags = do
--   pkgname <- findPkgName pkgDesc flags
--   let specfile = pkgname <.> "spec"
--   exists <- doesFileExist specfile
--   return (specfile, exists)

data PackageData =
  PackageData { specFilename :: Maybe FilePath
              , docFilenames :: [FilePath]
              , licenseFilenames :: [FilePath]
              , packageDesc :: PackageDescription
              }

-- Nothing implies existing packaging in cwd
-- Something implies either new packaging or some existing spec file in dir
prepare :: Flags -> Stream -> Maybe PackageIdentifier -> Bool -> IO PackageData
prepare flags stream mpkgid revise = do
  mspec <- checkForSpecFile mpkgid
  case mspec of
    Just spec -> do
      cabalfile <- cabalFromSpec spec revise
      (pkgDesc, docs, licenses) <- simplePackageDescription flags cabalfile
      return $ PackageData mspec docs licenses pkgDesc
    Nothing ->
      case mpkgid of
        Nothing -> do
          mcabal <- checkForCabalFile Nothing
          case mcabal of
            Just cabalfile -> do
              (pkgDesc, docs, licenses) <- simplePackageDescription flags cabalfile
              return $ PackageData Nothing docs licenses pkgDesc
            Nothing -> do
              cwd <- getCurrentDirectory
              prepare flags stream (simpleParse (takeFileName cwd)) revise
        Just pkgid -> do
          mcabal <- checkForPkgCabalFile pkgid
          case mcabal of
            Just cabalfile -> do
              (pkgDesc, docs, licenses) <- simplePackageDescription flags cabalfile
              return $ PackageData Nothing docs licenses pkgDesc
            Nothing -> do
              pkgid' <- if pkgVersion pkgid == nullVersion
                          then latestPackage stream (pkgName pkgid)
                          else return pkgid
              (cabalfile, mtmp) <- tryUnpack pkgid' revise
              (pkgDesc, docs, licenses) <- simplePackageDescription flags cabalfile
              maybe (return ()) removeDirectoryRecursive mtmp
              return $ PackageData Nothing docs licenses pkgDesc

patchSpec :: Bool -> Maybe FilePath -> FilePath -> FilePath -> IO ()
patchSpec dryrun mdir oldspec newspec = do
  diff <- cmdIgnoreErr "diff" ["-u2", "-I", "- spec file generated by cabal-rpm", "-I", "Fedora Haskell SIG <haskell@lists.fedoraproject.org>", oldspec, newspec] "" >>= cmdIgnoreErr "sed" ["-e", "s/.cblrpm//"]
  putStrLn diff
  unless dryrun $ do
    out <- cmdIgnoreErr "patch" opts diff
    putStrLn out
  where
    opts = ["--fuzz=1"] ++ ["-p1" | '/' `elem` newspec] ++ maybe [] (\ d -> ["-d", d]) mdir

packageManager :: IO String
packageManager = do
  havednf <- optionalProgram "dnf"
  if havednf
    then return "dnf"
    else requireProgram "yum" >> return "yum"

repoquery :: [String] -> String -> IO String
repoquery args key = do
  havednf <- optionalProgram "dnf"
  let (prog, subcmd) = if havednf then ("dnf", ["repoquery", "-q"]) else ("repoquery", [])
  sudo prog (subcmd ++ args ++ [key])

rpmInstall :: Bool -> [String] -> IO ()
rpmInstall _ [] = return ()
rpmInstall yes rpms = do
  pkginstaller <- packageManager
  let (inst, arg) = if pkginstaller == "dnf" then ("dnf", "install") else ("yum", "localinstall")
  tty <- hIsTerminalDevice stdout
  sudo_ inst $ ["-y" | yes || not tty] ++ [arg] ++ rpms

editSpecField :: String -> String -> FilePath -> IO ()
editSpecField field new spec =
  cmd_ "sed" ["-i", "-e s/^\\(" ++ field ++ ":\\s\\+\\).*/\\1" ++ new ++ "/", spec]

getSpecField :: String -> FilePath -> IO String
getSpecField field spec =
  cmd "sed" ["-n", "-e s/^" ++ field ++ ":\\s\\+\\(\\S\\+\\)/\\1/p", spec]
