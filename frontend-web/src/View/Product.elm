module View.Product exposing
    ( foodCategories
    , foodHeader
    , foodHeaderElement
    , foodNutrientsPer100g
    , macroDotGhost
    )

import Data.Food exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Element exposing (Element)
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


{-| The food identity as its own titled section, for pages where it stands alone.
-}
foodHeader : Env -> ProductDetail -> List (Maybe String) -> Element msg
foodHeader env food extraMeta =
    Surface.section env.theme
        { header = Just (foodHeaderElement env food extraMeta)
        , body = foodCategories env.theme food
        , footer = Nothing
        }


{-| The food name, macros, and brand/meta row, without a surface. Pages that
merge the header into a larger panel use this as the panel header.
-}
foodHeaderElement : Env -> ProductDetail -> List (Maybe String) -> Element msg
foodHeaderElement env food extraMeta =
    let
        macroNutrients : List Nutrition.NutrientAmount
        macroNutrients =
            food.nutrients
                |> List.map
                    (\n -> { code = n.code, amount = n.amountPer100g, unit = n.unit })
    in
    UiPage.pageHeader env.theme
        { leading = Just (View.Nutrients.macroDot env macroNutrients)
        , title = Typography.truncatedHeader env.theme food.name
        , subtitle =
            Just (UiPage.SubtitleMeta { items = metaItems food extraMeta, separator = " ⋅ " })
        , actions = []
        }


{-| Category chips as a panel section body, empty when the food has no tags.
-}
foodCategories : Theme -> ProductDetail -> List (Element msg)
foodCategories theme food =
    if List.isEmpty food.categories then
        []

    else
        [ Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ macroDotGhost, Chip.chips theme food.categories ]
        ]


metaItems : ProductDetail -> List (Maybe String) -> List String
metaItems food extraItems =
    (food.brand :: extraItems) |> List.filterMap identity


foodNutrientsPer100g : ProductDetail -> List Nutrition.NutrientAmount
foodNutrientsPer100g food =
    List.map
        (\nutrient ->
            { code = nutrient.code, amount = nutrient.amountPer100g, unit = nutrient.unit }
        )
        food.nutrients


macroDotGhost : Element msg
macroDotGhost =
    Element.el [ Element.width (Element.px 4), Element.height (Element.px 24) ] Element.none
