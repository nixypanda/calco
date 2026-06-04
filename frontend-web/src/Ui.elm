module Ui exposing
    ( body
    , bold
    , borderGray
    , button
    , caption
    , card
    , cardBg
      -- Typography
    , dangerBg
    , dangerButton
    , darkColor
    , display
    , emptyState
    , errorBanner
      -- Buttons
    , heading1
    , heading2
    , heading3
    , input
    , layout
    , loading
    , medium
      -- Layout
    , mediumColor
    , mutedColor
    , mutedText
    , pageContainer
    , pageHeader
    , passwordInput
    , -- Colors
      primaryTeal
    , sectionHeader
      -- States
    , select
      -- Display
    , small
    , smallButton
      -- Inputs
    , submitButton
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input



-- Colors


primaryTeal : Element.Color
primaryTeal =
    Element.rgb255 17 100 102


borderGray : Element.Color
borderGray =
    Element.rgb255 229 231 235


mutedColor : Element.Color
mutedColor =
    Element.rgb255 107 114 128


mediumColor : Element.Color
mediumColor =
    Element.rgb255 75 85 99


darkColor : Element.Color
darkColor =
    Element.rgb255 31 41 55


dangerBg : Element.Color
dangerBg =
    Element.rgb255 254 242 242


cardBg : Element.Color
cardBg =
    Element.rgb255 255 255 255


pageBg : Element.Color
pageBg =
    Element.rgb255 247 247 244


inputBorder : Element.Color
inputBorder =
    Element.rgb255 209 213 219



-- Typography


display : Element.Attribute msg
display =
    Font.size 32


heading1 : Element.Attribute msg
heading1 =
    Font.size 22


heading2 : Element.Attribute msg
heading2 =
    Font.size 20


heading3 : Element.Attribute msg
heading3 =
    Font.size 18


body : Element.Attribute msg
body =
    Font.size 14


caption : Element.Attribute msg
caption =
    Font.size 13


small : Element.Attribute msg
small =
    Font.size 12


bold : Element.Attribute msg
bold =
    Font.bold


medium : Element.Attribute msg
medium =
    Font.medium



-- Layout


layout : Element msg -> Element msg
layout content =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color pageBg
        , Font.family [ Font.typeface "Inter", Font.sansSerif ]
        , Font.color darkColor
        , body
        ]
        (Element.column
            [ Element.centerX
            , Element.width (Element.fill |> Element.maximum 960)
            ]
            [ content ]
        )


pageContainer : List (Element msg) -> Element msg
pageContainer children =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        , Element.padding 24
        ]
        children


pageHeader : String -> Maybe msg -> Element msg
pageHeader title back =
    Element.row
        [ Element.width Element.fill
        , Element.spacing 12
        ]
        (case back of
            Just backMsg ->
                [ button "Back" backMsg
                , Element.el [ heading1, bold ] (Element.text title)
                ]

            Nothing ->
                [ Element.el [ heading1, bold ] (Element.text title) ]
        )


card : List (Element msg) -> Element msg
card children =
    Element.column
        [ Element.width Element.fill
        , Background.color cardBg
        , Border.rounded 8
        , Border.width 1
        , Border.color borderGray
        , Element.padding 16
        , Element.spacing 12
        ]
        children


sectionHeader : String -> Element msg
sectionHeader title =
    Element.el [ heading3, bold ] (Element.text title)



-- States


loading : String -> Element msg
loading message =
    Element.el
        [ Font.color mutedColor ]
        (Element.text message)


emptyState : String -> Element msg
emptyState message =
    card [ Element.paragraph [ Font.color mutedColor, Font.center ] [ Element.text message ] ]


errorBanner : String -> Element msg
errorBanner message =
    Element.el
        [ Background.color (Element.rgb255 254 226 226)
        , Font.color (Element.rgb255 127 29 29)
        , Border.rounded 6
        , Element.padding 12
        , Element.width Element.fill
        ]
        (Element.text message)



-- Buttons


button : String -> msg -> Element msg
button label msg =
    Input.button
        [ Background.color primaryTeal
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 6
        , Element.paddingXY 14 10
        , Font.medium
        ]
        { onPress = Just msg
        , label = Element.text label
        }


submitButton : Bool -> String -> String -> msg -> Element msg
submitButton isSubmitting idleLabel submittingLabel msg =
    button
        (if isSubmitting then
            submittingLabel

         else
            idleLabel
        )
        msg


dangerButton : String -> msg -> Element msg
dangerButton label msg =
    Input.button
        [ Background.color (Element.rgb255 220 38 38)
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 6
        , Element.paddingXY 14 10
        , Font.medium
        ]
        { onPress = Just msg
        , label = Element.text label
        }


smallButton : String -> msg -> Element msg
smallButton label msg =
    Input.button
        [ Background.color primaryTeal
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 6
        , Element.paddingXY 12 8
        , caption
        , medium
        ]
        { onPress = Just msg
        , label = Element.text label
        }



-- Inputs


input : String -> String -> (String -> msg) -> Element msg
input label value onChange =
    Input.text
        [ Border.rounded 6
        , Border.width 1
        , Border.color inputBorder
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [ body, medium ] (Element.text label)
        }


passwordInput : String -> String -> (String -> msg) -> Element msg
passwordInput label value onChange =
    Input.currentPassword
        [ Border.rounded 6
        , Border.width 1
        , Border.color inputBorder
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [ body, medium ] (Element.text label)
        , show = False
        }


select : String -> a -> List ( a, String ) -> (a -> msg) -> Element msg
select label_ selected options onChange =
    Input.radio [ Element.spacing 8 ]
        { onChange = onChange
        , selected = Just selected
        , label = Input.labelAbove [ body, medium ] (Element.text label_)
        , options = List.map (\( val, lbl ) -> Input.option val (Element.text lbl)) options
        }



-- Display


mutedText : String -> Element msg
mutedText text =
    Element.el
        [ Font.color mutedColor
        , body
        ]
        (Element.text text)
