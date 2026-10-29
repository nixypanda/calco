module Page.FoodLog.ReviewStory exposing
    ( catalog
    , day
    , fillNutrients
    , gram
    , serving
    , units
    )

{-| Projections and fixtures shared by the two review screens
(`Page.FoodLog.CreateAdHoc` and its AI wrapper).
-}

import Api.Foods exposing (NutrientItem, UnitItem)
import Component.FoodEditor as Editor
import Lib.Date exposing (LocalDate)
import Page.FoodLog.CreateAdHoc as Review
import Support.Fixtures as Fixtures


day : LocalDate
day =
    Fixtures.date "2026-09-14"


catalog : List NutrientItem
catalog =
    [ nutrient "ENERGY_KCAL" "Calories" "kcal"
    , nutrient "PROTEIN_G" "Protein" "g"
    , nutrient "CARBS_G" "Carbohydrates" "g"
    , nutrient "FAT_G" "Fat" "g"
    , nutrient "FIBER_G" "Fiber" "g"
    ]


nutrient : String -> String -> String -> NutrientItem
nutrient code name unit =
    { code = code, name = name, unit = unit, category = "Core" }


units : List UnitItem
units =
    [ gram, serving ]


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


serving : UnitItem
serving =
    { code = "serving", name = "Serving", kind = "serving" }


fillNutrients : List Review.Msg
fillNutrients =
    [ Review.FormMsg (Editor.NutrientAmountChanged 0 "520")
    , Review.FormMsg (Editor.NutrientAmountChanged 1 "24")
    , Review.FormMsg (Editor.NutrientAmountChanged 2 "48")
    , Review.FormMsg (Editor.NutrientAmountChanged 3 "25")
    ]
