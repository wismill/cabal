{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Build
-- Copyright   :  Isaac Jones 2003-2005,
--                Ross Paterson 2006,
--                Duncan Coutts 2007-2008, 2012
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This is the entry point to actually building the modules in a package. It
-- doesn't actually do much itself, most of the work is delegated to
-- compiler-specific actions. It does do some non-compiler specific bits like
-- running pre-processors.
--

module Distribution.Simple.Build (
    build, repl,
    startInterpreter,

    initialBuildSteps,
    createInternalPackageDB,
    componentInitialBuildSteps,
    writeAutogenFiles,
  ) where

import Prelude ()
import Distribution.Compat.Prelude
import Distribution.Utils.Generic

import Distribution.Types.ComponentLocalBuildInfo
import Distribution.Types.ComponentRequestedSpec
import Distribution.Types.Dependency
import Distribution.Types.ExecutableScope
import Distribution.Types.ForeignLib
import Distribution.Types.LibraryVisibility
import Distribution.Types.LocalBuildInfo
import Distribution.Types.MungedPackageId
import Distribution.Types.MungedPackageName
import Distribution.Types.ModuleRenaming
import Distribution.Types.TargetInfo
import Distribution.Utils.Path

import Distribution.Package
import Distribution.Backpack
import Distribution.Backpack.DescribeUnitId
import qualified Distribution.Simple.GHC   as GHC
import qualified Distribution.Simple.GHCJS as GHCJS
import qualified Distribution.Simple.UHC   as UHC
import qualified Distribution.Simple.HaskellSuite as HaskellSuite
import qualified Distribution.Simple.PackageIndex as Index

import Distribution.Simple.Build.Macros      (generateCabalMacrosHeader)
import Distribution.Simple.Build.PackageInfoModule (generatePackageInfoModule)
import Distribution.Simple.Build.PathsModule (generatePathsModule)
import qualified Distribution.Simple.Program.HcPkg as HcPkg

import Distribution.Simple.Compiler
import Distribution.PackageDescription
import qualified Distribution.InstalledPackageInfo as IPI
import Distribution.InstalledPackageInfo (InstalledPackageInfo)
import qualified Distribution.ModuleName as ModuleName

import Distribution.Simple.Setup
import Distribution.Simple.BuildTarget
import Distribution.Simple.BuildToolDepends
import Distribution.Simple.PreProcess
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Program.Builtin (haskellSuiteProgram)
import qualified Distribution.Simple.Program.GHC   as GHC
import Distribution.Simple.Program.Types
import Distribution.Simple.ShowBuildInfo
import Distribution.Simple.BuildPaths
import Distribution.Simple.Configure
import Distribution.Simple.Register
import Distribution.Simple.Test.LibV09
import Distribution.Simple.Utils
import Distribution.Utils.Json

import Distribution.System
import Distribution.Pretty
import Distribution.Verbosity
import Distribution.Version (thisVersion)

import Distribution.Compat.Graph (IsNode(..))

import Control.Monad
import qualified Data.ByteString.Lazy as LBS
import System.FilePath ( (</>), (<.>), takeDirectory )
import System.Directory ( getCurrentDirectory, removeFile, doesFileExist )

-- -----------------------------------------------------------------------------
-- |Build the libraries and executables in this package.

build    :: PackageDescription  -- ^ Mostly information from the .cabal file
         -> LocalBuildInfo      -- ^ Configuration information
         -> BuildFlags          -- ^ Flags that the user passed to build
         -> [ PPSuffixHandler ] -- ^ preprocessors to run before compiling
         -> IO ()
build pkg_descr lbi flags suffixes = do
  targets <- readTargetInfos verbosity pkg_descr lbi (buildArgs flags)
  let componentsToBuild = neededTargetsInBuildOrder' pkg_descr lbi (map nodeKey targets)
  info verbosity $ "Component build order: "
                ++ intercalate ", "
                    (map (showComponentName . componentLocalName . targetCLBI)
                        componentsToBuild)

  when (null targets) $
    -- Only bother with this message if we're building the whole package
    setupMessage verbosity "Building" (packageId pkg_descr)

  internalPackageDB <- createInternalPackageDB verbosity lbi distPref

  -- Before the actual building, dump out build-information.
  -- This way, if the actual compilation failed, the options have still been
  -- dumped.
  dumpBuildInfo verbosity distPref (configDumpBuildInfo (configFlags lbi)) pkg_descr lbi flags

  -- Now do the actual building
  (\f -> foldM_ f (installedPkgs lbi) componentsToBuild) $ \index target -> do
    let comp = targetComponent target
        clbi = targetCLBI target
    componentInitialBuildSteps distPref pkg_descr lbi clbi verbosity
    let bi     = componentBuildInfo comp
        progs' = addInternalBuildTools pkg_descr lbi bi (withPrograms lbi)
        lbi'   = lbi {
                   withPrograms  = progs',
                   withPackageDB = withPackageDB lbi ++ [internalPackageDB],
                   installedPkgs = index
                 }
    mb_ipi <- buildComponent verbosity (buildNumJobs flags) pkg_descr
                   lbi' suffixes comp clbi distPref
    return (maybe index (Index.insert `flip` index) mb_ipi)

  return ()
 where
  distPref  = fromFlag (buildDistPref flags)
  verbosity = fromFlag (buildVerbosity flags)


