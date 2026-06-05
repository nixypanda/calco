module FoodDetailTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Food.Detail as FoodDetail
import Test exposing (Test, describe, test)
import View.FoodLogForm as FoodLogForm


tests : Test
tests =
    describe "Page.Food.Detail"
        [ test "init requests food detail and units" <|
            \_ ->
                FoodDetail.init "food-1" (Just Lunch)
                    |> Tuple.second
                    |> Expect.equal (FoodDetail.RequestInitialData "food-1")
        , test "food load success initializes the log form" <|
            \_ ->
                FoodDetail.update (FoodDetail.FoodLoaded (Ok food)) emptyModel
                    |> first
                    |> FoodDetail.update (FoodDetail.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> formOf
                    |> Maybe.map (\current -> ( current.amount, current.unit, current.mealSlot ))
                    |> Expect.equal (Just ( "2", "serving", Just Lunch ))
        , test "units load success stores units" <|
            \_ ->
                FoodDetail.update (FoodDetail.UnitsLoaded (Ok { items = [ gram ] })) emptyModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ gram ])
        , test "custom food source USER exposes edit path" <|
            \_ ->
                FoodDetail.customFoodEditRoute { food | source = "USER" }
                    |> Expect.equal (Just (CustomFoodEdit "food-1"))
        , test "global food sources do not expose edit path" <|
            \_ ->
                FoodDetail.customFoodEditRoute { food | source = "USDA" }
                    |> Expect.equal Nothing
        , test "display nutrients follow the current form quantity" <|
            \_ ->
                FoodDetail.foodNutrientsForDisplay foodWithNutrition form
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "display nutrients fall back when serving conversion is unknown" <|
            \_ ->
                FoodDetail.foodNutrientsForDisplay
                    foodWithNutrition
                    { form | unit = "cup" }
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "submit requests local context after validation" <|
            \_ ->
                FoodDetail.update FoodDetail.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal FoodDetail.RequestLocalContext
        , test "local context creates log request" <|
            \_ ->
                FoodDetail.update
                    (FoodDetail.LocalContextReceived
                        { date = "2026-06-04"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    contextReadyModel
                    |> third
                    |> Expect.equal
                        (FoodDetail.RequestCreateLog
                            { logDate = sampleDate
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = "product", id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "local context with bad date reports a validation error" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        FoodDetail.update
                            (FoodDetail.LocalContextReceived
                                { date = "not-a-date"
                                , timezone = "Asia/Kolkata"
                                }
                            )
                            contextReadyModel

                    formError : Maybe String
                    formError =
                        formOf model
                            |> Maybe.andThen .error
                in
                ( outMsg
                , formError
                )
                    |> Expect.equal
                        ( FoodDetail.NoOp
                        , Just "Could not read device date."
                        )
        , test "log success navigates home" <|
            \_ ->
                FoodDetail.update (FoodDetail.LogCompleted (Ok log)) savingModel
                    |> third
                    |> Expect.equal (FoodDetail.Navigate (Diary Nothing))
        , test "log failure keeps form state and stores error" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodDetail.update
                            (FoodDetail.LogCompleted (Err Client.NetworkError))
                            savingModel
                in
                ( Maybe.map (\current -> ( current.amount, current.submitting )) (formOf model)
                , errorOf model
                )
                    |> Expect.equal ( Just ( "2", False ), Just "Network error" )
        ]


emptyModel : FoodDetail.Model
emptyModel =
    FoodDetail.Loading
        { productId = "food-1"
        , mealSlot = Just Lunch
        , food = Nothing
        , units = Nothing
        }


loadedModel : FoodDetail.Model
loadedModel =
    FoodDetail.Loaded
        { productId = "food-1"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodDetail.Idle
        }


contextReadyModel : FoodDetail.Model
contextReadyModel =
    FoodDetail.Loaded
        { productId = "food-1"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodDetail.RequestingLocalContext
        }


savingModel : FoodDetail.Model
savingModel =
    FoodDetail.Loaded
        { productId = "food-1"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = { form | submitting = True }
        , error = Nothing
        , request = FoodDetail.Saving
        }


formOf : FoodDetail.Model -> Maybe FoodLogForm.Model
formOf model =
    case model of
        FoodDetail.Loaded loaded ->
            Just loaded.form

        _ ->
            Nothing


unitsOf : FoodDetail.Model -> Maybe (List UnitItem)
unitsOf model =
    case model of
        FoodDetail.Loading loading ->
            loading.units

        FoodDetail.Loaded loaded ->
            Just loaded.units

        FoodDetail.LoadFailed _ ->
            Nothing


errorOf : FoodDetail.Model -> Maybe String
errorOf model =
    case model of
        FoodDetail.Loaded loaded ->
            loaded.error

        FoodDetail.LoadFailed message ->
            Just message

        FoodDetail.Loading _ ->
            Nothing


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


foodWithNutrition : ProductDetail
foodWithNutrition =
    { food
        | nutrients =
            [ { code = "ENERGY_KCAL"
              , amountPer100g = "120"
              , unit = "kcal"
              , source = Nothing
              , confidence = Nothing
              }
            ]
        , servings =
            [ { label = "Serving"
              , quantity = "1"
              , unit = "serving"
              , grams = "50"
              }
            ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


log : FoodLog
log =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just "lunch"
    , item = { itemType = "product", id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }


sampleDate : LocalDate
sampleDate =
    sampleDateFromString "2026-06-04"


sampleDateFromString : String -> LocalDate
sampleDateFromString raw =
    case LocalDate.fromString raw of
        Just d ->
            d

        Nothing ->
            todayFallback


todayFallback : LocalDate
todayFallback =
    case LocalDate.fromParts 1970 1 1 of
        Just d ->
            d

        Nothing ->
            -- Unreachable: 1970-01-01 is always valid.
            sampleDate


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
