module CabalBounds.Update
   ( update
   ) where

import qualified Distribution.PackageDescription as D
import qualified Distribution.Package as P
import qualified Distribution.Version as V
import qualified Distribution.Simple.LocalBuildInfo as BI
import qualified Distribution.Simple.PackageIndex as PX
import qualified Distribution.InstalledPackageInfo as PI
import Control.Lens
import CabalBounds.Bound (UpdateBound(..))
import CabalBounds.Dependencies (Dependencies, filterDependency)
import CabalBounds.VersionComp (VersionComp(..))
import qualified CabalLenses as CL
import Data.List (foldl')
import qualified Data.HashMap.Strict as HM
import Data.Maybe (fromMaybe)

type PkgName           = String
type InstalledPackages = HM.HashMap PkgName V.Version


update :: UpdateBound -> [CL.Section] -> Dependencies -> D.GenericPackageDescription -> BI.LocalBuildInfo -> D.GenericPackageDescription
update bound sections deps pkgDescrp buildInfo =
   foldl' updateSection pkgDescrp sections
   where
      updateSection pkgDescrp section =
         pkgDescrp & CL.dependencyIf condVars section . filterDep %~ updateDep

      filterDep = filterDependency deps
      updateDep = updateDependency bound (installedPackages buildInfo)
      condVars  = CL.fromDefaults pkgDescrp


updateDependency :: UpdateBound -> InstalledPackages -> P.Dependency -> P.Dependency
updateDependency (UpdateLower comp) instPkgs dep =
   fromMaybe dep $ do
      version <- HM.lookup pkgName_ instPkgs
      let newLowerVersion = comp `compOf` version
          newLowerBound   = V.LowerBound newLowerVersion V.InclusiveBound
          vrange          = fromMaybe (V.orLaterVersion newLowerVersion) $ modifyVersionIntervals (updateLower newLowerBound) versionRange_
      return $ mkDependency pkgName_ vrange
   where
      updateLower newLowerBound []        = [(newLowerBound, V.NoUpperBound)]
      updateLower newLowerBound intervals = intervals & _head . lowerBound .~ newLowerBound

      pkgName_ = pkgName dep
      versionRange_ = versionRange dep

updateDependency (UpdateUpper comp) instPkgs dep =
   fromMaybe dep $ do
        upperVersion <- HM.lookup pkgName_ instPkgs
        let newUpperVersion = comp `compOf` upperVersion
            newUpperBound   = V.UpperBound (nextVersion newUpperVersion) V.ExclusiveBound
        vrange <- modifyVersionIntervals (updateUpper newUpperBound) versionRange_
        return $ mkDependency pkgName_ vrange
   where
      versionRange_ = versionRange dep
      pkgName_      = pkgName dep

      updateUpper newUpperBound []        = [(noLowerBound, newUpperBound)]
      updateUpper newUpperBound intervals = intervals & _last . upperBound .~ newUpperBound

      noLowerBound = V.LowerBound (V.Version [0] []) V.InclusiveBound

updateDependency (UpdateBoth lowerComp upperComp) instPkgs dep =
    updateDependency (UpdateLower lowerComp) instPkgs $
    updateDependency (UpdateUpper upperComp) instPkgs dep


modifyVersionIntervals :: ([V.VersionInterval] -> [V.VersionInterval]) -> V.VersionRange -> Maybe V.VersionRange
modifyVersionIntervals f = fmap V.fromVersionIntervals . V.mkVersionIntervals . f . V.asVersionIntervals


compOf :: VersionComp -> V.Version -> V.Version
Major1 `compOf` version =
   version & CL.versionBranchL %~ take 1
           & CL.versionTagsL   .~ []

Major2 `compOf` version =
   version & CL.versionBranchL %~ take 2
           & CL.versionTagsL   .~ []

Minor `compOf` version =
   version & CL.versionTagsL .~ []


nextVersion :: V.Version -> V.Version
nextVersion version =
   version & CL.versionBranchL %~ increaseLastComp
   where
      increaseLastComp = reverse . (& ix 0 %~ (+ 1)) . reverse


installedPackages :: BI.LocalBuildInfo -> InstalledPackages
installedPackages = HM.fromList
                    . map (\(P.PackageName n, v) -> (n, newestVersion v))
                    . filter ((not . null) . snd)
                    . PX.allPackagesByName . BI.installedPkgs
   where
      newestVersion :: [PI.InstalledPackageInfo] -> V.Version
      newestVersion = maximum . map (P.pkgVersion . PI.sourcePackageId)


pkgName :: P.Dependency -> PkgName
pkgName (P.Dependency (P.PackageName name) _) = name


versionRange :: P.Dependency -> V.VersionRange
versionRange (P.Dependency _ vrange) = vrange


mkDependency :: PkgName -> V.VersionRange -> P.Dependency
mkDependency name = P.Dependency (P.PackageName name)


lowerBound :: Lens' V.VersionInterval V.LowerBound
lowerBound = _1


upperBound :: Lens' V.VersionInterval V.UpperBound
upperBound = _2
