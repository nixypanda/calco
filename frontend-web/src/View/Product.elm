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
import Translations.Util exposing (Language)
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


{-| The food identity as its own titled section, for pages where it stands alone.
-}
foodHeader : Theme -> Language -> ProductDetail -> List (Maybe String) -> Element msg
foodHeader theme language food extraMeta =
    Surface.section theme
        { header = Just (foodHeaderElement theme language food extraMeta)
        , body = foodCategories theme food
        , footer = Nothing
        }


{-| The food name, macros, and brand/meta row, without a surface. Pages that
merge the header into a larger panel use this as the panel header.
-}
foodHeaderElement : Theme -> Language -> ProductDetail -> List (Maybe String) -> Element msg
foodHeaderElement theme language food extraMeta =
    let
        macroNutrients : List Nutrition.NutrientAmount
        macroNutrients =
            food.nutrients
                |> List.map
                    (\n -> { code = n.code, amount = n.amountPer100g, unit = n.unit })
    in
    UiPage.pageHeader theme
        { leading = Just (View.Nutrients.macroDot theme language macroNutrients)
        , title = Typography.truncatedHeader theme food.name
        , subtitle =
            Just
                (UiPage.SubtitleMeta
                    { items = metaItems food extraMeta
                    , separator = " ⋅ "
                    }
                )
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
