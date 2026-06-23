module View.Product exposing
    ( foodHeader
    , foodNutrientsPer100g
    )

import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Element exposing (Element)
import Ui
import Ui.Theme exposing (Theme)
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
            , title = Ui.truncatedHeader theme food.name
            , subtitle = Just (metaText food extraMeta)
            , actions = []
            }
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.macroDotGhost, Ui.chips theme food.categories ]
        ]


metaText : ProductDetail -> List (Maybe String) -> String
metaText food extraItems =
    [ food.brand
    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
    ]
        ++ extraItems
        |> Ui.dotSeparated


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
