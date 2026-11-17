module Ui.ThemeChoice exposing
    ( clickAwayDecoder
    , compactTrigger
    , compactTriggerId
    , focusOutDecoder
    , menu
    , menuId
    , view
    )

{-| Theme preference controls. Settings uses the labelled three-button group;
the top bar uses a single compact trigger that opens the same three choices, so
a Phone title keeps its width. The compact menu marks its selected row with a
check; the Settings buttons use bold text and a pressed state instead.
-}

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import Html.Events
import I18n
import Json.Decode as Decode exposing (Decoder)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common exposing (dataAttribute, testId, uiClass)
import Ui.DesignTokens
    exposing
        ( minimumTargetSize
        , radiusCard
        , radiusPill
        , space12
        , space4
        , space8
        )
import Ui.Icon as Icon exposing (Icon)
import Ui.Input as UiInput
import Ui.Theme as Theme exposing (Theme)


preferences : List Theme.Preference
preferences =
    [ Theme.System, Theme.LightMode, Theme.DarkMode ]


view :
    Theme
    -> Language
    -> (Theme.Preference -> msg)
    -> Element msg
view theme language onSelect =
    Element.row
        [ Element.spacing 0
        , Element.width Element.fill
        , Border.rounded radiusPill
        , Border.width 1
        , Border.color theme.divider
        , Background.color theme.cardBg
        , Element.htmlAttribute (Html.Attributes.attribute "role" "group")
        , Element.htmlAttribute
            (Html.Attributes.attribute "aria-label"
                (I18n.t language TidSettingsThemeTitle)
            )
        ]
        (List.map (option theme language onSelect) preferences)


option :
    Theme
    -> Language
    -> (Theme.Preference -> msg)
    -> Theme.Preference
    -> Element msg
option theme language onSelect preference =
    let
        label : String
        label =
            preferenceLabel language preference

        selected : Bool
        selected =
            preference == theme.preference

        foreground : Element.Color
        foreground =
            if selected then
                theme.chipSelectedFg

            else
                theme.textPrimary
    in
    Input.button
        [ Element.height (Element.px minimumTargetSize)
        , Element.width Element.fill
        , Element.paddingEach
            { top = 0
            , right = space12
            , bottom = 0
            , left = space12
            }
        , Border.rounded radiusPill
        , Background.color
            (if selected then
                theme.chipSelectedBg

             else
                theme.cardBg
            )
        , Font.color foreground
        , Font.size 14
        , if selected then
            Font.bold

          else
            Font.medium
        , uiClass "ui-motion ui-pressable"
        , testId ("theme-choice-" ++ Theme.preferenceToString preference)
        , Element.htmlAttribute (Html.Attributes.title label)
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" label)
        , Element.htmlAttribute
            (Html.Attributes.attribute "aria-pressed"
                (boolString selected)
            )
        ]
        { onPress = Just (onSelect preference)
        , label =
            Element.el [ Element.width Element.fill, Font.center ]
                (Element.text label)
        }



{-
   The compact trigger is the focus target after Escape or a choice closes
   the menu, so its id is public and shared with the app focus wiring.
-}


compactTriggerId : String
compactTriggerId =
    "app-theme-menu-trigger"


menuId : String
menuId =
    "theme-menu"


{-| The document-level click-away listener is installed after the opening
update, so it can still see that same click. Ignore any event whose target is
the trigger or the menu: the trigger handles its own toggle, and menu rows
handle their own choice. Every other click dismisses the menu without consuming
the page action under the pointer.
-}
clickAwayDecoder : msg -> Decoder msg
clickAwayDecoder msg =
    Decode.oneOf
        [ Decode.field "target" insideThemeChooser
        , Decode.succeed False
        ]
        |> Decode.andThen
            (\inside ->
                if inside then
                    Decode.fail "click inside the theme chooser"

                else
                    Decode.succeed msg
            )


{-| Tab and other focus moves take focus to the next control before `focusout`
fires. Dismiss the menu when focus lands outside the trigger or menu, but keep
it open while focus moves between them. Closing after the browser has moved
focus avoids removing the focused option and dropping focus on the document.
-}
focusOutDecoder : msg -> Decoder msg
focusOutDecoder msg =
    Decode.oneOf
        [ Decode.field "relatedTarget"
            (Decode.nullable (Decode.lazy (\_ -> insideThemeChooser)))
        , Decode.succeed Nothing
        ]
        |> Decode.map (Maybe.withDefault False)
        |> Decode.andThen
            (\inside ->
                if inside then
                    Decode.fail "focus stayed inside the theme chooser"

                else
                    Decode.succeed msg
            )