-- | Write available build information for 'LocalBuildInfo' to disk.
--
-- Dumps detailed build information 'build-info.json' to the given directory.
-- Build information contains basics such as compiler details, but also
-- lists what modules a component contains and how to compile the component, assuming
-- lib:Cabal made sure that dependencies are up-to-date.
dumpBuildInfo :: Verbosity
              -> FilePath           -- ^ To which directory should the build-info be dumped?
              -> Flag DumpBuildInfo -- ^ Should we dump detailed build information for this component?
              -> PackageDescription -- ^ Mostly information from the .cabal file
              -> LocalBuildInfo     -- ^ Configuration information
              -> BuildFlags         -- ^ Flags that the user passed to build
              -> IO ()
dumpBuildInfo verbosity distPref dumpBuildInfoFlag pkg_descr lbi flags = do
  when shouldDumpBuildInfo $ do
    -- Changing this line might break consumers of the dumped build info.
    -- Announce changes on mailing lists!
    let activeTargets = allTargetsInBuildOrder' pkg_descr lbi
    info verbosity $ "Dump build information for: "
                  ++ intercalate ", "
                      (map (showComponentName . componentLocalName . targetCLBI)
                          activeTargets)
    pwd <- getCurrentDirectory

    (compilerProg, _) <- case flavorToProgram (compilerFlavor (compiler lbi)) of
      Nothing -> die' verbosity $ "dumpBuildInfo: Unknown compiler flavor: "
                               ++ show (compilerFlavor (compiler lbi))
      Just program -> requireProgram verbosity program (withPrograms lbi)

    let (warns, json) = mkBuildInfo pwd pkg_descr lbi flags (compilerProg, compiler lbi) activeTargets
        buildInfoText = renderJson json
    unless (null warns) $
      warn verbosity $ "Encountered warnings while dumping build-info:\n"
                    ++ unlines warns
    LBS.writeFile (buildInfoPref distPref) buildInfoText

  when (not shouldDumpBuildInfo) $ do
    -- Remove existing build-info.json as it might be outdated now.
    exists <- doesFileExist (buildInfoPref distPref)
    when exists $ removeFile (buildInfoPref distPref)
  where
    shouldDumpBuildInfo = fromFlagOrDefault NoDumpBuildInfo dumpBuildInfoFlag == DumpBuildInfo

    -- | Given the flavor of the compiler, try to find out
    -- which program we need.
    flavorToProgram :: CompilerFlavor -> Maybe Program
    flavorToProgram GHC             = Just ghcProgram
    flavorToProgram GHCJS           = Just ghcjsProgram
    flavorToProgram UHC             = Just uhcProgram
    flavorToProgram JHC             = Just jhcProgram
    flavorToProgram HaskellSuite {} = Just haskellSuiteProgram
    flavorToProgram _     = Nothing


repl     :: PackageDescription  -- ^ Mostly information from the .cabal file
         -> LocalBuildInfo      -- ^ Configuration information
         -> ReplFlags           -- ^ Flags that the user passed to build
         -> [ PPSuffixHandler ] -- ^ preprocessors to run before compiling
         -> [String]
         -> IO ()
