module Page.CustomFood.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (NutrientItem, ProductDetail, UnitItem)
import Component.FoodEditor as Form
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Edit as CustomFoodEdit
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Edit"
        [ test "a user edits a food and saves it" <|
            \_ ->
                editedFood
                    |> step CustomFoodEdit.SubmitClicked
                    |> step (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                    |> finish
                        (\( saved, completionOut ) ->
                            { screen = toScreen saved
                            , finalOut = completionOut
                            }
                                |> Expect.equal
                                    { screen =
                                        { name = "Paneer"
                                        , categories = [ "dairy" ]
                                        , nutrients = []
                                        , unitOptions = [ "g" ]
                                        , error = Nothing
                                        }
                                    , finalOut =
                                        CustomFoodEdit.Navigate (CustomFoodShow "food-1")
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                loadedFood
                    |> step CustomFoodEdit.SubmitClicked
                    |> step
                        (CustomFoodEdit.SaveCompleted (Err Client.NetworkError))
                    |> step CustomFoodEdit.SubmitClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { request = updateRequest outMsg
                            , disabled = isSubmitting model
                            }
                                |> Expect.equal
                                    { request = Just curdRequest
                                    , disabled = True
                                    }
                        )
        , test "a failed load can be retried" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Story.start
                    |> step
                        (CustomFoodEdit.FoodLoaded "food-1" (Err Client.NetworkError))
                    |> step CustomFoodEdit.RetryClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (CustomFoodEdit.RequestInitialData "food-1")
                        )
        ]


type alias Screen =
    { name : String
    , categories : List String
    , nutrients : List String
    , unitOptions : List String
    , error : Maybe String
    }


toScreen : CustomFoodEdit.Model -> Screen
toScreen model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            { name = loaded.form.name
            , categories = loaded.form.categoryInput.selected
            , nutrients = List.filterMap nutrientRow loaded.form.nutrients
            , unitOptions = List.map .code loaded.units
            , error = submitError loaded.form.submit
            }

        CustomFoodEdit.LoadFailed failed ->
            { name = ""
            , categories = []
            , nutrients = []
            , unitOptions = []
            , error = Just failed.message
            }

        CustomFoodEdit.Loading _ ->
            { name = ""
            , categories = []
            , nutrients = []
            , unitOptions = []
            , error = Nothing
            }


nutrientRow : Form.NutrientRow -> Maybe String
nutrientRow row =
    if String.isEmpty row.code && String.isEmpty row.amount then
        Nothing

    else
        Just (row.code ++ ":" ++ row.amount)


submitError : Form.SubmitState -> Maybe String
submitError state =
    case state of
        Form.SubmitFailed message ->
            Just message

        _ ->
            Nothing


isSubmitting : CustomFoodEdit.Model -> Bool
isSubmitting model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            Form.isSubmitting loaded.form.submit

        _ ->
            False


updateRequest : CustomFoodEdit.OutMsg -> Maybe Api.Foods.CreateFoodRequest
updateRequest outMsg =
    case outMsg of
        CustomFoodEdit.RequestUpdateFood "food-1" request ->
            Just request

        _ ->
            Nothing



-- STORY PIPELINE


type alias Journey =
    Story.Journey CustomFoodEdit.Model CustomFoodEdit.OutMsg


step : CustomFoodEdit.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CustomFoodEdit.update)


finish :
    (( CustomFoodEdit.Model, CustomFoodEdit.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedFood : Journey
loadedFood =
    CustomFoodEdit.init "food-1"
        |> Story.start
        |> step (CustomFoodEdit.FoodLoaded "food-1" (Ok food))
        |> step (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
        |> step (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))


editedFood : Journey
editedFood =
    loadedFood
        |> step (CustomFoodEdit.FormMsg (Form.NameChanged "Paneer"))


curdRequest : Api.Foods.CreateFoodRequest
curdRequest =
    { name = "Curd"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "cup"
    , nutrients = []
    , servings = [ { unit = "cup", gramsPerUnit = 240 } ]
    }


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Curd"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "cup"
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = [ { unit = "cup", gramsPerUnit = "240" } ]
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" }
    , { code = "ENERGY_KCAL", name = "Energy", unit = "kcal", category = "energy" }
    ]
