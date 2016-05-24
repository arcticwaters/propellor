module Propellor.DotDir
	( distrepo
	, dotPropellor
	, interactiveInit
	, checkRepoUpToDate
	) where

import Propellor.Message
import Propellor.Bootstrap
import Propellor.Git
import Propellor.Gpg
import Propellor.Types.Result
import Utility.UserInfo
import Utility.Monad
import Utility.Process
import Utility.SafeCommand
import Utility.Exception
import Utility.Directory
import Utility.Path
-- This module is autogenerated by the build system.
import qualified Paths_propellor as Package

import Data.Char
import Data.List
import Data.Version
import Control.Monad
import Control.Monad.IfElse
import System.FilePath
import System.Posix.Directory
import System.IO
import System.Console.Concurrent
import Control.Applicative
import Prelude

distdir :: FilePath
distdir = "/usr/src/propellor"

-- A distribution may include a bundle of propellor's git repository here.
-- If not, it will be pulled from the network when needed.
distrepo :: FilePath
distrepo = distdir </> "propellor.git"

-- File containing the head rev of the distrepo.
disthead :: FilePath
disthead = distdir </> "head"

upstreambranch :: String
upstreambranch = "upstream/master"

-- Using the github mirror of the main propellor repo because
-- it is accessible over https for better security.
netrepo :: String
netrepo = "https://github.com/joeyh/propellor.git"

dotPropellor :: IO FilePath
dotPropellor = do
	home <- myHomeDir
	return (home </> ".propellor")

-- Detect if propellor was built using stack. This is somewhat of a hack.
buildSystem :: IO String
buildSystem = do
	d <- Package.getLibDir
	return $ if "stack-work" `isInfixOf` d then "stack" else "cabal"

interactiveInit :: IO ()
interactiveInit = ifM (doesDirectoryExist =<< dotPropellor)
	( error "~/.propellor/ already exists, not doing anything"
	, do
		welcomeBanner
		setup
	)

-- | Determine whether we need to create a cabal sandbox in ~/.propellor/,
-- which we do if the user has configured cabal to require a sandbox, and the
-- build system is cabal.
cabalSandboxRequired :: IO Bool
cabalSandboxRequired = ifM cabal
	( do
		home <- myHomeDir
		ls <- lines <$> catchDefaultIO []
			(readFile (home </> ".cabal" </> "config"))
		-- For simplicity, we assume a sane ~/.cabal/config here:
		return $ any ("True" `isInfixOf`) $
			filter ("require-sandbox:" `isPrefixOf`) ls
	, return False
	)
  where
	cabal = buildSystem >>= \bSystem -> return (bSystem == "cabal")

say :: String -> IO ()
say = outputConcurrent

sayLn :: String -> IO ()
sayLn s = say (s ++ "\n")

welcomeBanner :: IO ()
welcomeBanner = say $ unlines $ map prettify
	[ ""
	, ""
	, "                                 _         ______`|                     ,-.__"
	, " .---------------------------  /   ~___-=O`/|O`/__|                    (____.'"
	, "  - Welcome to              -- ~          / | /    )        _.-'-._"
	, "  -            Propellor!   --  `/-==__ _/__|/__=-|        (       ~_"
	, " `---------------------------   *             ~ | |         '--------'"
	, "                                            (o)  `"
	, ""
	, ""
	]
  where
	prettify = map (replace '~' '\\')
	replace x y c
		| c == x = y
		| otherwise = c

prompt :: String -> [(String, IO ())] -> IO ()
prompt p cs = do
	say (p ++ " [" ++ intercalate "|" (map fst cs) ++ "] ")
	flushConcurrentOutput
	hFlush stdout
	r <- map toLower <$> getLine
	if null r
		then snd (head cs) -- default to first choice on return
		else case filter (\(s, _) -> map toLower s == r) cs of
			[(_, a)] -> a
			_ -> do
				sayLn "Not a valid choice, try again.. (Or ctrl-c to quit)"
				prompt p cs

section :: IO ()
section = do
	sayLn ""
	sayLn "------------------------------------------------------------------------------"
	sayLn ""

setup :: IO ()
setup = do
	sayLn "Propellor's configuration file is ~/.propellor/config.hs"
	sayLn ""
	sayLn "Let's get you started with a simple config that you can adapt"
	sayLn "to your needs. You can start with:"
	sayLn "   A: A clone of propellor's git repository    (most flexible)"
	sayLn "   B: The bare minimum files to use propellor  (most simple)"
	prompt "Which would you prefer?"
		[ ("A", void $ actionMessage "Cloning propellor's git repository" fullClone)
		, ("B", void $ actionMessage "Creating minimal config" minimalConfig)
		]
	changeWorkingDirectory =<< dotPropellor

	section
	sayLn "Let's try building the propellor configuration, to make sure it will work..."
	sayLn ""
	b <- buildSystem
	void $ boolSystem "git"
		[ Param "config"
		, Param "propellor.buildsystem"
		, Param b
		]
	ifM cabalSandboxRequired
		( void $ boolSystem "cabal"
			[ Param "sandbox"
			, Param "init"
			]
		, return ()
		)
	buildPropellor Nothing
	sayLn ""
	sayLn "Great! Propellor is bootstrapped."

	section
	sayLn "Propellor can use gpg to encrypt private data about the systems it manages,"
	sayLn "and to sign git commits."
	gpg <- getGpgBin
	ifM (inPath gpg)
		( setupGpgKey
		, do
			sayLn "You don't seem to have gpg installed, so skipping setting it up."
			explainManualSetupGpgKey
		)

	section
	sayLn "Everything is set up ..."
	sayLn "Your next step is to edit ~/.propellor/config.hs"
	sayLn "and run propellor again to try it out."
	sayLn ""
	sayLn "For docs, see https://propellor.branchable.com/"
	sayLn "Enjoy propellor!"

