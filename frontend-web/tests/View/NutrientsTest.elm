module View.NutrientsTest exposing (tests)

{-| Laws for the generic fallback in `View.Nutrients.nutrientLabel`.

The curated code-to-label table is data, so it is not asserted here. Rendered
DOM structure is not asserted either.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz)
import Translations.Util as Util
import View.Nutrients as Nutrients


tests : Test
tests =
    describe "View.Nutrients"
        [ describe "nutrientLabel generic fallback"
            [ fuzz unitCode "a recognized unit suffix becomes a canonical parenthesized unit" <|
                \generated ->
                    Nutrients.nutrientLabel Util.EN_US generated.code
                        |> Expect.equal generated.label
            , fuzz plainCode "a code without a recognized unit becomes title-cased words" <|
                \generated ->
                    Nutrients.nutrientLabel Util.EN_US generated.code
                        |> Expect.equal generated.label
            ]
        ]


type alias GeneratedCode =
    { code : String
    , label : String
    }


{-| Words that can never start a curated nutrient code, so every generated code
reaches the generic fallback. None of them is a unit token either.
-}
safeWords : List String
safeWords =
    [ "alpha"
    , "Beta"
    , "GAMMA"
    , "mystery"
    , "custom"
    , "riboflavin"
    , "lycopene"
    , "boron"
    , "selenium"
    , "copper"
    , "manganese"
    , "chromium"
    , "iodine"
    , "niacin"
    , "biotin"
    , "choline"
    ]


nameTokens : Fuzzer (List String)
nameTokens =
    Fuzz.map2 (::)
        (Fuzz.oneOfValues safeWords)
        (Fuzz.list (Fuzz.oneOfValues safeWords))


{-| Case-insensitive spellings of the recognized unit suffixes.
-}
unitToken : Fuzzer ( String, String )
unitToken =
    Fuzz.oneOfValues
        [ ( "G", "g" )
        , ( "g", "g" )
        , ( "MG", "mg" )
        , ( "mg", "mg" )
        , ( "Mg", "mg" )
        , ( "UG", "ug" )
        , ( "ug", "ug" )
        , ( "Ug", "ug" )
        , ( "KCAL", "kcal" )
        , ( "kcal", "kcal" )
        , ( "Kcal", "kcal" )
        , ( "kCal", "kcal" )
        ]


unitCode : Fuzzer GeneratedCode
unitCode =
    Fuzz.map2
        (\tokens ( rawUnit, canonicalUnit ) ->
            let
                rendered : String
                rendered =
                    if List.isEmpty tokens then
                        rawUnit

                    else
                        String.join " " (List.map titleCase tokens)
            in
            { code = String.join "_" (tokens ++ [ rawUnit ])
            , label = rendered ++ " (" ++ canonicalUnit ++ ")"
            }
        )
        (Fuzz.list (Fuzz.oneOfValues safeWords))
        unitToken


plainCode : Fuzzer GeneratedCode
plainCode =
    Fuzz.map
        (\tokens ->
            { code = String.join "_" tokens
            , label = String.join " " (List.map titleCase tokens)
            }
        )
        nameTokens


titleCase : String -> String
titleCase word =
    case String.uncons word of
        Just ( head, rest ) ->
            String.fromChar (Char.toUpper head) ++ String.toLower rest

        Nothing ->
            word