insideThemeChooser : Decoder Bool
insideThemeChooser =
    Decode.oneOf
        [ Decode.field "id" Decode.string
            |> Decode.andThen
                (\id ->
                    if id == compactTriggerId || id == menuId then
                        Decode.succeed True

                    else
                        Decode.fail "not the theme chooser"
                )
        , Decode.field "parentElement"
            (Decode.nullable (Decode.lazy (\_ -> insideThemeChooser)))
            |> Decode.map (Maybe.withDefault False)
        ]


{-| The compact top-bar control is one 44px button showing the saved choice.
It opens the labelled menu below, so three options no longer consume the Phone
title's horizontal space.
-}
compactTrigger :
    Theme
    -> Language
    ->
        { expanded : Bool
        , onToggle : msg
        , onClose : msg
        }
    -> Element msg
compactTrigger theme language config =
    let
        label : String
        label =
            I18n.t language TidSettingsThemeTitle
                ++ ": "
                ++ preferenceLabel language theme.preference

        closeOnFocusOut : List (Element.Attribute msg)
        closeOnFocusOut =
            if config.expanded then
                [ Element.htmlAttribute
                    (Html.Events.on "focusout" (focusOutDecoder config.onClose))
                ]

            else
                []
    in
    Input.button
        ([ Element.width (Element.px minimumTargetSize)
         , Element.height (Element.px minimumTargetSize)
         , Element.padding 0
         , Border.rounded radiusPill
         , Border.width 1
         , Border.color theme.divider
         , Background.color
            (if config.expanded then
                theme.chipBg

             else
                theme.cardBg
            )
         , Font.color theme.textPrimary
         , uiClass "ui-motion ui-pressable"
         , testId "theme-menu-trigger"
         , Element.htmlAttribute (Html.Attributes.id compactTriggerId)
         , Element.htmlAttribute (Html.Attributes.title label)
         , Element.htmlAttribute (Html.Attributes.attribute "aria-label" label)
         , Element.htmlAttribute
            (Html.Attributes.attribute "aria-expanded" (boolString config.expanded))
         , Element.htmlAttribute (Html.Attributes.attribute "aria-controls" menuId)
         ]
            ++ closeOnFocusOut
        )
        { onPress = Just config.onToggle
        , label =
            Icon.view
                { icon = preferenceIcon theme.preference
                , size = 18
                , color = theme.textPrimary
                }
        }


menu :
    Theme
    -> Language
    -> { onSelect : Theme.Preference -> msg, onClose : msg }
    -> Element msg
menu theme language config =
    Element.column
        [ Element.alignRight
        , Element.moveDown (toFloat space4)
        , Element.width (Element.px 200)
        , Element.padding space8
        , Element.spacing space4
        , Background.color theme.cardSurfaceBg
        , Border.rounded radiusCard
        , uiClass "ui-card-shadow"
        , Element.htmlAttribute (Html.Attributes.id menuId)
        , Element.htmlAttribute (Html.Attributes.attribute "role" "group")
        , Element.htmlAttribute
            (Html.Attributes.attribute "aria-label"
                (I18n.t language TidSettingsThemeTitle)
            )
        , Element.htmlAttribute
            (Html.Events.on "focusout" (focusOutDecoder config.onClose))
        , testId "theme-menu"
        ]
        (List.map (menuOption theme language config.onSelect) preferences)


menuOption :
    Theme
    -> Language
    -> (Theme.Preference -> msg)
    -> Theme.Preference
    -> Element msg
menuOption theme language onSelect preference =
    let
        selected : Bool
        selected =
            preference == theme.preference

        label : String
        label =
            preferenceLabel language preference
    in
    Element.el
        [ Element.width Element.fill
        , testId ("theme-menu-" ++ Theme.preferenceToString preference)
        , dataAttribute "theme-preference" (Theme.preferenceToString preference)
        ]
        (UiInput.optionRowWithState theme
            { label = label
            , selected = selected
            , onPress = onSelect preference
            , disabled = False
            , trailing =
                if selected then
                    Just
                        (Icon.view
                            { icon = Icon.Check
                            , size = 18
                            , color = theme.chipSelectedFg
                            }
                        )

                else
                    Nothing
            }
        )


preferenceIcon : Theme.Preference -> Icon
preferenceIcon preference =
    case preference of
        Theme.System ->
            Icon.System

        Theme.LightMode ->
            Icon.Sun

        Theme.DarkMode ->
            Icon.Moon


preferenceLabel : Language -> Theme.Preference -> String
preferenceLabel language preference =
    I18n.t language
        (case preference of
            Theme.System ->
                TidCommonThemeSystem

            Theme.LightMode ->
                TidCommonThemeLight

            Theme.DarkMode ->
                TidCommonThemeDark
        )


boolString : Bool -> String
boolString value =
    if value then
        "true"

    else
        "false"
