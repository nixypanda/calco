module Ui.Theme exposing
    ( Mode(..)
    , Theme
    , forMode
    , light
    , modeFromString
    , modeToString
    , toggle
    )

import Element exposing (Color, rgb255)


type Mode
    = Light
    | Dark


type alias Theme =
    { mode : Mode
    , pageBg : Color
    , cardBg : Color
    , chipBg : Color
    , chipBorder : Color
    , textPrimary : Color
    , textMuted : Color
    , textMedium : Color
    , divider : Color
    , inputFill : Color
    , brandBlue : Color
    , brandBluePressed : Color
    , brandBlueSoft : Color
    , brandBlueDisabled : Color
    , dangerBg : Color
    , dangerFg : Color
    , dangerSolid : Color
    , drawerSelectionBg : Color
    , statusGreen : Color
    , statusRed : Color
    , statusActiveBg : Color
    , statusDisabledBg : Color
    , cardShadow : String
    }


light : Theme
light =
    { mode = Light
    , pageBg = rgb255 244 246 248
    , cardBg = rgb255 255 255 255
    , chipBg = rgb255 236 240 244
    , chipBorder = rgb255 218 224 232
    , textPrimary = rgb255 28 32 44
    , textMuted = rgb255 120 124 140
    , textMedium = rgb255 64 70 84
    , divider = rgb255 232 234 238
    , inputFill = rgb255 244 246 248
    , brandBlue = rgb255 75 145 207
    , brandBluePressed = rgb255 60 125 185
    , brandBlueSoft = rgb255 232 242 250
    , brandBlueDisabled = rgb255 131 170 207
    , dangerBg = rgb255 255 235 238
    , dangerFg = rgb255 200 60 80
    , dangerSolid = rgb255 255 107 122
    , drawerSelectionBg = rgb255 232 242 250
    , statusGreen = rgb255 50 110 60
    , statusRed = rgb255 180 60 80
    , statusActiveBg = rgb255 200 235 200
    , statusDisabledBg = rgb255 255 200 210
    , cardShadow = "0 4px 16px rgba(28, 32, 44, 0.06)"
    }


dark : Theme
dark =
    { mode = Dark
    , pageBg = rgb255 18 20 26
    , cardBg = rgb255 28 32 40
    , chipBg = rgb255 42 47 58
    , chipBorder = rgb255 58 66 80
    , textPrimary = rgb255 232 234 240
    , textMuted = rgb255 148 152 168
    , textMedium = rgb255 192 196 208
    , divider = rgb255 44 48 58
    , inputFill = rgb255 38 42 52
    , brandBlue = rgb255 96 165 227
    , brandBluePressed = rgb255 120 185 240
    , brandBlueSoft = rgb255 36 56 80
    , brandBlueDisabled = rgb255 70 108 145
    , dangerBg = rgb255 60 28 34
    , dangerFg = rgb255 255 138 152
    , dangerSolid = rgb255 220 80 100
    , drawerSelectionBg = rgb255 36 56 80
    , statusGreen = rgb255 140 220 160
    , statusRed = rgb255 255 130 150
    , statusActiveBg = rgb255 60 110 70
    , statusDisabledBg = rgb255 110 50 60
    , cardShadow = "0 4px 16px rgba(0, 0, 0, 0.4)"
    }


forMode : Mode -> Theme
forMode mode =
    case mode of
        Light ->
            light

        Dark ->
            dark


toggle : Mode -> Mode
toggle mode =
    case mode of
        Light ->
            Dark

        Dark ->
            Light


modeToString : Mode -> String
modeToString mode =
    case mode of
        Dark ->
            "dark"

        Light ->
            "light"


modeFromString : String -> Mode
modeFromString s =
    if s == "dark" then
        Dark

    else
        Light
