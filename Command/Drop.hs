{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Drop where

import Common.Annex
import Command
import qualified Remote
import qualified Annex
import Annex.UUID
import Logs.Location
import Logs.Trust
import Annex.Content
import Config
import qualified Option
import Annex.Wanted

def :: [Command]
def = [withOptions [fromOption] $ command "drop" paramPaths seek
	SectionCommon "indicate content of files not currently wanted"]

fromOption :: Option
fromOption = Option.field ['f'] "from" paramRemote "drop content from a remote"

seek :: [CommandSeek]
seek = [withField fromOption Remote.byNameWithUUID $ \from ->
	withFilesInGit $ whenAnnexed $ start from]

start :: Maybe Remote -> FilePath -> (Key, Backend) -> CommandStart
start from file (key, _) = checkDropAuto from file key $ \numcopies ->
	stopUnless (checkAuto $ wantDrop False (Remote.uuid <$> from) (Just file)) $
		case from of
			Nothing -> startLocal file numcopies key Nothing
			Just remote -> do
				u <- getUUID
				if Remote.uuid remote == u
					then startLocal file numcopies key Nothing
					else startRemote file numcopies key remote

startLocal :: FilePath -> Maybe Int -> Key -> Maybe Remote -> CommandStart
startLocal file numcopies key knownpresentremote = stopUnless (inAnnex key) $ do
	showStart "drop" file
	next $ performLocal key numcopies knownpresentremote

startRemote :: FilePath -> Maybe Int -> Key -> Remote -> CommandStart
startRemote file numcopies key remote = do
	showStart ("drop " ++ Remote.name remote) file
	next $ performRemote key numcopies remote

performLocal :: Key -> Maybe Int -> Maybe Remote -> CommandPerform
performLocal key numcopies knownpresentremote = lockContent key $ do
	(remotes, trusteduuids) <- Remote.keyPossibilitiesTrusted key
	let trusteduuids' = case knownpresentremote of
		Nothing -> trusteduuids
		Just r -> nub (Remote.uuid r:trusteduuids)
	untrusteduuids <- trustGet UnTrusted
	let tocheck = Remote.remotesWithoutUUID remotes (trusteduuids'++untrusteduuids)
	stopUnless (canDropKey key numcopies trusteduuids' tocheck []) $ do
		removeAnnex key
		next $ cleanupLocal key

performRemote :: Key -> Maybe Int -> Remote -> CommandPerform
performRemote key numcopies remote = lockContent key $ do
	-- Filter the remote it's being dropped from out of the lists of
	-- places assumed to have the key, and places to check.
	-- When the local repo has the key, that's one additional copy.
	(remotes, trusteduuids) <- Remote.keyPossibilitiesTrusted key
	present <- inAnnex key
	u <- getUUID
	let have = filter (/= uuid) $
		if present then u:trusteduuids else trusteduuids
	untrusteduuids <- trustGet UnTrusted
	let tocheck = filter (/= remote) $
		Remote.remotesWithoutUUID remotes (have++untrusteduuids)
	stopUnless (canDropKey key numcopies have tocheck [uuid]) $ do
		ok <- Remote.removeKey remote key
		next $ cleanupRemote key remote ok
  where
	uuid = Remote.uuid remote

cleanupLocal :: Key -> CommandCleanup
cleanupLocal key = do
	logStatus key InfoMissing
	return True

cleanupRemote :: Key -> Remote -> Bool -> CommandCleanup
cleanupRemote key remote ok = do
	when ok $
		Remote.logStatus remote key InfoMissing
	return ok

{- Checks specified remotes to verify that enough copies of a key exist to
 - allow it to be safely removed (with no data loss). Can be provided with
 - some locations where the key is known/assumed to be present. -}
canDropKey :: Key -> Maybe Int -> [UUID] -> [Remote] -> [UUID] -> Annex Bool
canDropKey key numcopiesM have check skip = do
	force <- Annex.getState Annex.force
	if force || numcopiesM == Just 0
		then return True
		else do
			need <- getNumCopies numcopiesM
			findCopies key need skip have check

findCopies :: Key -> Int -> [UUID] -> [UUID] -> [Remote] -> Annex Bool
findCopies key need skip = helper [] []
  where
	helper bad missing have []
		| length have >= need = return True
		| otherwise = notEnoughCopies key need have (skip++missing) bad
	helper bad missing have (r:rs)
		| length have >= need = return True
		| otherwise = do
			let u = Remote.uuid r
			let duplicate = u `elem` have
			haskey <- Remote.hasKey r key
			case (duplicate, haskey) of
				(False, Right True)  -> helper bad missing (u:have) rs
				(False, Left _)      -> helper (r:bad) missing have rs
				(False, Right False) -> helper bad (u:missing) have rs
				_                    -> helper bad missing have rs

notEnoughCopies :: Key -> Int -> [UUID] -> [UUID] -> [Remote] -> Annex Bool
notEnoughCopies key need have skip bad = do
	unsafe
	showLongNote $
		"Could only verify the existence of " ++
		show (length have) ++ " out of " ++ show need ++ 
		" necessary copies"
	Remote.showTriedRemotes bad
	Remote.showLocations key (have++skip)
		"Rather than dropping this file, try using: git annex move"
	hint
	return False
  where
	unsafe = showNote "unsafe"
	hint = showLongNote "(Use --force to override this check, or adjust annex.numcopies.)"

{- In auto mode, only runs the action if there are enough
 - copies on other semitrusted repositories.
 -
 - Passes any numcopies attribute of the file on to the action as an
 - optimisation. -}
checkDropAuto :: Maybe Remote -> FilePath -> Key -> (Maybe Int -> CommandStart) -> CommandStart
checkDropAuto mremote file key a = do
	numcopiesattr <- numCopies file
	Annex.getState Annex.auto >>= auto numcopiesattr
  where
	auto numcopiesattr False = a numcopiesattr
	auto numcopiesattr True = do
		needed <- getNumCopies numcopiesattr
		locs <- Remote.keyLocations key
		uuid <- getUUID
		let remoteuuid = fromMaybe uuid $ Remote.uuid <$> mremote
		locs' <- trustExclude UnTrusted $ filter (/= remoteuuid) locs
		if length locs' >= needed
			then a numcopiesattr
			else stop
