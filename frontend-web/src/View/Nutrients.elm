module View.Nutrients exposing (macroBreakdownView, nutrientLabel, nutrientsTable)

import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Lib.Number as Number
import Ui


{-| Render a friendly name for a nutrient code. Known backend codes
(`ENERGY_KCAL`, `SATURATED_FAT_G`, etc.) are mapped explicitly. Unknown
codes are parsed generically: `RIBOFLAVIN_MG` becomes `"Riboflavin (mg)"`.

Codes that have no recognized unit suffix (e.g. a bare `MYSTERY`) fall
back to the raw code.

-}
nutrientLabel : String -> String
nutrientLabel code =
    case code of
        "ENERGY_KCAL" ->
            "Energy"

        "PROTEIN_G" ->
            "Protein"

        "CARBS_G" ->
            "Carbohydrates"

        "FAT_G" ->
            "Fat"

        "SATURATED_FAT_G" ->
            "Saturated Fat"

        "MONOUNSATURATED_FAT_G" ->
            "Monounsaturated Fat"

        "POLYUNSATURATED_FAT_G" ->
            "Polyunsaturated Fat"

        "TRANS_FAT_G" ->
            "Trans Fat"

        "FIBER_G" ->
            "Fiber"

        "SUGAR_G" ->
            "Sugar"

        "STARCH_G" ->
            "Starch"

        "SODIUM_MG" ->
            "Sodium"

        "CHOLESTEROL_MG" ->
            "Cholesterol"

        "POTASSIUM_MG" ->
            "Potassium"

        "CALCIUM_MG" ->
            "Calcium"

        "IRON_MG" ->
            "Iron"

        "MAGNESIUM_MG" ->
            "Magnesium"

        "ZINC_MG" ->
            "Zinc"

        "PHOSPHORUS_MG" ->
            "Phosphorus"

        "VITAMIN_A_UG" ->
            "Vitamin A"

        "VITAMIN_C_MG" ->
            "Vitamin C"

        "VITAMIN_D_UG" ->
            "Vitamin D"

        "VITAMIN_E_MG" ->
            "Vitamin E"

        "VITAMIN_B6_MG" ->
            "Vitamin B6"

        "VITAMIN_B12_UG" ->
            "Vitamin B12"

        "FOLATE_UG" ->
            "Folate"

        _ ->
            genericNutrientLabel code


{-| Parses arbitrary backend nutrient codes into readable labels.

Examples:

  - `RIBOFLAVIN_MG` → `"Riboflavin (mg)"`
  - `BETA_CAROTENE_UG` → `"Beta Carotene (ug)"`
  - `LYCOPENE_G` → `"Lycopene (g)"`
  - `MYSTERY` → `"MYSTERY"` (no recognized unit)

A recognized unit is the suffix token if it matches one of `G`, `MG`,
`UG`, or `KCAL` (case-insensitive).

-}
genericNutrientLabel : String -> String
genericNutrientLabel code =
    let
        tokens : List String
        tokens =
            String.split "_" code

        lastToken : Maybe String
        lastToken =
            tokens |> List.reverse |> List.head

        unit : Maybe String
        unit =
            lastToken
                |> Maybe.andThen
                    (\t ->
                        case String.toUpper t of
                            "G" ->
                                Just "g"

                            "MG" ->
                                Just "mg"

                            "UG" ->
                                Just "ug"

                            "KCAL" ->
                                Just "kcal"

                            _ ->
                                Nothing
                    )

        nameTokens : List String
        nameTokens =
            case unit of
                Just _ ->
                    tokens |> List.reverse |> List.drop 1 |> List.reverse

                Nothing ->
                    tokens
    in
    case ( unit, nameTokens ) of
        ( Nothing, [] ) ->
            code

        ( Just u, [] ) ->
            code ++ " (" ++ u ++ ")"

        ( Just u, words ) ->
            words
                |> List.map titleCase
                |> String.join " "
                |> (\rendered -> rendered ++ " (" ++ u ++ ")")

        ( Nothing, words ) ->
            words |> List.map titleCase |> String.join " "


titleCase : String -> String
titleCase word =
    case String.uncons word of
        Just ( head, rest ) ->
            String.fromChar (Char.toUpper head) ++ String.toLower rest

        Nothing ->
            word