explainManualSetupGpgKey :: IO ()
explainManualSetupGpgKey = do
	sayLn "Propellor can still be used without gpg, but it won't be able to"
	sayLn "manage private data. You can set this up later:"
	sayLn " 1. gpg --gen-key"
	sayLn " 2. propellor --add-key (pass it the key ID generated in step 1)"

setupGpgKey :: IO ()
setupGpgKey = do
	ks <- listSecretKeys
	sayLn ""
	case ks of
		[] -> makeGpgKey
		[(k, d)] -> do
			sayLn $ "You have one gpg key: " ++ desckey k d
			prompt "Should propellor use that key?"
				[ ("Y", propellorAddKey k)
				, ("N", sayLn $ "Skipping gpg setup. If you change your mind, run: propellor --add-key " ++ k)
				]
		_ -> do
			let nks = zip ks (map show ([1..] :: [Integer]))
			sayLn "I see you have several gpg keys:"
			forM_ nks $ \((k, d), n) ->
				sayLn $ "   " ++ n ++ "   " ++ desckey k d
			prompt "Which of your gpg keys should propellor use?"
				(map (\((k, _), n) -> (n, propellorAddKey k)) nks)
  where
	desckey k d = d ++ "  (keyid " ++ k ++ ")"

makeGpgKey :: IO ()
makeGpgKey = do
	sayLn "You seem to not have any gpg secret keys."
	prompt "Would you like to create one now?"
		[("Y", rungpg), ("N", nope)]
  where
	nope = do
		sayLn "No problem."
		explainManualSetupGpgKey
	rungpg = do
		sayLn "Running gpg --gen-key ..."
		gpg <- getGpgBin
		void $ boolSystem gpg [Param "--gen-key"]
		ks <- listSecretKeys
		case ks of
			[] -> do
				sayLn "Hmm, gpg seemed to not set up a secret key."
				prompt "Want to try running gpg again?"
					[("Y", rungpg), ("N", nope)]
			((k, _):_) -> propellorAddKey k

propellorAddKey :: String -> IO ()
propellorAddKey keyid = do
	sayLn ""
	sayLn $ "Telling propellor to use your gpg key by running: propellor --add-key " ++ keyid
	d <- dotPropellor
	unlessM (boolSystem (d </> "propellor") [Param "--add-key", Param keyid]) $ do
		sayLn "Oops, that didn't work! You can retry the same command later."
		sayLn "Continuing onward ..."

minimalConfig :: IO Result
minimalConfig = do
	d <- dotPropellor
	createDirectoryIfMissing True d
	changeWorkingDirectory d
	void $ boolSystem "git" [Param "init"]
	addfile "config.cabal" cabalcontent
	addfile "config.hs" configcontent
	addfile "stack.yaml" stackcontent
	return MadeChange
  where
	addfile f content = do
		writeFile f (unlines content)
		void $ boolSystem "git" [Param "add" , File f]
	cabalcontent =
		[ "-- This is a cabal file to use to build your propellor configuration."
		, ""
		, "Name: config"
		, "Cabal-Version: >= 1.6"
		, "Build-Type: Simple"
		, "Version: 0"
		, ""
		, "Executable propellor-config"
		, "  Main-Is: config.hs"
		, "  GHC-Options: -threaded -Wall -fno-warn-tabs -O0"
		, "  Extensions: TypeOperators"
		, "  Build-Depends: propellor >= 3.0, base >= 3"
		]
	configcontent =
		[ "-- This is the main configuration file for Propellor, and is used to build"
		, "-- the propellor program.    https://propellor.branchable.com/"
		, ""
		, "import Propellor"
		, "import qualified Propellor.Property.File as File"
		, "import qualified Propellor.Property.Apt as Apt"
		, "import qualified Propellor.Property.Cron as Cron"
		, "import qualified Propellor.Property.User as User"
		, ""
		, "main :: IO ()"
		, "main = defaultMain hosts"
		, ""
		, "-- The hosts propellor knows about."
		, "hosts :: [Host]"
		, "hosts ="
		, "        [ mybox"
		, "        ]"
		, ""
		, "-- An example host."
		, "mybox :: Host"
		, "mybox = host \"mybox.example.com\" $ props"
		, "        & osDebian Unstable X86_64"
		, "        & Apt.stdSourcesList"
		, "        & Apt.unattendedUpgrades"
		, "        & Apt.installed [\"etckeeper\"]"
		, "        & Apt.installed [\"ssh\"]"
		, "        & User.hasSomePassword (User \"root\")"
		, "        & File.dirExists \"/var/www\""
		, "        & Cron.runPropellor (Cron.Times \"30 * * * *\")"
		, ""
		]
	stackcontent =
		-- This should be the same resolver version in propellor's
		-- own stack.yaml
		[ "resolver: lts-5.10"
		, "packages:"
		, "- '.'"
		, "extra-deps:"
		, "- propellor-" ++ showVersion Package.version
		]