repl pkg_descr lbi flags suffixes args = do
  let distPref  = fromFlag (replDistPref flags)
      verbosity = fromFlag (replVerbosity flags)

  target <- readTargetInfos verbosity pkg_descr lbi args >>= \r -> case r of
    -- This seems DEEPLY questionable.
    []       -> case allTargetsInBuildOrder' pkg_descr lbi of
      (target:_) -> return target
      []         -> die' verbosity $ "Failed to determine target."
    [target] -> return target
    _        -> die' verbosity $ "The 'repl' command does not support multiple targets at once."
  let componentsToBuild = neededTargetsInBuildOrder' pkg_descr lbi [nodeKey target]
  debug verbosity $ "Component build order: "
                 ++ intercalate ", "
                      (map (showComponentName . componentLocalName . targetCLBI)
                           componentsToBuild)

  internalPackageDB <- createInternalPackageDB verbosity lbi distPref

  let lbiForComponent comp lbi' =
        lbi' {
          withPackageDB = withPackageDB lbi ++ [internalPackageDB],
          withPrograms  = addInternalBuildTools pkg_descr lbi'
                            (componentBuildInfo comp) (withPrograms lbi')
        }

  -- build any dependent components
  sequence_
    [ do let clbi = targetCLBI subtarget
             comp = targetComponent subtarget
             lbi' = lbiForComponent comp lbi
         componentInitialBuildSteps distPref pkg_descr lbi clbi verbosity
         buildComponent verbosity NoFlag
                        pkg_descr lbi' suffixes comp clbi distPref
    | subtarget <- safeInit componentsToBuild ]

  -- REPL for target components
  let clbi = targetCLBI target
      comp = targetComponent target
      lbi' = lbiForComponent comp lbi
      replFlags = replReplOptions flags
  componentInitialBuildSteps distPref pkg_descr lbi clbi verbosity
  replComponent replFlags verbosity pkg_descr lbi' suffixes comp clbi distPref


-- | Start an interpreter without loading any package files.
startInterpreter :: Verbosity -> ProgramDb -> Compiler -> Platform
                 -> PackageDBStack -> IO ()
startInterpreter verbosity programDb comp platform packageDBs =
  case compilerFlavor comp of
    GHC   -> GHC.startInterpreter   verbosity programDb comp platform packageDBs
    GHCJS -> GHCJS.startInterpreter verbosity programDb comp platform packageDBs
    _     -> die' verbosity "A REPL is not supported with this compiler."

buildComponent :: Verbosity
               -> Flag (Maybe Int)
               -> PackageDescription
               -> LocalBuildInfo
               -> [PPSuffixHandler]
               -> Component
               -> ComponentLocalBuildInfo
               -> FilePath
               -> IO (Maybe InstalledPackageInfo)
buildComponent verbosity numJobs pkg_descr lbi suffixes
               comp@(CLib lib) clbi distPref = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    let libbi = libBuildInfo lib
        lib' = lib { libBuildInfo = flip addExtraAsmSources extras
                                  $ flip addExtraCmmSources extras
                                  $ flip addExtraCxxSources extras
                                  $ flip addExtraCSources   extras
                                  $ libbi
                   }

    buildLib verbosity numJobs pkg_descr lbi lib' clbi

    let oneComponentRequested (OneComponentRequestedSpec _) = True
        oneComponentRequested _ = False
    -- Don't register inplace if we're only building a single component;
    -- it's not necessary because there won't be any subsequent builds
    -- that need to tag us
    if (not (oneComponentRequested (componentEnabledSpec lbi)))
      then do
        -- Register the library in-place, so exes can depend
        -- on internally defined libraries.
        pwd <- getCurrentDirectory
        let -- The in place registration uses the "-inplace" suffix, not an ABI hash
            installedPkgInfo = inplaceInstalledPackageInfo pwd distPref pkg_descr
                                    -- NB: Use a fake ABI hash to avoid
                                    -- needing to recompute it every build.
                                    (mkAbiHash "inplace") lib' lbi clbi

        debug verbosity $ "Registering inplace:\n" ++ (IPI.showInstalledPackageInfo installedPkgInfo)
        registerPackage verbosity (compiler lbi) (withPrograms lbi)
                        (withPackageDB lbi) installedPkgInfo
                        HcPkg.defaultRegisterOptions {
                          HcPkg.registerMultiInstance = True
                        }
        return (Just installedPkgInfo)
      else return Nothing

buildComponent verbosity numJobs pkg_descr lbi suffixes
               comp@(CFLib flib) clbi _distPref = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    buildFLib verbosity numJobs pkg_descr lbi flib clbi
    return Nothing

buildComponent verbosity numJobs pkg_descr lbi suffixes
               comp@(CExe exe) clbi _ = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    let ebi = buildInfo exe
        exe' = exe { buildInfo = addExtraCSources ebi extras }
    buildExe verbosity numJobs pkg_descr lbi exe' clbi
    return Nothing


buildComponent verbosity numJobs pkg_descr lbi suffixes
               comp@(CTest test@TestSuite { testInterface = TestSuiteExeV10{} })
               clbi _distPref = do
    let exe = testSuiteExeV10AsExe test
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    (genDir, generatedExtras) <- generateCode (testCodeGenerators test) (testName test) pkg_descr (testBuildInfo test) lbi clbi verbosity
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    let ebi = buildInfo exe
        exe' = exe { buildInfo = addSrcDir (addExtraOtherModules (addExtraCSources ebi extras) generatedExtras) genDir } -- todo extend hssrcdirs
    buildExe verbosity numJobs pkg_descr lbi exe' clbi
    return Nothing

