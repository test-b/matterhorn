{-# LANGUAGE OverloadedStrings #-}
module Matterhorn.Draw.DeleteChannelConfirm
    ( drawDeleteChannelConfirm
    )
where

import Prelude ()
import Matterhorn.Prelude

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center

import Matterhorn.Themes
import Matterhorn.Types


drawDeleteChannelConfirm :: ChatState -> Widget Name
drawDeleteChannelConfirm st =
    let cName = st^.csCurrentChannel.ccInfo.cdName
    in centerLayer $ hLimit 50 $ vLimit 15 $
       withDefAttr dialogAttr $
       borderWithLabel (txt "Confirm Delete Channel") $
       vBox [ padBottom (Pad 1) $ hCenter $ txt "Are you sure you want to delete this channel?"
            , padBottom (Pad 1) $ hCenter $ withDefAttr dialogEmphAttr $ txt cName
            , hCenter $ txt "Press " <+> (withDefAttr dialogEmphAttr $ txt "Y") <+> txt " to delete the channel"
            , hCenter $ txt "or any other key to cancel."
            ]
