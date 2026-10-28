module View.NutrientsTest exposing (tests)

{-| Laws for the generic fallback in `View.Nutrients.nutrientLabel` and for
`View.Nutrients.mapNutritionInput`.

The curated code-to-label table is data, so it is not asserted here. Rendered
DOM structure is not asserted either.

-}

import Data.Nutrition as Nutrition
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, fuzz3)
import Translations.Util as Util
import View.Nutrients as Nutrients exposing (NutritionInput, NutritionState(..))


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
            , fuzz generatedCode
                "every non-empty generated code gets a non-blank trimmed label"
              <|
                \code ->
                    let
                        label : String
                        label =
                            Nutrients.nutrientLabel Util.EN_US code
                    in
                    Expect.all
                        [ \_ -> String.isEmpty code |> Expect.equal False
                        , \_ -> String.isEmpty label |> Expect.equal False
                        , \_ -> String.trim label |> String.isEmpty |> Expect.equal False
                        ]
                        ()
            ]
        , describe "mapNutritionInput"
            [ fuzz3 nutritionState
                transform
                transform
                "mapping updates the input and preserves the constructor, identity, and composition"
              <|
                \state first second ->
                    Expect.all
                        [ \_ ->
                            Nutrients.mapNutritionInput first state
                                |> stateTag
                                |> Expect.equal (stateTag state)
                        , \_ ->
                            Nutrients.mapNutritionInput first state
                                |> Nutrients.nutritionInput
                                |> Expect.equal (first (Nutrients.nutritionInput state))
                        , \_ ->
                            Nutrients.mapNutritionInput identity state
                                |> Expect.equal state
                        , \_ ->
                            Nutrients.mapNutritionInput first
                                (Nutrients.mapNutritionInput second state)
                                |> Expect.equal
                                    (Nutrients.mapNutritionInput (first << second) state)
                        ]
                        ()
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


{-| Codes that tokenize into empty strings: underscore-only, leading/trailing
underscores, and empty tokens between separators. Every generated code is still
non-empty.
-}
pathologicalCode : Fuzzer String
pathologicalCode =
    Fuzz.oneOf
        [ Fuzz.oneOfValues
            [ "_"
            , "__"
            , "___"
            , "_ALPHA"
            , "ALPHA_"
            , "_ALPHA_"
            , "ALPHA__MG"
            , "__MG__"
            ]
        , Fuzz.map2 (::)
            (Fuzz.oneOfValues [ "_", "__", "ALPHA", "_ALPHA", "ALPHA_", "MG", "_MG" ])
            (Fuzz.listOfLengthBetween 0
                4
                (Fuzz.oneOfValues [ "", "_", "__", "ALPHA", "BETA", "MG" ])
            )
            |> Fuzz.map (String.join "_")
        ]


generatedCode : Fuzzer String
generatedCode =
    Fuzz.oneOf
        [ Fuzz.map .code unitCode
        , Fuzz.map .code plainCode
        , pathologicalCode
        ]


titleCase : String -> String
titleCase word =
    case String.uncons word of
        Just ( head, rest ) ->
            String.fromChar (Char.toUpper head) ++ String.toLower rest

        Nothing ->
            word


type alias Transform =
    NutritionInput -> NutritionInput


transforms : List Transform
transforms =
    [ identity
    , \input -> { input | amount = "42" }
    , \input -> { input | unit = "mg" }
    , \input -> { input | unitOpen = not input.unitOpen }
    , \input -> { input | amount = input.amount ++ "0", unit = input.unit ++ "-x" }
    ]


transform : Fuzzer Transform
transform =
    Fuzz.oneOfValues transforms


nutritionInput : Fuzzer NutritionInput
nutritionInput =
    Fuzz.map3 NutritionInput Fuzz.string Fuzz.string Fuzz.bool


nutrientAmount : Fuzzer Nutrition.NutrientAmount
nutrientAmount =
    Fuzz.map3
        (\code amount unit -> { code = code, amount = amount, unit = unit })
        Fuzz.string
        Fuzz.string
        Fuzz.string


nutritionState : Fuzzer NutritionState
nutritionState =
    Fuzz.oneOf
        [ Fuzz.map NutritionLoading nutritionInput
        , Fuzz.map2 NutritionLoaded nutritionInput (Fuzz.list nutrientAmount)
        , Fuzz.map2 NutritionFailed nutritionInput Fuzz.string
        , Fuzz.map NutritionUnavailable nutritionInput
        ]


stateTag : NutritionState -> String
stateTag state =
    case state of
        NutritionLoading _ ->
            "Loading"

        NutritionLoaded _ _ ->
            "Loaded"

        NutritionFailed _ _ ->
            "Failed"

        NutritionUnavailable _ ->
            "Unavailable"
