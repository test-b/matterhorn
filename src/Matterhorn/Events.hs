module Matterhorn.Events
  ( onEvent
  , globalKeybindings
  , globalKeyHandlers
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import           Brick
import qualified Data.Text as T
import qualified Graphics.Vty as Vty
import           Lens.Micro.Platform ( (.=), _2, singular, _Just )

import qualified Network.Mattermost.Endpoints as MM
import           Network.Mattermost.Exceptions ( mattermostErrorMessage )

import           Matterhorn.Connection
import           Matterhorn.Constants ( userSigil, normalChannelSigil )
import           Matterhorn.HelpTopics
import           Matterhorn.State.ChannelList
import           Matterhorn.State.Channels
import           Matterhorn.State.Common
import           Matterhorn.State.Help
import           Matterhorn.State.Messages
import           Matterhorn.Types

import           Matterhorn.Events.ChannelSelect
import           Matterhorn.Events.ChannelTopicWindow
import           Matterhorn.Events.DeleteChannelConfirm
import           Matterhorn.Events.Keybindings
import           Matterhorn.Events.LeaveChannelConfirm
import           Matterhorn.Events.Main
import           Matterhorn.Events.MessageSelect
import           Matterhorn.Events.ThemeListOverlay
import           Matterhorn.Events.PostListOverlay
import           Matterhorn.Events.ShowHelp
import           Matterhorn.Events.UrlSelect
import           Matterhorn.Events.UserListOverlay
import           Matterhorn.Events.ChannelListOverlay
import           Matterhorn.Events.ReactionEmojiListOverlay
import           Matterhorn.Events.TabbedWindow
import           Matterhorn.Events.ManageAttachments
import           Matterhorn.Events.EditNotifyPrefs
import           Matterhorn.Events.Websocket


onEvent :: ChatState -> BrickEvent Name MHEvent -> EventM Name (Next ChatState)
onEvent st ev = runMHEvent st $ do
    onBrickEvent ev
    doPendingUserFetches
    doPendingUserStatusFetches

onBrickEvent :: BrickEvent Name MHEvent -> MH ()
onBrickEvent (AppEvent e) =
    onAppEvent e
onBrickEvent (VtyEvent (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl])) = do
    vty <- mh getVtyHandle
    liftIO $ Vty.refresh vty
onBrickEvent (VtyEvent e) =
    onVtyEvent e
onBrickEvent _ =
    return ()

onAppEvent :: MHEvent -> MH ()
onAppEvent RefreshWebsocketEvent =
    connectWebsockets
onAppEvent WebsocketDisconnect = do
    csConnectionStatus .= Disconnected
    disconnectChannels
onAppEvent WebsocketConnect = do
    csConnectionStatus .= Connected
    refreshChannelsAndUsers
    refreshClientConfig
    fetchVisibleIfNeeded
onAppEvent (RateLimitExceeded winSz) =
    mhError $ GenericError $ T.pack $
        let s = if winSz == 1 then "" else "s"
        in "The server's API request rate limit was exceeded; Matterhorn will " <>
           "retry the failed request in " <> show winSz <> " second" <> s <>
           ". Please contact your Mattermost administrator " <>
           "about API rate limiting issues."
onAppEvent RateLimitSettingsMissing =
    mhError $ GenericError $
        "A request was rate-limited but could not be retried due to rate " <>
        "limit settings missing"
onAppEvent RequestDropped =
    mhError $ GenericError $
        "An API request was retried and dropped due to a rate limit. Matterhorn " <>
        "may now be inconsistent with the server. Please contact your " <>
        "Mattermost administrator about API rate limiting issues."
onAppEvent BGIdle =
    csWorkerIsBusy .= Nothing
onAppEvent (BGBusy n) =
    csWorkerIsBusy .= Just n
onAppEvent (WSEvent we) =
    handleWebsocketEvent we
onAppEvent (WSActionResponse r) =
    handleWebsocketActionResponse r
onAppEvent (RespEvent f) = f
onAppEvent (WebsocketParseError e) = do
    let msg = "A websocket message could not be parsed:\n  " <>
              T.pack e <>
              "\nPlease report this error at https://github.com/matterhorn-chat/matterhorn/issues"
    mhError $ GenericError msg
onAppEvent (IEvent e) = do
    handleIEvent e

handleIEvent :: InternalEvent -> MH ()
handleIEvent (DisplayError e) =
    postErrorMessage' $ formatError e
handleIEvent (LoggingStarted path) =
    postInfoMessage $ "Logging to " <> T.pack path
handleIEvent (LogDestination dest) =
    case dest of
        Nothing ->
            postInfoMessage "Logging is currently disabled. Enable it with /log-start."
        Just path ->
            postInfoMessage $ T.pack $ "Logging to " <> path