buildComponent verbosity numJobs pkg_descr lbi0 suffixes
               comp@(CTest
                 test@TestSuite { testInterface = TestSuiteLibV09{} })
               clbi -- This ComponentLocalBuildInfo corresponds to a detailed
                    -- test suite and not a real component. It should not
                    -- be used, except to construct the CLBIs for the
                    -- library and stub executable that will actually be
                    -- built.
               distPref = do
    pwd <- getCurrentDirectory
    let (pkg, lib, libClbi, lbi, ipi, exe, exeClbi) =
          testSuiteLibV09AsLibAndExe pkg_descr test clbi lbi0 distPref pwd
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi -- TODO find cpphs processed files
    (genDir, generatedExtras) <- generateCode (testCodeGenerators test) (testName test) pkg_descr (testBuildInfo test) lbi clbi verbosity
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    let libbi = libBuildInfo lib
        lib' = lib { libBuildInfo = addSrcDir (addExtraOtherModules libbi generatedExtras) genDir }
    buildLib verbosity numJobs pkg lbi lib' libClbi
    -- NB: need to enable multiple instances here, because on 7.10+
    -- the package name is the same as the library, and we still
    -- want the registration to go through.
    registerPackage verbosity (compiler lbi) (withPrograms lbi)
                    (withPackageDB lbi) ipi
                    HcPkg.defaultRegisterOptions {
                      HcPkg.registerMultiInstance = True
                    }
    let ebi = buildInfo exe
        -- NB: The stub executable is linked against the test-library
        --     which already contains all `other-modules`, so we need
        --     to remove those from the stub-exe's build-info
        exe' = exe { buildInfo = (addExtraCSources ebi extras) { otherModules = [] } }
    buildExe verbosity numJobs pkg_descr lbi exe' exeClbi
    return Nothing -- Can't depend on test suite


buildComponent verbosity _ _ _ _
               (CTest TestSuite { testInterface = TestSuiteUnsupported tt })
               _ _ =
    die' verbosity $ "No support for building test suite type " ++ prettyShow tt


buildComponent verbosity numJobs pkg_descr lbi suffixes
               comp@(CBench bm@Benchmark { benchmarkInterface = BenchmarkExeV10 {} })
               clbi _distPref = do
    let exe = benchmarkExeV10asExe bm
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    setupMessage' verbosity "Building" (packageId pkg_descr)
      (componentLocalName clbi) (maybeComponentInstantiatedWith clbi)
    let ebi = buildInfo exe
        exe' = exe { buildInfo = addExtraCSources ebi extras }
    buildExe verbosity numJobs pkg_descr lbi exe' clbi
    return Nothing


buildComponent verbosity _ _ _ _
               (CBench Benchmark { benchmarkInterface = BenchmarkUnsupported tt })
               _ _ =
    die' verbosity $ "No support for building benchmark type " ++ prettyShow tt



generateCode
        :: [String]
           -> UnqualComponentName
           -> PackageDescription
           -> BuildInfo
           -> LocalBuildInfo
           -> ComponentLocalBuildInfo
           -> Verbosity
           -> IO (FilePath, [ModuleName.ModuleName])
generateCode codeGens nm pdesc bi lbi clbi verbosity = do
     when (not . null $ codeGens) $ createDirectoryIfMissingVerbose verbosity True tgtDir
     (\x -> (tgtDir,x)) . concat <$> mapM go codeGens
   where
     allLibs = (maybe id (:) $ library pdesc) (subLibraries pdesc)
     dependencyLibs = filter (const True) allLibs -- intersect with componentPackageDeps of clbi
     srcDirs = concatMap (hsSourceDirs . libBuildInfo) dependencyLibs
     nm' = unUnqualComponentName nm
     tgtDir = buildDir lbi </> nm' </> nm' ++ "-gen"
     go :: String -> IO [ModuleName.ModuleName]
     go codeGenProg = fmap fromString . lines <$> getDbProgramOutput verbosity (simpleProgram codeGenProg) (withPrograms lbi)
                         ((tgtDir : map getSymbolicPath srcDirs) ++
                         ("--" :
                          GHC.renderGhcOptions (compiler lbi) (hostPlatform lbi) (GHC.componentGhcOptions verbosity lbi bi clbi tgtDir)))


-- | Add extra C sources generated by preprocessing to build
-- information.
addExtraCSources :: BuildInfo -> [FilePath] -> BuildInfo
addExtraCSources bi extras = bi { cSources = new }
  where new = ordNub (extras ++ cSources bi)

-- | Add extra C++ sources generated by preprocessing to build
-- information.
addExtraCxxSources :: BuildInfo -> [FilePath] -> BuildInfo
addExtraCxxSources bi extras = bi { cxxSources = new }
  where new = ordNub (extras ++ cxxSources bi)

