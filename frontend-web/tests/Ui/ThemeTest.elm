module Ui.ThemeTest exposing (tests)

{-| Theme state laws: old saved light/dark values stay explicit, missing or
unknown values follow the system, and the effective theme is always derived
from the saved preference plus the latest operating-system scheme.
-}

import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, fuzz, fuzz2, test)
import Ui.Theme as Theme exposing (Theme)
import Ui.ThemeChoice as ThemeChoice


tests : Test
tests =
    describe "Ui.Theme"
        [ describe "saved preference"
            [ test "old light and dark values stay explicit" <|
                \_ ->
                    [ Theme.preferenceFromString "light"
                    , Theme.preferenceFromString "dark"
                    ]
                        |> Expect.equal [ Theme.LightMode, Theme.DarkMode ]
            , test "missing and unknown values follow the system" <|
                \_ ->
                    [ Theme.preferenceFromString ""
                    , Theme.preferenceFromString "sepia"
                    ]
                        |> Expect.equal [ Theme.System, Theme.System ]
            , fuzz preferenceFuzzer "a preference roundtrips through storage" <|
                \preference ->
                    Theme.preferenceFromString (Theme.preferenceToString preference)
                        |> Expect.equal preference
            ]
        , describe "compact click-away"
            [ test "the opening click and clicks inside the menu are ignored" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            decodeThemeClick
                                [ "path", "", ThemeChoice.compactTriggerId ]
                                |> Expect.equal Nothing
                        , \_ ->
                            decodeThemeClick
                                [ "span", "", ThemeChoice.menuId ]
                                |> Expect.equal Nothing
                        ]
                        ()
            , test "clicks outside the theme chooser dismiss the menu" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            decodeThemeClick
                                [ "button", "", "body", "" ]
                                |> Expect.equal (Just ())
                        , \_ ->
                            decodeThemeClick [ "" ]
                                |> Expect.equal (Just ())
                        ]
                        ()
            ]
        , describe "compact focus leave"
            [ test "focus moving inside the chooser keeps the menu open" <|
                \_ ->
                    [ decodeThemeFocusOut [ "", ThemeChoice.compactTriggerId ]
                    , decodeThemeFocusOut [ "button", "", ThemeChoice.menuId ]
                    ]
                        |> Expect.equal [ Nothing, Nothing ]
            , test "focus leaving the chooser dismisses the menu" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            decodeThemeFocusOut
                                [ "button", "", "body", "" ]
                                |> Expect.equal (Just ())
                        , \_ ->
                            decodeThemeFocusOut [ "" ]
                                |> Expect.equal (Just ())
                        ]
                        ()
            ]
        , describe "typed state"
            [ test "flags initialize the saved choice and system scheme" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            Theme.fromFlags "system" True
                                |> Theme.forState
                                |> .mode
                                |> Expect.equal Theme.Dark
                        , \_ ->
                            Theme.fromFlags "light" True
                                |> Theme.forState
                                |> .preference
                                |> Expect.equal Theme.LightMode
                        , \_ ->
                            Theme.fromFlags "sepia" False
                                |> Theme.forState
                                |> .preference
                                |> Expect.equal Theme.System
                        ]
                        ()
            , test "manual selections override the current system scheme" <|
                \_ ->
                    let
                        state : Theme.State
                        state =
                            Theme.fromFlags "system" True

                        lightTheme : Theme
                        lightTheme =
                            Theme.selectPreference Theme.LightMode state
                                |> Theme.forState

                        darkTheme : Theme
                        darkTheme =
                            Theme.selectPreference Theme.DarkMode state
                                |> Theme.forState
                    in
                    Expect.all
                        [ \_ -> lightTheme.mode |> Expect.equal Theme.Light
                        , \_ -> lightTheme.preference |> Expect.equal Theme.LightMode
                        , \_ -> darkTheme.mode |> Expect.equal Theme.Dark
                        , \_ -> darkTheme.preference |> Expect.equal Theme.DarkMode
                        ]
                        ()
            , fuzz2 Fuzz.bool
                preferenceFuzzer
                "an OS change follows only the System choice"
                (\systemPrefersDark preference ->
                    let
                        next : Theme.State
                        next =
                            Theme.fromFlags
                                (Theme.preferenceToString preference)
                                (not systemPrefersDark)
                                |> Theme.setSystemPrefersDark systemPrefersDark

                        theme : Theme
                        theme =
                            Theme.forState next
                    in
                    Expect.all
                        [ \_ -> theme.preference |> Expect.equal preference
                        , \_ ->
                            theme.mode
                                |> Expect.equal
                                    (expectedMode systemPrefersDark preference)
                        ]
                        ()
                )
            , fuzz manualPreferenceFuzzer
                "a manual choice ignores OS changes but remembers the latest scheme"
                (\preference ->
                    let
                        overridden : Theme.State
                        overridden =
                            Theme.fromFlags (Theme.preferenceToString preference) False
                                |> Theme.setSystemPrefersDark True

                        backToSystem : Theme.State
                        backToSystem =
                            Theme.selectPreference Theme.System overridden

                        overriddenTheme : Theme
                        overriddenTheme =
                            Theme.forState overridden

                        systemTheme : Theme
                        systemTheme =
                            Theme.forState backToSystem
                    in
                    Expect.all
                        [ \_ ->
                            overriddenTheme.mode
                                |> Expect.equal (expectedMode False preference)
                        , \_ -> overriddenTheme.preference |> Expect.equal preference
                        , \_ -> systemTheme.mode |> Expect.equal Theme.Dark
                        , \_ -> systemTheme.preference |> Expect.equal Theme.System
                        ]
                        ()
                )
            ]
        ]


expectedMode : Bool -> Theme.Preference -> Theme.Mode
expectedMode systemPrefersDark preference =
    case preference of
        Theme.System ->
            if systemPrefersDark then
                Theme.Dark

            else
                Theme.Light

        Theme.LightMode ->
            Theme.Light

        Theme.DarkMode ->
            Theme.Dark


preferenceFuzzer : Fuzzer Theme.Preference
preferenceFuzzer =
    Fuzz.oneOfValues [ Theme.System, Theme.LightMode, Theme.DarkMode ]


manualPreferenceFuzzer : Fuzzer Theme.Preference
manualPreferenceFuzzer =
    Fuzz.oneOfValues [ Theme.LightMode, Theme.DarkMode ]


decodeThemeClick : List String -> Maybe ()
decodeThemeClick ids =
    Decode.decodeValue
        (ThemeChoice.clickAwayDecoder ())
        (Encode.object [ ( "target", targetNode ids ) ])
        |> Result.toMaybe


decodeThemeFocusOut : List String -> Maybe ()
decodeThemeFocusOut ids =
    Decode.decodeValue
        (ThemeChoice.focusOutDecoder ())
        (Encode.object [ ( "relatedTarget", targetNode ids ) ])
        |> Result.toMaybe


targetNode : List String -> Encode.Value
targetNode ids =
    case ids of
        [] ->
            Encode.null

        id :: ancestors ->
            Encode.object
                [ ( "id", Encode.string id )
                , ( "parentElement", targetNode ancestors )
                ]
