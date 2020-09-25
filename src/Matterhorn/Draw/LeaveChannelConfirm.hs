{-# LANGUAGE OverloadedStrings #-}
module Matterhorn.Draw.LeaveChannelConfirm
    ( drawLeaveChannelConfirm
    )
where

import Prelude ()
import Matterhorn.Prelude

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center

import Matterhorn.Themes
import Matterhorn.Types


drawLeaveChannelConfirm :: ChatState -> Widget Name
drawLeaveChannelConfirm st =
    let cName = st^.csCurrentChannel.ccInfo.cdName
    in centerLayer $ hLimit 50 $ vLimit 15 $
       withDefAttr dialogAttr $
       borderWithLabel (txt "Confirm Leave Channel") $
       vBox [ padBottom (Pad 1) $ hCenter $ txt "Are you sure you want to leave this channel?"
            , padBottom (Pad 1) $ hCenter $ withDefAttr dialogEmphAttr $ txt cName
            , hCenter $ txt "Press " <+> (withDefAttr dialogEmphAttr $ txt "Y") <+> txt " to leave the channel"
            , hCenter $ txt "or any other key to cancel."
            ]
