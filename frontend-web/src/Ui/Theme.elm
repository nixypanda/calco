module Ui.Theme exposing
    ( Mode(..)
    , Theme
    , forMode
    , light
    , modeFromString
    , modeToString
    , toggle
    )

import Element exposing (Color, rgb255, rgba255)


type Mode
    = Light
    | Dark


type alias Theme =
    { mode : Mode
    , pageBg : Color
    , cardBg : Color
    , chipBg : Color
    , chipBorder : Color
    , chipSelectedBg : Color
    , chipSelectedFg : Color
    , textPrimary : Color
    , textMuted : Color
    , textMedium : Color
    , divider : Color
    , inputFill : Color
    , brandBlue : Color
    , brandBlueOn : Color
    , brandBluePressed : Color
    , brandBlueSoft : Color
    , brandBlueDisabled : Color
    , dangerBg : Color
    , dangerFg : Color
    , dangerSolid : Color
    , dangerSolidOn : Color
    , dangerSolidPressed : Color
    , drawerSelectionBg : Color
    , statusGreen : Color
    , statusRed : Color
    , statusActiveBg : Color
    , statusDisabledBg : Color
    , focusRing : Color
    , scannerGuide : Color
    , scrim : Color
    , videoBackdrop : Color
    , underGoalAccent : Color
    , calorieAccent : Color
    , proteinAccent : Color
    , carbsAccent : Color
    , fatAccent : Color
    , cardShadow : String
    }


light : Theme
light =
    { mode = Light
    , pageBg = rgb255 244 246 248
    , cardBg = rgb255 255 255 255
    , chipBg = rgb255 236 240 244
    , chipBorder = rgb255 218 224 232
    , chipSelectedBg = rgb255 15 118 110
    , chipSelectedFg = rgb255 255 255 255
    , textPrimary = rgb255 28 32 44
    , textMuted = rgb255 80 84 100
    , textMedium = rgb255 64 70 84
    , divider = rgb255 232 234 238
    , inputFill = rgb255 244 246 248
    , brandBlue = rgb255 47 110 168
    , brandBlueOn = rgb255 255 255 255
    , brandBluePressed = rgb255 37 93 146
    , brandBlueSoft = rgb255 232 242 250
    , brandBlueDisabled = rgb255 131 170 207
    , dangerBg = rgb255 255 235 238
    , dangerFg = rgb255 179 38 30
    , dangerSolid = rgb255 207 58 76
    , dangerSolidOn = rgb255 255 255 255
    , dangerSolidPressed = rgb255 165 31 24
    , drawerSelectionBg = rgb255 232 242 250
    , statusGreen = rgb255 50 110 60
    , statusRed = rgb255 158 47 69
    , statusActiveBg = rgb255 200 235 200
    , statusDisabledBg = rgb255 255 200 210
    , focusRing = rgb255 15 118 110
    , scannerGuide = rgb255 94 224 213
    , scrim = rgba255 0 0 0 0.28
    , videoBackdrop = rgb255 0 0 0
    , underGoalAccent = rgb255 0 127 135
    , calorieAccent = rgb255 94 224 213
    , proteinAccent = rgb255 255 138 170
    , carbsAccent = rgb255 200 235 200
    , fatAccent = rgb255 255 210 80
    , cardShadow = "0 4px 16px rgba(28, 32, 44, 0.06)"
    }


dark : Theme
dark =
    { mode = Dark
    , pageBg = rgb255 18 20 26
    , cardBg = rgb255 28 32 40
    , chipBg = rgb255 42 47 58
    , chipBorder = rgb255 58 66 80
    , chipSelectedBg = rgb255 15 118 110
    , chipSelectedFg = rgb255 234 255 253
    , textPrimary = rgb255 232 234 240
    , textMuted = rgb255 148 152 168
    , textMedium = rgb255 192 196 208
    , divider = rgb255 44 48 58
    , inputFill = rgb255 38 42 52
    , brandBlue = rgb255 142 197 242
    , brandBlueOn = rgb255 18 20 26
    , brandBluePressed = rgb255 165 208 245
    , brandBlueSoft = rgb255 36 56 80
    , brandBlueDisabled = rgb255 70 108 145
    , dangerBg = rgb255 60 28 34
    , dangerFg = rgb255 255 138 152
    , dangerSolid = rgb255 199 58 77
    , dangerSolidOn = rgb255 255 255 255
    , dangerSolidPressed = rgb255 204 63 82
    , drawerSelectionBg = rgb255 36 56 80
    , statusGreen = rgb255 140 220 160
    , statusRed = rgb255 255 130 150
    , statusActiveBg = rgb255 47 90 56
    , statusDisabledBg = rgb255 92 40 49
    , focusRing = rgb255 104 226 214
    , scannerGuide = rgb255 104 226 214
    , scrim = rgba255 0 0 0 0.28
    , videoBackdrop = rgb255 0 0 0
    , underGoalAccent = rgb255 78 208 196
    , calorieAccent = rgb255 78 208 196
    , proteinAccent = rgb255 255 158 188
    , carbsAccent = rgb255 126 192 136
    , fatAccent = rgb255 242 196 96
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
