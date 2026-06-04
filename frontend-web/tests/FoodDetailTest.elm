module FoodDetailTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Page.FoodDetail as FoodDetail
import Page.FoodLogForm as FoodLogForm
import Route exposing (Route(..))
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodDetail"
        [ test "init requests food detail and units" <|
            \_ ->
                FoodDetail.init "food-1" (Just Lunch)
                    |> Tuple.second
                    |> Expect.equal (FoodDetail.RequestInitialData "food-1")
        , test "food load success initializes the log form" <|
            \_ ->
                FoodDetail.update (FoodDetail.FoodLoaded (Ok food)) emptyModel
                    |> first
                    |> .form
                    |> Maybe.map (\current -> ( current.amount, current.unit, current.mealSlot ))
                    |> Expect.equal (Just ( "2", "serving", Just Lunch ))
        , test "units load success stores units" <|
            \_ ->
                FoodDetail.update (FoodDetail.UnitsLoaded (Ok { items = [ gram ] })) emptyModel
                    |> first
                    |> .units
                    |> Expect.equal (Just [ gram ])
        , test "custom food source USER exposes edit path" <|
            \_ ->
                FoodDetail.customFoodEditRoute { food | source = "USER" }
                    |> Expect.equal (Just (CustomFoodEdit "food-1"))
        , test "global food sources do not expose edit path" <|
            \_ ->
                FoodDetail.customFoodEditRoute { food | source = "USDA" }
                    |> Expect.equal Nothing
        , test "submit requests local timestamp after validation" <|
            \_ ->
                FoodDetail.update FoodDetail.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal FoodDetail.RequestLocalTimestamp
        , test "local timestamp creates log request" <|
            \_ ->
                FoodDetail.update (FoodDetail.LocalTimestampReceived "2026-06-04T10:00:00+05:30") loadedModel
                    |> third
                    |> Expect.equal
                        (FoodDetail.RequestCreateLog
                            { loggedAt = "2026-06-04T10:00:00+05:30"
                            , mealSlot = Just "lunch"
                            , item = { itemType = "product", id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "log success navigates home" <|
            \_ ->
                FoodDetail.update (FoodDetail.LogCompleted (Ok log)) loadedModel
                    |> third
                    |> Expect.equal (FoodDetail.Navigate (Diary Nothing))
        , test "log failure keeps form state and stores error" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodDetail.update (FoodDetail.LogCompleted (Err Client.NetworkError)) { loadedModel | form = Just { form | submitting = True } }
                in
                ( Maybe.map (\current -> ( current.amount, current.submitting )) model.form, model.error )
                    |> Expect.equal ( Just ( "2", False ), Just "Network error" )
        ]


emptyModel : FoodDetail.Model
emptyModel =
    { productId = "food-1"
    , mealSlot = Just Lunch
    , food = Nothing
    , units = Nothing
    , form = Nothing
    , error = Nothing
    }


loadedModel : FoodDetail.Model
loadedModel =
    { emptyModel
        | food = Just food
        , units = Just [ gram ]
        , form = Just form
    }


form : FoodLogForm.Model
form =
    FoodLogForm.initLogFormFromFood (Just Lunch) food


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , defaultQuantity = Just "2"
    , defaultUnit = Just "serving"
    , servingSizeG = Just "100"
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


log : FoodLog
log =
    { id = "log-1"
    , loggedAt = "2026-06-04T10:00:00+05:30"
    , mealSlot = Just "lunch"
    , item = { itemType = "product", id = "food-1" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
