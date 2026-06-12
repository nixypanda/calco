module View.Nutrients exposing
    ( NutritionInput
    , NutritionState(..)
    , defaultNutritionInput
    , macroDot
    , mapNutritionInput
    , nutrientLabel
    , nutritionCard
    , nutritionInput
    , preview
    )

import Data.Nutrition as Nutrition exposing (NutrientAmount, defaultCode)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Lib.Number as Number
import Ui
import Ui.Theme exposing (Theme)


type alias NutritionInput =
    { amount : String
    , unit : String
    , unitOpen : Bool
    }


type NutritionState
    = NutritionLoading NutritionInput
    | NutritionLoaded NutritionInput (List NutrientAmount)
    | NutritionFailed NutritionInput String
    | NutritionUnavailable NutritionInput


defaultNutritionInput : NutritionInput
defaultNutritionInput =
    { amount = "100", unit = defaultCode, unitOpen = False }


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


macroDot : List NutrientAmount -> Element msg
macroDot nutrients =
    case nutrients |> Nutrition.dominantMacro |> Maybe.map Ui.macroColor of
        Just c ->
            Ui.accentDot c

        Nothing ->
            Ui.accentDot Ui.primaryTeal


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


skeletonPreview : Theme -> Element msg
skeletonPreview theme =
    Ui.section theme
        { header = Just (Ui.skeletonBar theme)
        , body =
            [ Ui.skeletonBar theme
            , Ui.hairline theme
            , Ui.skeletonBar theme
            , Ui.skeletonBar theme
            , Ui.skeletonBar theme
            ]
        , footer = Nothing
        }


preview : Theme -> Device -> NutritionState -> Element msg
preview theme device state =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space8 ]
        [ case state of
            NutritionLoading _ ->
                skeletonPreview theme

            NutritionLoaded _ nutrients ->
                nutritionCard theme device nutrients

            NutritionFailed _ errMsg ->
                Ui.errorBanner theme errMsg

            NutritionUnavailable _ ->
                Ui.errorBanner theme "Unavailable"
        ]


nutritionInput : NutritionState -> NutritionInput
nutritionInput state =
    case state of
        NutritionLoading input ->
            input

        NutritionLoaded input _ ->
            input

        NutritionFailed input _ ->
            input

        NutritionUnavailable input ->
            input


mapNutritionInput :
    (NutritionInput -> NutritionInput)
    -> NutritionState
    -> NutritionState
mapNutritionInput transform state =
    let
        input : NutritionInput
        input =
            transform (nutritionInput state)
    in
    case state of
        NutritionLoading _ ->
            NutritionLoading input

        NutritionLoaded _ nutrients ->
            NutritionLoaded input nutrients

        NutritionFailed _ message ->
            NutritionFailed input message

        NutritionUnavailable _ ->
            NutritionUnavailable input


macroBreakdownView : Theme -> Device -> List NutrientAmount -> Element msg
macroBreakdownView theme device nutrients =
    let
        portions : MacroPortions
        portions =
            macroPortions nutrients
    in
    Element.column [ Element.width Element.fill, Element.spacing Ui.space8 ]
        [ macroBarRow theme 24 portions
        , if Ui.isSmall device then
            Element.none

          else
            macroLegend portions
        ]


type alias MacroPortions =
    { protein : Float
    , carbs : Float
    , fat : Float
    , proteinPct : Int
    , carbsPct : Int
    , fatPct : Int
    }


macroPortions : List NutrientAmount -> MacroPortions
macroPortions nutrients =
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
    { protein = totals.protein
    , carbs = totals.carbs
    , fat = totals.fat
    , proteinPct = pProtein
    , carbsPct = pCarbs
    , fatPct = pFat
    }


macroBarRow : Theme -> Int -> MacroPortions -> Element msg
macroBarRow theme height portions =
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px height)
        , Background.color theme.divider
        , Border.rounded 999
        , Element.clip
        ]
        [ barSegment Ui.proteinColor portions.proteinPct
        , barSegment Ui.carbsColor portions.carbsPct
        , barSegment Ui.fatColor portions.fatPct
        ]


barSegment : Element.Color -> Int -> Element msg
barSegment color pct =
    Element.el
        [ Element.width (Element.fillPortion pct)
        , Element.height Element.fill
        , Background.color color
        ]
        Element.none


macroLegend : MacroPortions -> Element msg
macroLegend portions =
    Element.row
        [ Element.width Element.fill, Element.spacing Ui.space16 ]
        [ Element.row [ Element.spacing Ui.space4 ]
            [ legendDot Ui.proteinColor
            , Element.el [ Ui.body ]
                (Element.text ("Protein " ++ Number.toFixedOne portions.protein ++ "g"))
            ]
        , Element.row [ Element.spacing Ui.space4 ]
            [ legendDot Ui.carbsColor
            , Element.el [ Ui.body ]
                (Element.text ("Carbs " ++ Number.toFixedOne portions.carbs ++ "g"))
            ]
        , Element.row [ Element.spacing Ui.space4 ]
            [ legendDot Ui.fatColor
            , Element.el [ Ui.body ]
                (Element.text ("Fat " ++ Number.toFixedOne portions.fat ++ "g"))
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


{-| The bare nutrient table (no card wrapper), used by `nutritionCard`
to compose macro breakdown + table inside a single shared card.
-}
nutrientsTableInner : Theme -> List NutrientAmount -> Element msg
nutrientsTableInner theme nutrients =
    Element.table [ Element.width Element.fill ]
        { data = nutrients
        , columns =
            [ { header =
                    Element.el [ Element.paddingXY 0 Ui.space8 ]
                        (Ui.tableHeader theme "Nutrient")
              , width = Element.fill
              , view =
                    \n ->
                        Element.el
                            [ Ui.body, Element.paddingXY 0 Ui.space8 ]
                            (Element.text (nutrientLabel n.code))
              }
            , { header =
                    Element.el
                        [ Font.alignRight
                        , Element.paddingEach { top = 8, bottom = 8, left = 0, right = 8 }
                        ]
                        (Ui.tableHeader theme "Amount")
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
                        [ Element.paddingEach { top = 8, bottom = 8, left = 0, right = 0 } ]
                        (Ui.tableHeader theme "Unit")
              , width = Element.shrink
              , view =
                    \n ->
                        Element.el
                            [ Ui.body, Element.paddingXY 0 Ui.space8 ]
                            (Element.text n.unit)
              }
            ]
        }


{-| Combined "Nutrition" card: macro breakdown across the top, a hairline,
then the full nutrients table below — all inside a single card. Replaces
the prior pattern of two stacked cards.
-}
nutritionCard : Theme -> Device -> List NutrientAmount -> Element msg
nutritionCard theme device nutrients =
    Ui.section theme
        { header = Just (Ui.subsectionTitle theme device "Nutrition")
        , body =
            [ macroBreakdownView theme device nutrients
            , Ui.hairline theme
            , nutrientsTableInner theme nutrients
            ]
        , footer = Nothing
        }


formatAmount : String -> String
formatAmount raw =
    case String.toFloat raw of
        Just value ->
            Number.toFixedTrimmed 3 value

        Nothing ->
            raw
