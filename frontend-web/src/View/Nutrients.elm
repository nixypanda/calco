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
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import I18n
import Lib.Number as Number
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


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
nutrientLabel : Language -> String -> String
nutrientLabel language code =
    case code of
        "ENERGY_KCAL" ->
            I18n.t language TidNutrientEnergy

        "PROTEIN_G" ->
            I18n.t language TidNutrientProtein

        "CARBS_G" ->
            I18n.t language TidNutrientCarbohydrates

        "FAT_G" ->
            I18n.t language TidNutrientFat

        "SATURATED_FAT_G" ->
            I18n.t language TidNutrientSaturatedFat

        "MONOUNSATURATED_FAT_G" ->
            I18n.t language TidNutrientMonounsaturatedFat

        "POLYUNSATURATED_FAT_G" ->
            I18n.t language TidNutrientPolyunsaturatedFat

        "TRANS_FAT_G" ->
            I18n.t language TidNutrientTransFat

        "FIBER_G" ->
            I18n.t language TidNutrientFiber

        "SUGAR_G" ->
            I18n.t language TidNutrientSugar

        "ADDED_SUGAR_G" ->
            I18n.t language TidNutrientAddedSugars

        "STARCH_G" ->
            I18n.t language TidNutrientStarch

        "SODIUM_MG" ->
            I18n.t language TidNutrientSodium

        "CHOLESTEROL_MG" ->
            I18n.t language TidNutrientCholesterol

        "POTASSIUM_MG" ->
            I18n.t language TidNutrientPotassium

        "CALCIUM_MG" ->
            I18n.t language TidNutrientCalcium

        "IRON_MG" ->
            I18n.t language TidNutrientIron

        "MAGNESIUM_MG" ->
            I18n.t language TidNutrientMagnesium

        "ZINC_MG" ->
            I18n.t language TidNutrientZinc

        "PHOSPHORUS_MG" ->
            I18n.t language TidNutrientPhosphorus

        "VITAMIN_A_UG" ->
            I18n.t language TidNutrientVitaminA

        "VITAMIN_C_MG" ->
            I18n.t language TidNutrientVitaminC

        "VITAMIN_D_UG" ->
            I18n.t language TidNutrientVitaminD

        "VITAMIN_E_MG" ->
            I18n.t language TidNutrientVitaminE

        "VITAMIN_B6_MG" ->
            I18n.t language TidNutrientVitaminB6

        "VITAMIN_B12_UG" ->
            I18n.t language TidNutrientVitaminB12

        "FOLATE_UG" ->
            I18n.t language TidNutrientFolate

        _ ->
            genericNutrientLabel code


macroDot : Theme -> Language -> List NutrientAmount -> Element msg
macroDot theme language nutrients =
    let
        dominant : Maybe Nutrition.Macro
        dominant =
            Nutrition.dominantMacro nutrients
    in
    Surface.accentDotLabeled
        { color =
            dominant
                |> Maybe.map (macroColor theme)
                |> Maybe.withDefault theme.calorieAccent
        , label =
            dominant
                |> Maybe.map (macroLabel language)
                |> Maybe.withDefault (I18n.t language TidNutrientNutrition)
        }


macroLabel : Language -> Nutrition.Macro -> String
macroLabel language macro =
    case macro of
        Nutrition.Protein ->
            I18n.t language TidNutrientProteinRich

        Nutrition.Carbs ->
            I18n.t language TidNutrientCarbRich

        Nutrition.Fat ->
            I18n.t language TidNutrientFatRich


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
    Surface.section theme
        { header = Just (Skeleton.bar theme)
        , body =
            [ Skeleton.bar theme
            , Surface.hairline theme
            , Skeleton.bar theme
            , Skeleton.bar theme
            , Skeleton.bar theme
            ]
        , footer = Nothing
        }


preview : Element.Device -> Theme -> Language -> NutritionState -> Element msg
preview device theme language state =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ case state of
            NutritionLoading _ ->
                skeletonPreview theme

            NutritionLoaded _ nutrients ->
                nutritionCard device theme language nutrients

            NutritionFailed _ errMsg ->
                Feedback.errorBanner theme errMsg

            NutritionUnavailable _ ->
                Feedback.errorBanner theme (I18n.t language TidNutrientUnavailable)
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


macroBreakdownView : Element.Device -> Theme -> Language -> List NutrientAmount -> Element msg
macroBreakdownView device theme language nutrients =
    macroBreakdownViewWithLegend (responsiveMacroLegend device theme language) theme nutrients


macroBreakdownViewWithLegend :
    (MacroPortions -> Element msg)
    -> Theme
    -> List NutrientAmount
    -> Element msg
macroBreakdownViewWithLegend legend theme nutrients =
    let
        portions : MacroPortions
        portions =
            macroPortions nutrients
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ macroBarRow theme 24 portions
        , legend portions
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
        , Border.rounded DesignTokens.radiusPill
        , Element.clip
        ]
        [ barSegment theme.proteinAccent portions.proteinPct
        , barSegment theme.carbsAccent portions.carbsPct
        , barSegment theme.fatAccent portions.fatPct
        ]