fullClone :: IO Result
fullClone = do
	d <- dotPropellor
	let enterdotpropellor = changeWorkingDirectory d >> return True
	ok <- ifM (doesFileExist distrepo <||> doesDirectoryExist distrepo)
		( allM id
			[ boolSystem "git" [Param "clone", File distrepo, File d]
			, fetchUpstreamBranch distrepo
			, enterdotpropellor
			, boolSystem "git" [Param "remote", Param "rm", Param "origin"]
			]
		, allM id
			[ boolSystem "git" [Param "clone", Param netrepo, File d]
			, enterdotpropellor
			-- Rename origin to upstream and avoid
			-- git push to that read-only repo.
			, boolSystem "git" [Param "remote", Param "rename", Param "origin", Param "upstream"]
			, boolSystem "git" [Param "config", Param "--unset", Param "branch.master.remote", Param "upstream"]
			]
		)
	return (toResult ok)

fetchUpstreamBranch :: FilePath -> IO Bool
fetchUpstreamBranch repo = do
	changeWorkingDirectory =<< dotPropellor
	boolSystem "git"
		[ Param "fetch"
		, File repo
		, Param ("+refs/heads/master:refs/remotes/" ++ upstreambranch)
		, Param "--quiet"
		]

checkRepoUpToDate :: IO ()
checkRepoUpToDate = whenM (gitbundleavail <&&> dotpropellorpopulated) $ do
	headrev <- takeWhile (/= '\n') <$> readFile disthead
	changeWorkingDirectory =<< dotPropellor
	headknown <- catchMaybeIO $
		withQuietOutput createProcessSuccess $
			proc "git" ["log", headrev]
	if (headknown == Nothing)
		then setupUpstreamMaster headrev
		else do
			theirhead <- getCurrentGitSha1 =<< getCurrentBranchRef
			when (theirhead /= headrev) $ do
				merged <- not . null <$>
					readProcess "git" ["log", headrev ++ "..HEAD", "--ancestry-path"]
				unless merged $
					warnoutofdate True
  where
	gitbundleavail = doesFileExist disthead
	dotpropellorpopulated = do
		d <- dotPropellor
		doesFileExist (d </> "propellor.cabal")

-- Makes upstream/master in dotPropellor be a usefully mergeable branch.
--
-- We cannot just use origin/master, because in the case of a distrepo,
-- it only contains 1 commit. So, trying to merge with it will result
-- in lots of merge conflicts, since git cannot find a common parent
-- commit.
--
-- Instead, the upstream/master branch is created by taking the
-- upstream/master branch (which must be an old version of propellor,
-- as distributed), and diffing from it to the current origin/master,
-- and committing the result. This is done in a temporary clone of the
-- repository, giving it a new master branch. That new branch is fetched
-- into the user's repository, as if fetching from a upstream remote,
-- yielding a new upstream/master branch.
setupUpstreamMaster :: String -> IO ()
setupUpstreamMaster newref = do
	changeWorkingDirectory =<< dotPropellor
	go =<< catchMaybeIO getoldrev
  where
	go Nothing = warnoutofdate False
	go (Just oldref) = do
		let tmprepo = ".git/propellordisttmp"
		let cleantmprepo = void $ catchMaybeIO $ removeDirectoryRecursive tmprepo
		cleantmprepo
		git ["clone", "--quiet", ".", tmprepo]

		changeWorkingDirectory tmprepo
		git ["fetch", distrepo, "--quiet"]
		git ["reset", "--hard", oldref, "--quiet"]
		git ["merge", newref, "-s", "recursive", "-Xtheirs", "--quiet", "-m", "merging upstream version"]

		void $ fetchUpstreamBranch tmprepo
		cleantmprepo
		warnoutofdate True

	getoldrev = takeWhile (/= '\n')
		<$> readProcess "git" ["show-ref", upstreambranch, "--hash"]

	git = run "git"
	run cmd ps = unlessM (boolSystem cmd (map Param ps)) $
		error $ "Failed to run " ++ cmd ++ " " ++ show ps

warnoutofdate :: Bool -> IO ()
warnoutofdate havebranch = do
	warningMessage ("** Your ~/.propellor/ is out of date..")
	let also s = hPutStrLn stderr ("   " ++ s)
	also ("A newer upstream version is available in " ++ distrepo)
	if havebranch
		then also ("To merge it, run: git merge " ++ upstreambranch)
		else also ("To merge it, find the most recent commit in your repository's history that corresponds to an upstream release of propellor, and set refs/remotes/" ++ upstreambranch ++ " to it. Then run propellor again.")
	also ""
