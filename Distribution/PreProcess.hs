-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PreProcess
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  GHC, Hugs
--
{- Copyright (c) 2003-2004, Isaac Jones, Malcolm Wallace
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.PreProcess (preprocessSources, knownSuffixHandlers,
                                PPSuffixHandler, PreProcessor)
    where

import Distribution.PreProcess.Unlit(plain, unlit)
import Distribution.Package (PackageDescription(..), BuildInfo(..), Executable(..))
import Distribution.Simple.Configure (LocalBuildInfo(..))
import Distribution.Simple.Utils (setupMessage,moveSources, pathJoin,
                                  withLib, rawSystemPath, splitFilePath,
                                  joinFilenameDir, joinExt, moduleToFilePath)
import System.Exit (ExitCode(..))

import Data.Maybe(catMaybes)

-- |A preprocessor must fulfill this basic interface.  It can be an
-- external program, or just a function.
type PreProcessor = FilePath  -- ^Location of the source file in need of preprocessing
                  -> FilePath -- ^Output filename
                  -> IO ExitCode


-- |How to dispatch this file to a preprocessor.  Is there a better
-- way to handle this "Unlit" business?  It is nice that it can handle
-- happy, for instance.  Maybe we need a way to chain preprocessors
-- that would solve this problem.

type PPSuffixHandler
    = (String, (String->String->String), PreProcessor)

-- |Copy and (possibly) preprocess sources from hsSourceDirs
preprocessSources :: PackageDescription 
		  -> LocalBuildInfo 
                  -> [PPSuffixHandler]  -- ^ preprocessors to try
		  -> FilePath           {- ^ Directory to put preprocessed 
				             sources in -}
		  -> IO ()

preprocessSources pkg_descr _ handlers pref = 
    do
    setupMessage "Preprocessing" pkg_descr
    -- preprocess all sources before moving them
    allSources <- findAllSourceFiles pkg_descr [a | (a, _, _) <- knownSuffixHandlers]
    sequence [dispatchPP src handlers | src <- allSources] -- FIX: output errors?
    -- move sources into place
    withLib pkg_descr $ \lib ->
        moveSources (hsSourceDir lib) (pathJoin [pref, hsSourceDir lib]) (modules lib) ["hs","lhs"] 
    sequence_ [ moveSources (hsSourceDir exeBi) (pathJoin [pref, hsSourceDir exeBi]) (modules exeBi) ["hs","lhs"]
              | Executable _ _ exeBi <- executables pkg_descr]

dispatchPP :: FilePath -> [ PPSuffixHandler ] -> IO ExitCode
dispatchPP p handlers
    = do let (dir, file, ext) = splitFilePath p
         let (Just (lit, pp)) = findPP ext handlers --FIX: Nothing case?
         pp p (joinFilenameDir dir (joinExt file "hs"))

findPP :: String -- ^Extension
       -> [PPSuffixHandler]
       -> Maybe ((String -> String -> String), PreProcessor)
findPP ext ((e2, lit, pp):t)
    | e2 == ext = Just (lit, pp)
    | otherwise = findPP ext t
findPP _ [] = Nothing


-- |Locate the source files based on the module names, the search
-- pathes (both in PackageDescription) and the suffixes we might be
-- interested in.
findAllSourceFiles :: PackageDescription
                   -> [String] -- ^search suffixes
                   -> IO [FilePath]
findAllSourceFiles PackageDescription{executables=execs, library=lib} allSuffixes
    = do exeFiles <- sequence [buildInfoSources (buildInfo e) allSuffixes | e <- execs]
         libFiles <- case lib of 
                       Just bi -> buildInfoSources bi allSuffixes
                       Nothing -> return []
         return $ catMaybes ((concat exeFiles) ++ libFiles)

        where buildInfoSources :: BuildInfo -> [String] -> IO [Maybe FilePath]
              buildInfoSources BuildInfo{modules=mods, hsSourceDir=dir} suffixes
                  = sequence [moduleToFilePath dir modu suffixes | modu <- mods]


-- ------------------------------------------------------------
-- * known preprocessors
-- ------------------------------------------------------------

ppCpp, ppGreenCard, ppHsc2hs, ppC2hs, ppHappy, ppNone :: PreProcessor

ppCpp inFile outFile
    = rawSystemPath "cpphs" ["-O" ++ outFile, inFile]
ppGreenCard inFile outFile
    = rawSystemPath "green-card" ["-tffi", "-o" ++ outFile, inFile]
ppHsc2hs = standardPP "hsc2hs"
ppC2hs inFile outFile
    = rawSystemPath "c2hs" ["-o " ++ outFile, inFile]
ppHappy = standardPP "happy"
ppNone _ _  = return ExitSuccess

ppTestHandler :: FilePath -- ^InFile
              -> FilePath -- ^OutFile
              -> IO ExitCode
ppTestHandler inFile outFile
    = do stuff <- readFile inFile
         writeFile outFile ("-- this file has been preprocessed as a test\n\n" ++ stuff)
         return ExitSuccess

standardPP :: String -> PreProcessor
standardPP eName inFile outFile
    = rawSystemPath eName ["-o" ++ outFile, inFile]

-- |Leave in unlit since some preprocessors can't handle literated
-- source?
knownSuffixHandlers :: [ PPSuffixHandler ]
knownSuffixHandlers =
  [ ("gc",     plain, ppGreenCard)
  , ("chs",    plain, ppC2hs)
  , ("hsc",    plain, ppHsc2hs)
  , ("y",      plain, ppHappy)
  , ("ly",     unlit, ppHappy)
  , ("cpphs",  plain, ppCpp)
  , ("gc",     plain, ppNone)	-- note, for nhc98 only
  , ("hs",     plain, ppNone)
  , ("lhs",    unlit, ppNone)
  , ("testSuffix", plain, ppTestHandler)
  ] 
