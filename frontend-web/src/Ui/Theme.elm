module Ui.Theme exposing
    ( Mode(..)
    , Preference(..)
    , State
    , Theme
    , forMode
    , forState
    , fromFlags
    , light
    , preferenceFromString
    , preferenceToString
    , savedPreference
    , selectPreference
    , setSystemPrefersDark
    )

import Element exposing (Color, rgb255, rgba255)


type Mode
    = Light
    | Dark


{-| The saved choice. `System` follows the operating-system color scheme;
`LightMode` and `DarkMode` override it. The names stay distinct from `Mode`'s
constructors because both types live in this module.
-}
type Preference
    = System
    | LightMode
    | DarkMode


{-| The saved choice plus the latest operating-system scheme. The effective
`Mode` is derived from both, so the resolved palette is never stored alongside
the inputs it came from.
-}
type State
    = State
        { preference : Preference
        , systemMode : Mode
        }


{-| A resolved palette. `mode` is the effective scheme, while `preference` is
carried for theme controls so they do not need a second source.
-}
type alias Theme =
    { mode : Mode
    , preference : Preference
    , pageBg : Color
    , cardBg : Color
    , cardSurfaceBg : Color
    , cardHeaderBg : Color
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
    , brandBluePressed : Color
    , brandBlueSoft : Color
    , brandBlueDisabled : Color
    , solidControlFg : Color
    , dangerBg : Color
    , dangerFg : Color
    , dangerSolid : Color
    , dangerSolidPressed : Color
    , warningBg : Color
    , warningFg : Color
    , drawerSelectionBg : Color
    , statusGreen : Color
    , statusGreenSoft : Color
    , statusRed : Color
    , statusActiveBg : Color
    , statusDisabledBg : Color
    , focusRing : Color
    , scrim : Color
    , mediaBackdrop : Color
    , goalUnder : Color
    , calorieAccent : Color
    , proteinAccent : Color
    , carbsAccent : Color
    , fatAccent : Color
    , cardShadow : String
    }


light : Theme
light =
    { mode = Light
    , preference = LightMode
    , pageBg = rgb255 244 246 248
    , cardBg = rgb255 255 255 255
    , cardSurfaceBg = rgb255 250 253 254
    , cardHeaderBg = rgb255 236 246 252
    , chipBg = rgb255 236 240 244
    , chipBorder = rgb255 218 224 232
    , chipSelectedBg = rgb255 94 224 213
    , chipSelectedFg = rgb255 28 32 44
    , textPrimary = rgb255 28 32 44
    , textMuted = rgb255 80 84 100
    , textMedium = rgb255 64 70 84
    , divider = rgb255 232 234 238
    , inputFill = rgb255 244 246 248
    , brandBlue = rgb255 18 147 216
    , brandBluePressed = rgb255 14 120 178
    , brandBlueSoft = rgb255 228 243 252
    , brandBlueDisabled = rgb255 150 195 220
    , solidControlFg = rgb255 255 255 255
    , dangerBg = rgb255 255 235 237
    , dangerFg = rgb255 214 58 70
    , dangerSolid = rgb255 226 74 84
    , dangerSolidPressed = rgb255 202 55 65

    -- Amber warning tone for non-blocking, incomplete-data notices.
    -- `warningFg` clears 4.5:1 against `warningBg` in both themes.
    , warningBg = rgb255 255 246 224
    , warningFg = rgb255 122 79 0
    , drawerSelectionBg = rgb255 228 243 252
    , statusGreen = rgb255 50 110 60

    -- A lighter good-range green for progress fills and guidance text.
    -- Kept near 4.5:1 against `cardSurfaceBg` so 13px captions stay legible.
    , statusGreenSoft = rgb255 60 131 73
    , statusRed = rgb255 180 60 80
    , statusActiveBg = rgb255 200 235 200
    , statusDisabledBg = rgb255 255 200 210
    , focusRing = rgb255 18 147 216
    , scrim = rgba255 0 0 0 0.28
    , mediaBackdrop = rgb255 0 0 0
    , goalUnder = rgb255 0 135 145

    -- Accepted deviation: macro accent fills read below the 3:1 non-text
    -- contrast target in light mode. The palette is intentional; do not
    -- "fix" this by darkening the accents without a design decision.
    , calorieAccent = rgb255 94 224 213
    , proteinAccent = rgb255 255 138 170
    , carbsAccent = rgb255 200 235 200
    , fatAccent = rgb255 255 210 80
    , cardShadow = "0 4px 16px rgba(28, 32, 44, 0.06)"
    }


