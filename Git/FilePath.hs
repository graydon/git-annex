{- git FilePath library
 -
 - Different git commands use different types of FilePaths to refer to
 - files in the repository. Some commands use paths relative to the
 - top of the repository even when run in a subdirectory. Adding some
 - types helps keep that straight.
 -
 - Copyright 2012-2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Git.FilePath (
	TopFilePath,
	fromTopFilePath,
	getTopFilePath,
	toTopFilePath,
	asTopFilePath,
	InternalGitPath,
	toInternalGitPath,
	fromInternalGitPath
) where

import Common
import Git

{- A FilePath, relative to the top of the git repository. -}
newtype TopFilePath = TopFilePath { getTopFilePath :: FilePath }
	deriving (Show)

{- Returns an absolute FilePath. -}
fromTopFilePath :: TopFilePath -> Git.Repo -> FilePath
fromTopFilePath p repo = absPathFrom (repoPath repo) (getTopFilePath p)

{- The input FilePath can be absolute, or relative to the CWD. -}
toTopFilePath :: FilePath -> Git.Repo -> IO TopFilePath
toTopFilePath file repo = TopFilePath <$>
	relPathDirToFile (repoPath repo) <$> absPath file

{- The input FilePath must already be relative to the top of the git
 - repository -}
asTopFilePath :: FilePath -> TopFilePath
asTopFilePath file = TopFilePath file

{- Git may use a different representation of a path when storing
 - it internally. 
 -
 - On Windows, git uses '/' to separate paths stored in the repository,
 - despite Windows using '\'. Also, git on windows dislikes paths starting
 - with "./" or ".\".
 -
 -}
type InternalGitPath = String

toInternalGitPath :: FilePath -> InternalGitPath
#ifndef mingw32_HOST_OS
toInternalGitPath = id
#else
toInternalGitPath p =
	let p' = replace "\\" "/" p
	in if "./" `isPrefixOf` p'
		then dropWhile (== '/') (drop 1 p')
		else p'
#endif

fromInternalGitPath :: InternalGitPath -> FilePath
#ifndef mingw32_HOST_OS
fromInternalGitPath = id
#else
fromInternalGitPath = replace "/" "\\"
#endif