barSegment : Element.Color -> Int -> Element msg
barSegment color pct =
    Element.el
        [ Element.width (Element.fillPortion pct)
        , Element.height Element.fill
        , Background.color color
        ]
        Element.none


macroLegend : Theme -> Language -> MacroPortions -> Element msg
macroLegend theme language portions =
    macroLegendItems theme language portions
        |> Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]


responsiveMacroLegend : Element.Device -> Theme -> Language -> MacroPortions -> Element msg
responsiveMacroLegend device theme language portions =
    if UiCommon.isSmall device then
        macroLegendItems theme language portions
            |> Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]

    else
        macroLegend theme language portions


macroLegendItems : Theme -> Language -> MacroPortions -> List (Element msg)
macroLegendItems theme language portions =
    [ Element.row [ Element.spacing DesignTokens.space4 ]
        [ legendDot theme.proteinAccent
        , Element.el [ Typography.body ]
            (Element.text
                (I18n.t language (TidNutrientLegendProtein (Number.toFixedOne portions.protein)))
            )
        ]
    , Element.row [ Element.spacing DesignTokens.space4 ]
        [ legendDot theme.carbsAccent
        , Element.el [ Typography.body ]
            (Element.text
                (I18n.t language (TidNutrientLegendCarbs (Number.toFixedOne portions.carbs)))
            )
        ]
    , Element.row [ Element.spacing DesignTokens.space4 ]
        [ legendDot theme.fatAccent
        , Element.el [ Typography.body ]
            (Element.text
                (I18n.t language (TidNutrientLegendFat (Number.toFixedOne portions.fat)))
            )
        ]
    ]


legendDot : Element.Color -> Element msg
legendDot color =
    Element.el
        [ Element.width (Element.px 10)
        , Element.height (Element.px 10)
        , Background.color color
        , Border.rounded DesignTokens.radiusPill
        ]
        Element.none


{-| The bare nutrient table (no card wrapper), used by `nutritionCard`
to compose macro breakdown + table inside a single shared card.
-}
nutrientsTableInner : Theme -> Language -> List NutrientAmount -> Element msg
nutrientsTableInner theme language nutrients =
    Element.table [ Element.width Element.fill ]
        { data = nutrients
        , columns =
            [ { header =
                    Element.el [ Element.paddingXY 0 DesignTokens.space8 ]
                        (Typography.tableHeader theme (I18n.t language TidNutrientTableNutrient))
              , width = Element.fill
              , view =
                    \n ->
                        Element.el
                            [ Typography.body, Element.paddingXY 0 DesignTokens.space8 ]
                            (Element.text (nutrientLabel language n.code))
              }
            , { header =
                    Element.el
                        [ Font.alignRight
                        , Element.paddingEach
                            { top = DesignTokens.space8
                            , bottom = DesignTokens.space8
                            , left = 0
                            , right = DesignTokens.space8
                            }
                        ]
                        (Typography.tableHeader theme (I18n.t language TidNutrientTableAmount))
              , width = Element.shrink
              , view =
                    \n ->
                        Element.el
                            [ Font.alignRight
                            , Element.paddingEach
                                { top = DesignTokens.space8
                                , bottom = DesignTokens.space8
                                , left = 0
                                , right = DesignTokens.space8
                                }
                            ]
                            (Typography.decimalNumber (formatAmount n.amount))
              }
            , { header =
                    Element.el
                        [ Element.paddingEach
                            { top = DesignTokens.space8
                            , bottom = DesignTokens.space8
                            , left = 0
                            , right = 0
                            }
                        ]
                        (Typography.tableHeader theme (I18n.t language TidNutrientTableUnit))
              , width = Element.shrink
              , view =
                    \n ->
                        Element.el
                            [ Typography.body, Element.paddingXY 0 DesignTokens.space8 ]
                            (Element.text n.unit)
              }
            ]
        }


{-| Combined "Nutrition" card: macro breakdown across the top, a hairline,
then the full nutrients table below — all inside a single card. Replaces
the prior pattern of two stacked cards.
-}
nutritionCard : Element.Device -> Theme -> Language -> List NutrientAmount -> Element msg
nutritionCard device theme language nutrients =
    Surface.section theme
        { header = Just (Typography.subsectionTitle theme (I18n.t language TidNutrientNutrition))
        , body =
            [ macroBreakdownView device theme language nutrients
            , Surface.hairline theme
            , nutrientsTableInner theme language nutrients
            ]
        , footer = Nothing
        }


macroColor : Theme -> Nutrition.Macro -> Element.Color
macroColor theme m =
    case m of
        Nutrition.Protein ->
            theme.proteinAccent

        Nutrition.Carbs ->
            theme.carbsAccent

        Nutrition.Fat ->
            theme.fatAccent


formatAmount : String -> String
formatAmount raw =
    case String.toFloat raw of
        Just value ->
            Number.toFixed 3 value

        Nothing ->
            raw
