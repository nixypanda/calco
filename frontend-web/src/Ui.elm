module Ui exposing (button, errorBanner, input, layout, passwordInput)

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input


layout : Element msg -> Element msg
layout content =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color (Element.rgb255 247 247 244)
        , Font.family [ Font.typeface "Inter", Font.sansSerif ]
        , Font.color (Element.rgb255 31 41 55)
        ]
        content


button : String -> msg -> Element msg
button label msg =
    Input.button
        [ Background.color (Element.rgb255 17 100 102)
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 6
        , Element.paddingXY 14 10
        , Font.medium
        ]
        { onPress = Just msg
        , label = Element.text label
        }


input : String -> String -> (String -> msg) -> Element msg
input label value onChange =
    Input.text
        [ Border.rounded 6
        , Border.width 1
        , Border.color (Element.rgb255 209 213 219)
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [ Font.size 14, Font.medium ] (Element.text label)
        }


passwordInput : String -> String -> (String -> msg) -> Element msg
passwordInput label value onChange =
    Input.currentPassword
        [ Border.rounded 6
        , Border.width 1
        , Border.color (Element.rgb255 209 213 219)
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [ Font.size 14, Font.medium ] (Element.text label)
        , show = False
        }


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
