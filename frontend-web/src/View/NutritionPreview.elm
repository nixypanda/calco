module View.NutritionPreview exposing (view)

import Data.Nutrition exposing (NutrientAmount)
import Element exposing (Element)
import Ui
import View.Nutrients


view :
    { loading : Bool
    , error : Maybe String
    , nutrients : Maybe (List NutrientAmount)
    }
    -> Element msg
view config =
    Element.column [ Element.width Element.fill, Element.spacing 8 ]
        [ if config.loading then
            Ui.loading "Loading nutrition..."

          else
            Element.none
        , case config.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case config.nutrients of
            Just nutrients ->
                Element.column [ Element.width Element.fill, Element.spacing 8 ]
                    [ Ui.card
                        [ Ui.sectionHeader "Macro Breakdown"
                        , View.Nutrients.macroBreakdownView nutrients
                        ]
                    , View.Nutrients.nutrientsTable nutrients
                    ]

            Nothing ->
                Element.none
        ]
