module Ui exposing
    ( -- Colors
      primaryTeal
    , proteinColor
    , carbsColor
    , fatColor
    , borderGray
    , cardBg
    , dangerBg
    , darkColor
    , mediumColor
    , mutedColor
      -- Typography
    , display
    , heading1
    , heading2
    , heading3
    , body
    , caption
    , small
    , bold
    , medium
      -- Layout
    , layout
    , pageContainer
    , pageHeader
    , card
    , sectionHeader
      -- States
    , loading
    , emptyState
    , errorBanner
    , skeletonLoading
      -- Buttons
    , button
    , submitButton
    , dangerButton
    , smallButton
      -- Inputs
    , input
    , passwordInput
    , select
    , selectDropdown
      -- Display
    , mutedText
    , badge
    , macroBar
    , cardActions
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


proteinColor : Element.Color
proteinColor =
    Element.rgb255 212 80 107


carbsColor : Element.Color
carbsColor =
    Element.rgb255 76 175 80


fatColor : Element.Color
fatColor =
    Element.rgb255 255 193 7


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



-- New UI components


badge : String -> Element msg
badge label_ =
    Element.el
        [ Background.color borderGray
        , Font.color mutedColor
        , Border.rounded 12
        , Element.paddingXY 8 4
        , small
        , Font.medium
        ]
        (Element.text label_)


selectDropdown :
    { label : String
    , selected : a
    , options : List ( a, String )
    , onChange : a -> msg
    , isOpen : Bool
    , onToggle : msg
    }
    -> Element msg
selectDropdown config =
    let
        selectedLabel : String
        selectedLabel =
            case List.filter (\( val, _ ) -> val == config.selected) config.options of
                ( _, lbl ) :: _ ->
                    lbl

                [] ->
                    ""
    in
    let
        optionsElement : Element msg
        optionsElement =
            if config.isOpen then
                Element.column
                    [ Element.width Element.fill
                    , Element.spacing 0
                    , Border.rounded 6
                    , Border.width 1
                    , Border.color inputBorder
                    , Background.color cardBg
                    ]
                    (List.map
                        (\( val, lbl ) ->
                            Input.button
                                [ Element.width Element.fill
                                , Element.paddingEach
                                    { top = 10, bottom = 10, left = 14, right = 14 }
                                , body
                                , Background.color
                                    (if val == config.selected then
                                        primaryTeal

                                     else
                                        cardBg
                                    )
                                , Font.color
                                    (if val == config.selected then
                                        Element.rgb255 255 255 255

                                     else
                                        darkColor
                                    )
                                ]
                                { onPress = Just (config.onChange val)
                                , label = Element.text lbl
                                }
                        )
                        config.options
                    )

            else
                Element.none
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Element.el [ body, Font.medium ] (Element.text config.label)
        , Input.button
            (List.concat
                [ [ Element.width Element.fill
                  , Border.rounded 6
                  , Border.width 1
                  , Border.color inputBorder
                  , Element.padding 10
                  , Background.color cardBg
                  ]
                , if config.isOpen then
                    [ Element.below optionsElement ]

                  else
                    []
                ]
            )
            { onPress = Just config.onToggle
            , label =
                Element.row [ Element.width Element.fill, Element.spacing 8 ]
                    [ Element.el [ Element.width Element.fill, body ] (Element.text selectedLabel)
                    , Element.text (if config.isOpen then "▲" else "▼")
                    ]
            }
        ]


macroBar :
    { label : String
    , value : Float
    , unit : String
    , color : Element.Color
    , max : Float
    }
    -> Element msg
macroBar config =
    let
        pct : Float
        pct =
            if config.max > 0 then
                min 1.0 (config.value / config.max)

            else
                0

        filled : Int
        filled =
            max 0 (round (pct * 100))

        remaining : Int
        remaining =
            max 0 (100 - filled)
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Element.row [ Element.width Element.fill ]
            [ Element.el [ bold, body ] (Element.text config.label)
            , Element.el
                [ body
                , Font.color mutedColor
                , Element.alignRight
                ]
                (Element.text (String.fromInt (round config.value) ++ " " ++ config.unit))
            ]
        , if pct > 0 then
            Element.row
                [ Element.width Element.fill
                , Element.height (Element.px 12)
                , Background.color borderGray
                , Border.rounded 6
                , Element.clip
                ]
                [ Element.el
                    [ Element.width (Element.fillPortion filled)
                    , Element.height Element.fill
                    , Background.color config.color
                    , Border.rounded 6
                    ]
                    Element.none
                , Element.el [ Element.width (Element.fillPortion remaining) ] Element.none
                ]

          else
            Element.row
                [ Element.width Element.fill
                , Element.height (Element.px 12)
                , Background.color borderGray
                , Border.rounded 6
                ]
                []
        ]


skeletonLoading : Element msg
skeletonLoading =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ skeletonBar
        , skeletonBar
        , skeletonBar
        ]


skeletonBar : Element msg
skeletonBar =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 16)
        , Background.color borderGray
        , Border.rounded 4
        ]
        Element.none


cardActions : List (Element msg) -> Element msg
cardActions buttons =
    Element.row
        [ Element.width Element.fill
        , Element.paddingEach { top = 12, right = 0, bottom = 0, left = 0 }
        , Element.spacing 12
        , Border.widthEach { top = 1, right = 0, bottom = 0, left = 0 }
        , Border.color borderGray
        ]
        buttons
