{- git-annex assistant daemon
 -
 - Copyright 2012-2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Assistant where

import qualified Annex
import Assistant.Common
import Assistant.DaemonStatus
import Assistant.NamedThread
import Assistant.Types.ThreadedMonad
import Assistant.Threads.DaemonStatus
import Assistant.Threads.Watcher
import Assistant.Threads.Committer
import Assistant.Threads.Pusher
import Assistant.Threads.Merger
import Assistant.Threads.TransferWatcher
import Assistant.Threads.Transferrer
import Assistant.Threads.SanityChecker
import Assistant.Threads.Cronner
import Assistant.Threads.ProblemFixer
#ifdef WITH_CLIBS
import Assistant.Threads.MountWatcher
#endif
import Assistant.Threads.NetWatcher
import Assistant.Threads.Upgrader
import Assistant.Threads.UpgradeWatcher
import Assistant.Threads.TransferScanner
import Assistant.Threads.TransferPoller
import Assistant.Threads.ConfigMonitor
import Assistant.Threads.Glacier
#ifdef WITH_WEBAPP
import Assistant.WebApp
import Assistant.Threads.WebApp
#ifdef WITH_PAIRING
import Assistant.Threads.PairListener
#endif
#ifdef WITH_XMPP
import Assistant.Threads.XMPPClient
import Assistant.Threads.XMPPPusher
#endif
#else
#warning Building without the webapp. You probably need to install Yesod..
import Assistant.Types.UrlRenderer
#endif
import qualified Utility.Daemon
import Utility.ThreadScheduler
import Utility.HumanTime
import qualified Build.SysConfig as SysConfig
#ifndef mingw32_HOST_OS
import Utility.LogFile
import Annex.Perms
#endif

import System.Log.Logger
import Network.Socket (HostName)

stopDaemon :: Annex ()
stopDaemon = liftIO . Utility.Daemon.stopDaemon =<< fromRepo gitAnnexPidFile

{- Starts the daemon. If the daemon is run in the foreground, once it's
 - running, can start the browser.
 -
 - startbrowser is passed the url and html shim file, as well as the original
 - stdout and stderr descriptors. -}
startDaemon :: Bool -> Bool -> Maybe Duration -> Maybe String -> Maybe HostName ->  Maybe (Maybe Handle -> Maybe Handle -> String -> FilePath -> IO ()) -> Annex ()
startDaemon assistant foreground startdelay cannotrun listenhost startbrowser = do
	Annex.changeState $ \s -> s { Annex.daemon = True }
	pidfile <- fromRepo gitAnnexPidFile
#ifndef mingw32_HOST_OS
	logfile <- fromRepo gitAnnexLogFile
	createAnnexDirectory (parentDir logfile)
	logfd <- liftIO $ openLog logfile
	if foreground
		then do
			origout <- liftIO $ catchMaybeIO $ 
				fdToHandle =<< dup stdOutput
			origerr <- liftIO $ catchMaybeIO $ 
				fdToHandle =<< dup stdError
			let undaemonize a = do
				debugM desc $ "logging to " ++ logfile
				Utility.Daemon.lockPidFile pidfile
				Utility.LogFile.redirLog logfd
				a
			start undaemonize $ 
				case startbrowser of
					Nothing -> Nothing
					Just a -> Just $ a origout origerr
		else
			start (Utility.Daemon.daemonize logfd (Just pidfile) False) Nothing
#else
	-- Windows is always foreground, and has no log file.
	when (foreground || not foreground) $ do
		liftIO $ Utility.Daemon.lockPidFile pidfile
		start id $ do
			case startbrowser of
				Nothing -> Nothing
				Just a -> Just $ a Nothing Nothing
#endif
  where
  	desc
		| assistant = "assistant"
		| otherwise = "watch"
	start daemonize webappwaiter = withThreadState $ \st -> do
		checkCanWatch
		dstatus <- startDaemonStatus
		logfile <- fromRepo gitAnnexLogFile
		liftIO $ debugM desc $ "logging to " ++ logfile
		liftIO $ daemonize $
			flip runAssistant (go webappwaiter) 
				=<< newAssistantData st dstatus

#ifdef WITH_WEBAPP
	go webappwaiter = do
		d <- getAssistant id
#else
	go _webappwaiter = do
#endif
		notice ["starting", desc, "version", SysConfig.packageversion]
		urlrenderer <- liftIO newUrlRenderer
#ifdef WITH_WEBAPP
		let webappthread = [ assist $ webAppThread d urlrenderer False cannotrun listenhost Nothing webappwaiter ]
#else
		let webappthread = []
#endif
		let threads = if isJust cannotrun
			then webappthread
			else webappthread ++
				[ watch $ commitThread
#ifdef WITH_WEBAPP
#ifdef WITH_PAIRING
				, assist $ pairListenerThread urlrenderer
#endif
#ifdef WITH_XMPP
				, assist $ xmppClientThread urlrenderer
				, assist $ xmppSendPackThread urlrenderer
				, assist $ xmppReceivePackThread urlrenderer
#endif
#endif
				, assist $ pushThread
				, assist $ pushRetryThread
				, assist $ mergeThread
				, assist $ transferWatcherThread
				, assist $ transferPollerThread
				, assist $ transfererThread
				, assist $ daemonStatusThread
				, assist $ sanityCheckerDailyThread urlrenderer
				, assist $ sanityCheckerHourlyThread
				, assist $ problemFixerThread urlrenderer
#ifdef WITH_CLIBS
				, assist $ mountWatcherThread urlrenderer
#endif
				, assist $ netWatcherThread
				, assist $ upgraderThread urlrenderer
				, assist $ upgradeWatcherThread urlrenderer
				, assist $ netWatcherFallbackThread
				, assist $ transferScannerThread urlrenderer
				, assist $ cronnerThread urlrenderer
				, assist $ configMonitorThread
				, assist $ glacierThread
				, watch $ watchThread
				-- must come last so that all threads that wait
				-- on it have already started waiting
				, watch $ sanityCheckerStartupThread startdelay
				]
	
		mapM_ (startthread urlrenderer) threads
		liftIO waitForTermination

	watch a = (True, a)
	assist a = (False, a)
	startthread urlrenderer (watcher, t)
		| watcher || assistant = startNamedThread urlrenderer t
		| otherwise = noop