-- | Add extra C-- sources generated by preprocessing to build
-- information.
addExtraCmmSources :: BuildInfo -> [FilePath] -> BuildInfo
addExtraCmmSources bi extras = bi { cmmSources = new }
  where new = ordNub (extras ++ cmmSources bi)

-- | Add extra ASM sources generated by preprocessing to build
-- information.
addExtraAsmSources :: BuildInfo -> [FilePath] -> BuildInfo
addExtraAsmSources bi extras = bi { asmSources = new }
  where new = ordNub (extras ++ asmSources bi)

-- | Add extra HS modules generated by preprocessing to build
-- information.
addExtraOtherModules :: BuildInfo -> [ModuleName.ModuleName] -> BuildInfo
addExtraOtherModules bi extras = bi { otherModules = new }
  where new = ordNub (extras ++ otherModules bi)

-- | Add extra source dir for generated modules.
addSrcDir :: BuildInfo -> FilePath -> BuildInfo
addSrcDir bi extra = bi { hsSourceDirs = new }
  where new = ordNub (unsafeMakeSymbolicPath extra : hsSourceDirs bi)

replComponent :: ReplOptions
              -> Verbosity
              -> PackageDescription
              -> LocalBuildInfo
              -> [PPSuffixHandler]
              -> Component
              -> ComponentLocalBuildInfo
              -> FilePath
              -> IO ()
replComponent replFlags verbosity pkg_descr lbi suffixes
               comp@(CLib lib) clbi _ = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    let libbi = libBuildInfo lib
        lib' = lib { libBuildInfo = libbi { cSources = cSources libbi ++ extras } }
    replLib replFlags verbosity pkg_descr lbi lib' clbi

replComponent replFlags verbosity pkg_descr lbi suffixes
               comp@(CFLib flib) clbi _ = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    replFLib replFlags verbosity pkg_descr lbi flib clbi

replComponent replFlags verbosity pkg_descr lbi suffixes
               comp@(CExe exe) clbi _ = do
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    let ebi = buildInfo exe
        exe' = exe { buildInfo = ebi { cSources = cSources ebi ++ extras } }
    replExe replFlags verbosity pkg_descr lbi exe' clbi


replComponent replFlags verbosity pkg_descr lbi suffixes
               comp@(CTest test@TestSuite { testInterface = TestSuiteExeV10{} })
               clbi _distPref = do
    let exe = testSuiteExeV10AsExe test
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    let ebi = buildInfo exe
        exe' = exe { buildInfo = ebi { cSources = cSources ebi ++ extras } }
    replExe replFlags verbosity pkg_descr lbi exe' clbi


replComponent replFlags verbosity pkg_descr lbi0 suffixes
               comp@(CTest
                 test@TestSuite { testInterface = TestSuiteLibV09{} })
               clbi distPref = do
    pwd <- getCurrentDirectory
    let (pkg, lib, libClbi, lbi, _, _, _) =
          testSuiteLibV09AsLibAndExe pkg_descr test clbi lbi0 distPref pwd
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    let libbi = libBuildInfo lib
        lib' = lib { libBuildInfo = libbi { cSources = cSources libbi ++ extras } }
    replLib replFlags verbosity pkg lbi lib' libClbi


replComponent _ verbosity _ _ _
              (CTest TestSuite { testInterface = TestSuiteUnsupported tt })
              _ _ =
    die' verbosity $ "No support for building test suite type " ++ prettyShow tt


replComponent replFlags verbosity pkg_descr lbi suffixes
               comp@(CBench bm@Benchmark { benchmarkInterface = BenchmarkExeV10 {} })
               clbi _distPref = do
    let exe = benchmarkExeV10asExe bm
    preprocessComponent pkg_descr comp lbi clbi False verbosity suffixes
    extras <- preprocessExtras verbosity comp lbi
    let ebi = buildInfo exe
        exe' = exe { buildInfo = ebi { cSources = cSources ebi ++ extras } }
    replExe replFlags verbosity pkg_descr lbi exe' clbi


replComponent _ verbosity _ _ _
              (CBench Benchmark { benchmarkInterface = BenchmarkUnsupported tt })
              _ _ =
    die' verbosity $ "No support for building benchmark type " ++ prettyShow tt

----------------------------------------------------
-- Shared code for buildComponent and replComponent
--

-- | Translate a exe-style 'TestSuite' component into an exe for building
testSuiteExeV10AsExe :: TestSuite -> Executable
testSuiteExeV10AsExe test@TestSuite { testInterface = TestSuiteExeV10 _ mainFile } =
    Executable {
      exeName    = testName test,
      modulePath = mainFile,
      exeScope   = ExecutablePublic,
      buildInfo  = testBuildInfo test
    }
