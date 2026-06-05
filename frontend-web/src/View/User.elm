module View.User exposing
    ( statusBadge
    , userListRow
    , userSummaryCard
    )

import Data.User as User
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui


statusBadge : String -> Element msg
statusBadge status =
    Ui.coloredBadge
        { label = status
        , background =
            if status == "active" then
                Element.rgb255 220 252 231

            else
                Element.rgb255 254 226 226
        , foreground =
            if status == "active" then
                Element.rgb255 22 101 52

            else
                Element.rgb255 153 27 27
        }


userListRow : { user : User.User, onSelect : String -> msg } -> Element msg
userListRow config =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        ]
        { onPress = Just (config.onSelect config.user.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.column [ Element.width Element.fill, Element.spacing 2 ]
                    [ Element.el [ Font.bold ] (Element.text config.user.username)
                    , Ui.mutedText config.user.displayName
                    ]
                , Element.el [ Element.alignRight ] (statusBadge config.user.status)
                ]
        }


userSummaryCard : User.User -> Element msg
userSummaryCard user =
    Ui.card
        [ Element.column [ Element.spacing 8, Element.width Element.fill ]
            [ Element.el [ Font.bold, Ui.heading3 ] (Element.text user.username)
            , Ui.detailRow "Display Name"
                (Element.el [ Ui.caption ] (Element.text user.displayName))
            , Ui.detailRow "Status" (statusBadge user.status)
            , Ui.detailRow "Created"
                (Element.el [ Ui.caption ] (Element.text user.createdAt))
            ]
        ]