dark : Theme
dark =
    { mode = Dark
    , preference = DarkMode
    , pageBg = rgb255 18 20 26
    , cardBg = rgb255 28 32 40
    , cardSurfaceBg = rgb255 30 38 48
    , cardHeaderBg = rgb255 33 47 59
    , chipBg = rgb255 42 47 58
    , chipBorder = rgb255 58 66 80
    , chipSelectedBg = rgb255 46 155 146
    , chipSelectedFg = rgb255 18 20 26
    , textPrimary = rgb255 232 234 240
    , textMuted = rgb255 148 152 168
    , textMedium = rgb255 192 196 208
    , divider = rgb255 44 48 58
    , inputFill = rgb255 38 42 52
    , brandBlue = rgb255 74 178 232
    , brandBluePressed = rgb255 110 198 244
    , brandBlueSoft = rgb255 20 45 62
    , brandBlueDisabled = rgb255 90 130 155
    , solidControlFg = rgb255 18 20 26
    , dangerBg = rgb255 60 28 34
    , dangerFg = rgb255 255 138 152
    , dangerSolid = rgb255 240 96 112
    , dangerSolidPressed = rgb255 250 120 135
    , warningBg = rgb255 60 48 22
    , warningFg = rgb255 245 200 120
    , drawerSelectionBg = rgb255 20 45 62
    , statusGreen = rgb255 140 220 160
    , statusGreenSoft = rgb255 168 236 184
    , statusRed = rgb255 255 130 150
    , statusActiveBg = rgb255 60 110 70
    , statusDisabledBg = rgb255 110 50 60
    , focusRing = rgb255 74 178 232
    , scrim = rgba255 0 0 0 0.28
    , mediaBackdrop = rgb255 0 0 0
    , goalUnder = rgb255 78 208 196
    , calorieAccent = rgb255 78 208 196
    , proteinAccent = rgb255 255 158 188
    , carbsAccent = rgb255 126 192 136
    , fatAccent = rgb255 242 196 96
    , cardShadow = "0 4px 16px rgba(0, 0, 0, 0.4)"
    }


{-| Build a palette with its matching preference. Application state resolves
through `forState`; this constructor is for previews and tests, and still cannot
produce a palette whose `mode` and `preference` disagree.
-}
forMode : Mode -> Theme
forMode mode =
    case mode of
        Light ->
            light

        Dark ->
            dark


{-| Resolve the typed theme state into the palette that views consume. The
palette keeps the saved preference for theme controls, while its `mode` is the
effective light/dark choice.
-}
forState : State -> Theme
forState state =
    let
        palette : Theme
        palette =
            forMode (effectiveMode state)
    in
    { palette | preference = savedPreference state }


{-| Parse the two raw JavaScript flags at the transport boundary.
-}
fromFlags : String -> Bool -> State
fromFlags rawPreference systemPrefersDark =
    State
        { preference = preferenceFromString rawPreference
        , systemMode = modeFromBool systemPrefersDark
        }


savedPreference : State -> Preference
savedPreference (State state) =
    state.preference


selectPreference : Preference -> State -> State
selectPreference next (State state) =
    State { state | preference = next }


{-| Record the latest OS scheme even while a manual choice overrides it, so
selecting `System` later follows the current setting without another port
round trip.
-}
setSystemPrefersDark : Bool -> State -> State
setSystemPrefersDark systemPrefersDark (State state) =
    State { state | systemMode = modeFromBool systemPrefersDark }


effectiveMode : State -> Mode
effectiveMode state =
    case savedPreference state of
        System ->
            systemMode state

        LightMode ->
            Light

        DarkMode ->
            Dark


systemMode : State -> Mode
systemMode (State state) =
    state.systemMode


modeFromBool : Bool -> Mode
modeFromBool systemPrefersDark =
    if systemPrefersDark then
        Dark

    else
        Light


preferenceToString : Preference -> String
preferenceToString preference =
    case preference of
        System ->
            "system"

        LightMode ->
            "light"

        DarkMode ->
            "dark"


{-| Old saved values were only "light" or "dark"; keep honoring them and treat
anything missing or unknown as the system preference.
-}
preferenceFromString : String -> Preference
preferenceFromString value =
    case value of
        "light" ->
            LightMode

        "dark" ->
            DarkMode

        _ ->
            System
