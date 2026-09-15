module View.Product exposing
    ( foodHeader
    , foodNutrientsPer100g
    , macroDotGhost
    )

import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Element exposing (Element)
import Ui
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


foodHeader : Theme -> ProductDetail -> List (Maybe String) -> Element msg
foodHeader theme food extraMeta =
    let
        macroNutrients : List Nutrition.NutrientAmount
        macroNutrients =
            food.nutrients
                |> List.map
                    (\n -> { code = n.code, amount = n.amountPer100g, unit = n.unit })
    in
    Ui.card theme
        [ Ui.pageHeader theme
            { leading = Just (View.Nutrients.macroDot theme macroNutrients)
            , title = Typography.truncatedHeader theme food.name
            , subtitle =
                Just
                    (Ui.SubtitleMeta
                        { items = metaItems food extraMeta
                        , separator = " ⋅ "
                        }
                    )
            , actions = []
            }
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ macroDotGhost, Chip.chips theme food.categories ]
        ]


metaItems : ProductDetail -> List (Maybe String) -> List String
metaItems food extraItems =
    (food.brand :: extraItems)
        |> List.filterMap identity


foodNutrientsPer100g : ProductDetail -> List Nutrition.NutrientAmount
foodNutrientsPer100g food =
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amount = nutrient.amountPer100g
            , unit = nutrient.unit
            }
        )
        food.nutrients


macroDotGhost : Element msg
macroDotGhost =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        ]
        Element.none