handleIEvent (LogSnapshotSucceeded path) =
    postInfoMessage $ "Log snapshot written to " <> T.pack path
handleIEvent (LoggingStopped path) =
    postInfoMessage $ "Stopped logging to " <> T.pack path
handleIEvent (LogStartFailed path err) =
    postErrorMessage' $ "Could not start logging to " <> T.pack path <>
                        ", error: " <> T.pack err
handleIEvent (LogSnapshotFailed path err) =
    postErrorMessage' $ "Could not write log snapshot to " <> T.pack path <>
                        ", error: " <> T.pack err

formatError :: MHError -> T.Text
formatError (GenericError msg) =
    msg
formatError (NoSuchChannel chan) =
    T.pack $ "No such channel: " <> show chan
formatError (NoSuchUser user) =
    T.pack $ "No such user: " <> show user
formatError (AmbiguousName name) =
    (T.pack $ "The input " <> show name <> " matches both channels ") <>
    "and users. Try using '" <> userSigil <> "' or '" <>
    normalChannelSigil <> "' to disambiguate."
formatError (ServerError e) =
    mattermostErrorMessage e
formatError (ClipboardError msg) =
    msg
formatError (ConfigOptionMissing opt) =
    T.pack $ "Config option " <> show opt <> " missing"
formatError (ProgramExecutionFailed progName logPath) =
    T.pack $ "An error occurred when running " <> show progName <>
             "; see " <> show logPath <> " for details."
formatError (NoSuchScript name) =
    "No script named " <> name <> " was found"
formatError (NoSuchHelpTopic topic) =
    let knownTopics = ("  - " <>) <$> helpTopicName <$> helpTopics
    in "Unknown help topic: `" <> topic <> "`. " <>
       (T.unlines $ "Available topics are:" : knownTopics)
formatError (AsyncErrEvent e) =
    "An unexpected error has occurred! The exception encountered was:\n  " <>
    T.pack (show e) <>
    "\nPlease report this error at https://github.com/matterhorn-chat/matterhorn/issues"

onVtyEvent :: Vty.Event -> MH ()
onVtyEvent e = do
    case e of
        (Vty.EvResize _ _) ->
            -- On resize, invalidate the entire rendering cache since
            -- many things depend on the window size.
            --
            -- Note: we fall through after this because it is sometimes
            -- important for modes to have their own additional logic
            -- to run when a resize occurs, so we don't want to stop
            -- processing here.
            mh invalidateCache
        _ -> return ()

    void $ handleKeyboardEvent globalKeybindings handleGlobalEvent e

handleGlobalEvent :: Vty.Event -> MH ()
handleGlobalEvent e = do
    mode <- use (csCurrentTeam.tsMode)
    globalHandlerByMode mode e

globalHandlerByMode :: Mode -> Vty.Event -> MH ()
globalHandlerByMode mode =
    case mode of
        Main                       -> onEventMain
        ShowHelp _ _               -> void . onEventShowHelp
        ChannelSelect              -> void . onEventChannelSelect
        UrlSelect                  -> void . onEventUrlSelect
        LeaveChannelConfirm        -> onEventLeaveChannelConfirm
        MessageSelect              -> onEventMessageSelect
        MessageSelectDeleteConfirm -> onEventMessageSelectDeleteConfirm
        DeleteChannelConfirm       -> onEventDeleteChannelConfirm
        ThemeListOverlay           -> onEventThemeListOverlay
        PostListOverlay _          -> onEventPostListOverlay
        UserListOverlay            -> onEventUserListOverlay
        ChannelListOverlay         -> onEventChannelListOverlay
        ReactionEmojiListOverlay   -> onEventReactionEmojiListOverlay
        ViewMessage                -> void . handleTabbedWindowEvent
                                             (csCurrentTeam.tsViewedMessage.singular _Just._2)
        ManageAttachments          -> onEventManageAttachments
        ManageAttachmentsBrowseFiles -> onEventManageAttachments
        EditNotifyPrefs            -> void . onEventEditNotifyPrefs
        ChannelTopicWindow         -> onEventChannelTopicWindow

globalKeybindings :: KeyConfig -> KeyHandlerMap
globalKeybindings = mkKeybindings globalKeyHandlers

globalKeyHandlers :: [KeyEventHandler]
globalKeyHandlers =
    [ mkKb ShowHelpEvent
        "Show this help screen"
        (showHelpScreen mainHelpTopic)
    ]

-- | Refresh client-accessible server configuration information. This
-- is usually triggered when a reconnect event for the WebSocket to the
-- server occurs.
refreshClientConfig :: MH ()
refreshClientConfig = do
    session <- getSession
    doAsyncWith Preempt $ do
        cfg <- MM.mmGetClientConfiguration (Just "old") session
        return $ Just $ do
            csClientConfig .= Just cfg
            updateSidebar Nothing