testSuiteExeV10AsExe TestSuite{} = error "testSuiteExeV10AsExe: wrong kind"

-- | Translate a exe-style 'Benchmark' component into an exe for building
benchmarkExeV10asExe :: Benchmark -> Executable
benchmarkExeV10asExe bm@Benchmark { benchmarkInterface = BenchmarkExeV10 _ mainFile } =
    Executable {
      exeName    = benchmarkName bm,
      modulePath = mainFile,
      exeScope   = ExecutablePublic,
      buildInfo  = benchmarkBuildInfo bm
    }
benchmarkExeV10asExe Benchmark{} = error "benchmarkExeV10asExe: wrong kind"

-- | Translate a lib-style 'TestSuite' component into a lib + exe for building
testSuiteLibV09AsLibAndExe :: PackageDescription
                           -> TestSuite
                           -> ComponentLocalBuildInfo
                           -> LocalBuildInfo
                           -> FilePath
                           -> FilePath
                           -> (PackageDescription,
                               Library, ComponentLocalBuildInfo,
                               LocalBuildInfo,
                               IPI.InstalledPackageInfo,
                               Executable, ComponentLocalBuildInfo)
testSuiteLibV09AsLibAndExe pkg_descr
                     test@TestSuite { testInterface = TestSuiteLibV09 _ m }
                     clbi lbi distPref pwd =
    (pkg, lib, libClbi, lbi, ipi, exe, exeClbi)
  where
    bi  = testBuildInfo test
    lib = Library {
            libName = LMainLibName,
            exposedModules = [ m ],
            reexportedModules = [],
            signatures = [],
            libExposed     = True,
            libVisibility  = LibraryVisibilityPrivate,
            libBuildInfo   = bi
          }
    -- This is, like, the one place where we use a CTestName for a library.
    -- Should NOT use library name, since that could conflict!
    PackageIdentifier pkg_name pkg_ver = package pkg_descr
    -- Note: we do make internal library from the test!
    compat_name = MungedPackageName pkg_name (LSubLibName (testName test))
    compat_key = computeCompatPackageKey (compiler lbi) compat_name pkg_ver (componentUnitId clbi)
    libClbi = LibComponentLocalBuildInfo
                { componentPackageDeps = componentPackageDeps clbi
                , componentInternalDeps = componentInternalDeps clbi
                , componentIsIndefinite_ = False
                , componentExeDeps = componentExeDeps clbi
                , componentLocalName = CLibName $ LSubLibName $ testName test
                , componentIsPublic = False
                , componentIncludes = componentIncludes clbi
                , componentUnitId = componentUnitId clbi
                , componentComponentId = componentComponentId clbi
                , componentInstantiatedWith = []
                , componentCompatPackageName = compat_name
                , componentCompatPackageKey = compat_key
                , componentExposedModules = [IPI.ExposedModule m Nothing]
                }
    pkgName' = mkPackageName $ prettyShow compat_name
    pkg = pkg_descr {
            package      = (package pkg_descr) { pkgName = pkgName' }
          , executables  = []
          , testSuites   = []
          , subLibraries = [lib]
          }
    ipi    = inplaceInstalledPackageInfo pwd distPref pkg (mkAbiHash "") lib lbi libClbi
    testDir = buildDir lbi </> stubName test
          </> stubName test ++ "-tmp"
    testLibDep = Dependency
        pkgName'
        (thisVersion $ pkgVersion $ package pkg_descr)
        mainLibSet
    exe = Executable {
            exeName    = mkUnqualComponentName $ stubName test,
            modulePath = stubFilePath test,
            exeScope   = ExecutablePublic,
            buildInfo  = (testBuildInfo test) {
                           hsSourceDirs       = [ unsafeMakeSymbolicPath testDir ],
                           targetBuildDepends = testLibDep
                             : (targetBuildDepends $ testBuildInfo test)
                         }
          }
    -- | The stub executable needs a new 'ComponentLocalBuildInfo'
    -- that exposes the relevant test suite library.
    deps = (IPI.installedUnitId ipi, mungedId ipi)
         : (filter (\(_, x) -> let name = prettyShow $ mungedName x
                               in name == "Cabal" || name == "base")
                   (componentPackageDeps clbi))
    exeClbi = ExeComponentLocalBuildInfo {
                -- TODO: this is a hack, but as long as this is unique
                -- (doesn't clobber something) we won't run into trouble
                componentUnitId = mkUnitId (stubName test),
                componentComponentId = mkComponentId (stubName test),
                componentInternalDeps = [componentUnitId clbi],
                componentExeDeps = [],
                componentLocalName = CExeName $ mkUnqualComponentName $ stubName test,
                componentPackageDeps = deps,
                -- Assert DefUnitId invariant!
                -- Executable can't be indefinite, so dependencies must
                -- be definite packages.
                componentIncludes = zip (map (DefiniteUnitId . unsafeMkDefUnitId . fst) deps)
                                        (repeat defaultRenaming)
              }
testSuiteLibV09AsLibAndExe _ TestSuite{} _ _ _ _ = error "testSuiteLibV09AsLibAndExe: wrong kind"


-- | Initialize a new package db file for libraries defined
-- internally to the package.
createInternalPackageDB :: Verbosity -> LocalBuildInfo -> FilePath
                        -> IO PackageDB
createInternalPackageDB verbosity lbi distPref = do
    existsAlready <- doesPackageDBExist dbPath
    when existsAlready $ deletePackageDB dbPath
    createPackageDB verbosity (compiler lbi) (withPrograms lbi) False dbPath
    return (SpecificPackageDB dbPath)
  where
    dbPath = internalPackageDBPath lbi distPref

addInternalBuildTools :: PackageDescription -> LocalBuildInfo -> BuildInfo
                      -> ProgramDb -> ProgramDb
addInternalBuildTools pkg lbi bi progs =
    foldr updateProgram progs internalBuildTools
  where
    internalBuildTools =
      [ simpleConfiguredProgram toolName' (FoundOnSystem toolLocation)
      | toolName <- getAllInternalToolDependencies pkg bi
      , let toolName' = unUnqualComponentName toolName
      , let toolLocation = buildDir lbi </> toolName' </> toolName' <.> exeExtension (hostPlatform lbi) ]


-- TODO: build separate libs in separate dirs so that we can build
-- multiple libs, e.g. for 'LibTest' library-style test suites
buildLib :: Verbosity -> Flag (Maybe Int)
                      -> PackageDescription -> LocalBuildInfo
                      -> Library            -> ComponentLocalBuildInfo -> IO ()
buildLib verbosity numJobs pkg_descr lbi lib clbi =
  case compilerFlavor (compiler lbi) of
    GHC   -> GHC.buildLib   verbosity numJobs pkg_descr lbi lib clbi
    GHCJS -> GHCJS.buildLib verbosity numJobs pkg_descr lbi lib clbi
    UHC   -> UHC.buildLib   verbosity         pkg_descr lbi lib clbi
    HaskellSuite {} -> HaskellSuite.buildLib verbosity pkg_descr lbi lib clbi
    _    -> die' verbosity "Building is not supported with this compiler."

-- | Build a foreign library
--
-- NOTE: We assume that we already checked that we can actually build the
-- foreign library in configure.
buildFLib :: Verbosity -> Flag (Maybe Int)
                       -> PackageDescription -> LocalBuildInfo
                       -> ForeignLib         -> ComponentLocalBuildInfo -> IO ()
buildFLib verbosity numJobs pkg_descr lbi flib clbi =
    case compilerFlavor (compiler lbi) of
      GHC -> GHC.buildFLib verbosity numJobs pkg_descr lbi flib clbi
      _   -> die' verbosity "Building is not supported with this compiler."

buildExe :: Verbosity -> Flag (Maybe Int)
                      -> PackageDescription -> LocalBuildInfo
                      -> Executable         -> ComponentLocalBuildInfo -> IO ()
buildExe verbosity numJobs pkg_descr lbi exe clbi =
  case compilerFlavor (compiler lbi) of
    GHC   -> GHC.buildExe   verbosity numJobs pkg_descr lbi exe clbi
    GHCJS -> GHCJS.buildExe verbosity numJobs pkg_descr lbi exe clbi
    UHC   -> UHC.buildExe   verbosity         pkg_descr lbi exe clbi
    _     -> die' verbosity "Building is not supported with this compiler."

replLib :: ReplOptions     -> Verbosity -> PackageDescription
        -> LocalBuildInfo  -> Library   -> ComponentLocalBuildInfo
        -> IO ()
replLib replFlags verbosity pkg_descr lbi lib clbi =
  case compilerFlavor (compiler lbi) of
    -- 'cabal repl' doesn't need to support 'ghc --make -j', so we just pass
    -- NoFlag as the numJobs parameter.
    GHC   -> GHC.replLib   replFlags verbosity NoFlag pkg_descr lbi lib clbi
    GHCJS -> GHCJS.replLib (replOptionsFlags replFlags) verbosity NoFlag pkg_descr lbi lib clbi
    _     -> die' verbosity "A REPL is not supported for this compiler."

replExe :: ReplOptions     -> Verbosity  -> PackageDescription
        -> LocalBuildInfo  -> Executable -> ComponentLocalBuildInfo
        -> IO ()
replExe replFlags verbosity pkg_descr lbi exe clbi =
  case compilerFlavor (compiler lbi) of
    GHC   -> GHC.replExe   replFlags verbosity NoFlag pkg_descr lbi exe clbi
    GHCJS -> GHCJS.replExe (replOptionsFlags replFlags) verbosity NoFlag pkg_descr lbi exe clbi
    _     -> die' verbosity "A REPL is not supported for this compiler."

replFLib :: ReplOptions     -> Verbosity  -> PackageDescription
         -> LocalBuildInfo  -> ForeignLib -> ComponentLocalBuildInfo
         -> IO ()
replFLib replFlags verbosity pkg_descr lbi exe clbi =
  case compilerFlavor (compiler lbi) of
    GHC -> GHC.replFLib replFlags verbosity NoFlag pkg_descr lbi exe clbi
    _   -> die' verbosity "A REPL is not supported for this compiler."

-- | Runs 'componentInitialBuildSteps' on every configured component.
initialBuildSteps :: FilePath -- ^"dist" prefix
                  -> PackageDescription  -- ^mostly information from the .cabal file
                  -> LocalBuildInfo -- ^Configuration information
                  -> Verbosity -- ^The verbosity to use
                  -> IO ()
initialBuildSteps distPref pkg_descr lbi verbosity =
    withAllComponentsInBuildOrder pkg_descr lbi $ \_comp clbi ->
        componentInitialBuildSteps distPref pkg_descr lbi clbi verbosity

-- | Creates the autogenerated files for a particular configured component.
componentInitialBuildSteps :: FilePath -- ^"dist" prefix
                  -> PackageDescription  -- ^mostly information from the .cabal file
                  -> LocalBuildInfo -- ^Configuration information
                  -> ComponentLocalBuildInfo
                  -> Verbosity -- ^The verbosity to use
                  -> IO ()
componentInitialBuildSteps _distPref pkg_descr lbi clbi verbosity = do
  createDirectoryIfMissingVerbose verbosity True (componentBuildDir lbi clbi)

  writeAutogenFiles verbosity pkg_descr lbi clbi

-- | Generate and write out the Paths_<pkg>.hs, PackageInfo_<pkg>.hs, and cabal_macros.h files
--
writeAutogenFiles :: Verbosity
                  -> PackageDescription
                  -> LocalBuildInfo
                  -> ComponentLocalBuildInfo
                  -> IO ()
writeAutogenFiles verbosity pkg lbi clbi = do
  createDirectoryIfMissingVerbose verbosity True (autogenComponentModulesDir lbi clbi)

  let pathsModulePath = autogenComponentModulesDir lbi clbi
                 </> ModuleName.toFilePath (autogenPathsModuleName pkg) <.> "hs"
      pathsModuleDir = takeDirectory pathsModulePath
  -- Ensure that the directory exists!
  createDirectoryIfMissingVerbose verbosity True pathsModuleDir
  rewriteFileEx verbosity pathsModulePath (generatePathsModule pkg lbi clbi)

  let packageInfoModulePath = autogenComponentModulesDir lbi clbi
                 </> ModuleName.toFilePath (autogenPackageInfoModuleName pkg) <.> "hs"
      packageInfoModuleDir = takeDirectory packageInfoModulePath
  -- Ensure that the directory exists!
  createDirectoryIfMissingVerbose verbosity True packageInfoModuleDir
  rewriteFileEx verbosity packageInfoModulePath (generatePackageInfoModule pkg lbi)

  --TODO: document what we're doing here, and move it to its own function
  case clbi of
    LibComponentLocalBuildInfo { componentInstantiatedWith = insts } ->
        -- Write out empty hsig files for all requirements, so that GHC
        -- has a source file to look at it when it needs to typecheck
        -- a signature.  It's harmless to write these out even when
        -- there is a real hsig file written by the user, since
        -- include path ordering ensures that the real hsig file
        -- will always be picked up before the autogenerated one.
        for_ (map fst insts) $ \mod_name -> do
            let sigPath = autogenComponentModulesDir lbi clbi
                      </> ModuleName.toFilePath mod_name <.> "hsig"
            createDirectoryIfMissingVerbose verbosity True (takeDirectory sigPath)
            rewriteFileEx verbosity sigPath $
                "{-# OPTIONS_GHC -w #-}\n" ++
                "{-# LANGUAGE NoImplicitPrelude #-}\n" ++
                "signature " ++ prettyShow mod_name ++ " where"
    _ -> return ()

  let cppHeaderPath = autogenComponentModulesDir lbi clbi </> cppHeaderName
  rewriteFileEx verbosity cppHeaderPath (generateCabalMacrosHeader pkg lbi clbi)
