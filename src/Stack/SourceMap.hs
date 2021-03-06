{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
module Stack.SourceMap
    ( mkProjectPackage
    , snapToDepPackage
    , additionalDepPackage
    , loadVersion
    , getPLIVersion
    , loadGlobalHints
    , DumpedGlobalPackage
    , actualFromGhc
    , actualFromHints
    , checkFlagsUsedThrowing
    , globalCondCheck
    , pruneGlobals
    , globalsFromHints
    , getCompilerInfo
    , immutableLocSha
    ) where

import Data.ByteString.Builder (byteString, lazyByteString)
import qualified Data.Conduit.List as CL
import qualified Distribution.PackageDescription as PD
import Distribution.System (Platform(..))
import Pantry
import qualified Pantry.SHA256 as SHA256
import qualified RIO
import qualified RIO.Map as Map
import qualified RIO.Set as Set
import RIO.Process
import Stack.PackageDump
import Stack.Prelude
import Stack.Types.Build
import Stack.Types.Compiler
import Stack.Types.Config
import Stack.Types.SourceMap

-- | Create a 'ProjectPackage' from a directory containing a package.
mkProjectPackage ::
       forall env. (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
    => PrintWarnings
    -> ResolvedPath Dir
    -> Bool
    -> RIO env ProjectPackage
mkProjectPackage printWarnings dir buildHaddocks = do
   (gpd, name, cabalfp) <- loadCabalFilePath (resolvedAbsolute dir)
   return ProjectPackage
     { ppCabalFP = cabalfp
     , ppResolvedDir = dir
     , ppCommon = CommonPackage
                  { cpGPD = gpd printWarnings
                  , cpName = name
                  , cpFlags = mempty
                  , cpGhcOptions = mempty
                  , cpHaddocks = buildHaddocks
                  }
     }

-- | Create a 'DepPackage' from a 'PackageLocation', from some additional
-- to a snapshot setting (extra-deps or command line)
additionalDepPackage
  :: forall env. (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
  => Bool
  -> PackageLocation
  -> RIO env DepPackage
additionalDepPackage buildHaddocks pl = do
  (name, gpdio) <-
    case pl of
      PLMutable dir -> do
        (gpdio, name, _cabalfp) <- loadCabalFilePath (resolvedAbsolute dir)
        pure (name, gpdio NoPrintWarnings)
      PLImmutable pli -> do
        PackageIdentifier name _ <- getPackageLocationIdent pli
        run <- askRunInIO
        pure (name, run $ loadCabalFileImmutable pli)
  return DepPackage
    { dpLocation = pl
    , dpHidden = False
    , dpFromSnapshot = NotFromSnapshot
    , dpCommon = CommonPackage
                  { cpGPD = gpdio
                  , cpName = name
                  , cpFlags = mempty
                  , cpGhcOptions = mempty
                  , cpHaddocks = buildHaddocks
                  }
    }

snapToDepPackage ::
       forall env. (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
    => Bool
    -> PackageName
    -> SnapshotPackage
    -> RIO env DepPackage
snapToDepPackage buildHaddocks name SnapshotPackage{..} = do
  run <- askRunInIO
  return DepPackage
    { dpLocation = PLImmutable spLocation
    , dpHidden = spHidden
    , dpFromSnapshot = FromSnapshot
    , dpCommon = CommonPackage
                  { cpGPD = run $ loadCabalFileImmutable spLocation
                  , cpName = name
                  , cpFlags = spFlags
                  , cpGhcOptions = spGhcOptions
                  , cpHaddocks = buildHaddocks
                  }
    }

loadVersion :: MonadIO m => CommonPackage -> m Version
loadVersion common = do
    gpd <- liftIO $ cpGPD common
    return (pkgVersion $ PD.package $ PD.packageDescription gpd)

getPLIVersion :: PackageLocationImmutable -> Version
getPLIVersion (PLIHackage (PackageIdentifier _ v) _ _) = v
getPLIVersion (PLIArchive _ pm) = pkgVersion $ pmIdent pm
getPLIVersion (PLIRepo _ pm) = pkgVersion $ pmIdent pm

globalsFromDump ::
       (HasLogFunc env, HasProcessContext env, HasCompiler env)
    => ActualCompiler
    -> RIO env (Map PackageName DumpedGlobalPackage)
globalsFromDump compiler = do
    let pkgConduit =
            conduitDumpPackage .|
            CL.foldMap (\dp -> Map.singleton (dpGhcPkgId dp) dp)
        toGlobals ds =
          Map.fromList $ map (pkgName . dpPackageIdent &&& id) $ Map.elems ds
    toGlobals <$> ghcPkgDump (whichCompiler compiler) [] pkgConduit

globalsFromHints ::
       HasConfig env
    => WantedCompiler
    -> RIO env (Map PackageName Version)
globalsFromHints compiler = do
    ghfp <- globalHintsFile
    mglobalHints <- loadGlobalHints ghfp compiler
    case mglobalHints of
        Just hints -> pure hints
        Nothing -> do
            logWarn $ "Unable to load global hints for " <> RIO.display compiler
            pure mempty

type DumpedGlobalPackage = DumpPackage

actualFromGhc ::
       (HasConfig env, HasCompiler env)
    => SMWanted
    -> ActualCompiler
    -> RIO env (SMActual DumpedGlobalPackage)
actualFromGhc smw ac = do
    globals <- globalsFromDump ac
    return
        SMActual
        { smaCompiler = ac
        , smaProject = smwProject smw
        , smaDeps = smwDeps smw
        , smaGlobal = globals
        }

actualFromHints ::
       (HasConfig env)
    => SMWanted
    -> ActualCompiler
    -> RIO env (SMActual GlobalPackageVersion)
actualFromHints smw ac = do
    globals <- globalsFromHints (actualToWanted ac)
    return
        SMActual
        { smaCompiler = ac
        , smaProject = smwProject smw
        , smaDeps = smwDeps smw
        , smaGlobal = Map.map GlobalPackageVersion globals
        }

-- | Simple cond check for boot packages - checks only OS and Arch
globalCondCheck :: (HasConfig env) => RIO env (PD.ConfVar -> Either PD.ConfVar Bool)
globalCondCheck = do
  Platform arch os <- view platformL
  let condCheck (PD.OS os') = pure $ os' == os
      condCheck (PD.Arch arch') = pure $ arch' == arch
      condCheck c = Left c
  return condCheck

checkFlagsUsedThrowing ::
       (MonadIO m, MonadThrow m)
    => Map PackageName (Map FlagName Bool)
    -> FlagSource
    -> Map PackageName ProjectPackage
    -> Map PackageName DepPackage
    -> m ()
checkFlagsUsedThrowing packageFlags source prjPackages deps = do
    unusedFlags <-
        forMaybeM (Map.toList packageFlags) $ \(pname, flags) ->
            getUnusedPackageFlags (pname, flags) source prjPackages deps
    unless (null unusedFlags) $
        throwM $ InvalidFlagSpecification $ Set.fromList unusedFlags

getUnusedPackageFlags ::
       MonadIO m
    => (PackageName, Map FlagName Bool)
    -> FlagSource
    -> Map PackageName ProjectPackage
    -> Map PackageName DepPackage
    -> m (Maybe UnusedFlags)
getUnusedPackageFlags (name, userFlags) source prj deps =
    let maybeCommon =
          fmap ppCommon (Map.lookup name prj) <|>
          fmap dpCommon (Map.lookup name deps)
    in case maybeCommon  of
        -- Package is not available as project or dependency
        Nothing ->
            pure $ Just $ UFNoPackage source name
        -- Package exists, let's check if the flags are defined
        Just common -> do
            gpd <- liftIO $ cpGPD common
            let pname = pkgName $ PD.package $ PD.packageDescription gpd
                pkgFlags = Set.fromList $ map PD.flagName $ PD.genPackageFlags gpd
                unused = Map.keysSet $ Map.withoutKeys userFlags pkgFlags
            if Set.null unused
                    -- All flags are defined, nothing to do
                    then pure Nothing
                    -- Error about the undefined flags
                    else pure $ Just $ UFFlagsNotDefined source pname pkgFlags unused

pruneGlobals ::
       Map PackageName DumpedGlobalPackage
    -> Set PackageName
    -> Map PackageName GlobalPackage
pruneGlobals globals deps =
  let (prunedGlobals, keptGlobals) =
        partitionReplacedDependencies globals (pkgName . dpPackageIdent)
            dpGhcPkgId dpDepends deps
  in Map.map (GlobalPackage . pkgVersion . dpPackageIdent) keptGlobals <>
     Map.map ReplacedGlobalPackage prunedGlobals

getCompilerInfo :: (HasConfig env) => WhichCompiler -> RIO env Builder
getCompilerInfo wc = do
    let compilerExe =
            case wc of
                Ghc -> "ghc"
                Ghcjs -> "ghcjs"
    lazyByteString . fst <$> proc compilerExe ["--info"] readProcess_

immutableLocSha :: PackageLocationImmutable -> Builder
immutableLocSha = byteString . treeKeyToBs . locationTreeKey
  where
    locationTreeKey (PLIHackage _ _ tk) = tk
    locationTreeKey (PLIArchive _ pm) = pmTreeKey pm
    locationTreeKey (PLIRepo _ pm) = pmTreeKey pm
    treeKeyToBs (TreeKey (BlobKey sha _)) = SHA256.toHexBytes sha