macroBreakdownView : List NutrientAmount -> Element msg
macroBreakdownView nutrients =
    let
        totals : Nutrition.MacroTotals
        totals =
            Nutrition.macroTotals [ { nutrients = nutrients } ]

        pProtein : Int
        pProtein =
            round totals.proteinPct

        pCarbs : Int
        pCarbs =
            round totals.carbsPct

        pFat : Int
        pFat =
            if pProtein + pCarbs > 0 then
                max 0 (100 - pProtein - pCarbs)

            else
                round totals.fatPct
    in
    Element.column [ Element.width Element.fill, Element.spacing 8 ]
        [ Element.row
            [ Element.width Element.fill
            , Element.height (Element.px 24)
            , Background.color Ui.borderGray
            , Border.rounded 999
            , Element.clip
            ]
            [ Element.el
                [ Element.width (Element.fillPortion pProtein)
                , Element.height Element.fill
                , Background.color Ui.proteinColor
                ]
                Element.none
            , Element.el
                [ Element.width (Element.fillPortion pCarbs)
                , Element.height Element.fill
                , Background.color Ui.carbsColor
                ]
                Element.none
            , Element.el
                [ Element.width (Element.fillPortion pFat)
                , Element.height Element.fill
                , Background.color Ui.fatColor
                ]
                Element.none
            ]
        , Element.row
            [ Element.width Element.fill, Element.spacing 16 ]
            [ Element.row [ Element.spacing 4 ]
                [ legendDot Ui.proteinColor
                , Element.el [ Ui.body ]
                    (Element.text ("Protein " ++ Number.toFixedOne totals.protein ++ "g"))
                ]
            , Element.row [ Element.spacing 4 ]
                [ legendDot Ui.carbsColor
                , Element.el [ Ui.body ]
                    (Element.text ("Carbs " ++ Number.toFixedOne totals.carbs ++ "g"))
                ]
            , Element.row [ Element.spacing 4 ]
                [ legendDot Ui.fatColor
                , Element.el [ Ui.body ]
                    (Element.text ("Fat " ++ Number.toFixedOne totals.fat ++ "g"))
                ]
            ]
        ]


legendDot : Element.Color -> Element msg
legendDot color =
    Element.el
        [ Element.width (Element.px 10)
        , Element.height (Element.px 10)
        , Background.color color
        , Border.rounded 999
        ]
        Element.none


nutrientsTable : List NutrientAmount -> Element msg
nutrientsTable nutrients =
    Ui.card
        [ Element.table [ Element.width Element.fill ]
            { data = nutrients
            , columns =
                [ { header =
                        Element.el
                            [ Font.bold
                            , Ui.body
                            , Font.letterSpacing 0.5
                            , Font.color Ui.mutedColor
                            , Element.paddingXY 0 8
                            ]
                            (Element.text (String.toUpper "Nutrient"))
                  , width = Element.fill
                  , view =
                        \n ->
                            Element.el
                                [ Ui.body, Element.paddingXY 0 8 ]
                                (Element.text (nutrientLabel n.code))
                  }
                , { header =
                        Element.el
                            [ Font.bold
                            , Ui.body
                            , Font.letterSpacing 0.5
                            , Font.color Ui.mutedColor
                            , Font.alignRight
                            , Element.paddingEach { top = 8, bottom = 8, left = 0, right = 8 }
                            ]
                            (Element.text (String.toUpper "Amount"))
                  , width = Element.shrink
                  , view =
                        \n ->
                            Element.el
                                [ Ui.body
                                , Font.alignRight
                                , Element.paddingEach { top = 8, bottom = 8, left = 0, right = 8 }
                                ]
                                (Element.text (formatAmount n.amount))
                  }
                , { header =
                        Element.el
                            [ Font.bold
                            , Ui.body
                            , Font.letterSpacing 0.5
                            , Font.color Ui.mutedColor
                            , Element.paddingEach { top = 8, bottom = 8, left = 0, right = 0 }
                            ]
                            (Element.text (String.toUpper "Unit"))
                  , width = Element.shrink
                  , view =
                        \n ->
                            Element.el
                                [ Ui.body, Element.paddingXY 0 8 ]
                                (Element.text n.unit)
                  }
                ]
            }
        ]


formatAmount : String -> String
formatAmount raw =
    case String.toFloat raw of
        Just value ->
            Number.toFixedTrimmed 3 value

        Nothing ->
            raw
