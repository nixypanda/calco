module Page.Food.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Food.Show as FoodShow
import Page.FoodLog.Form as FoodLogForm
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Food.Show"
        [ test "init requests food detail and units" <|
            \_ ->
                FoodShow.init
                    "food-1"
                    (Just "2026-05-29")
                    (Just Lunch)
                    |> Tuple.second
                    |> Expect.equal (FoodShow.RequestInitialData "food-1")
        , test "food load success initializes the log form" <|
            \_ ->
                FoodShow.update (FoodShow.FoodLoaded (Ok food)) emptyModel
                    |> first
                    |> FoodShow.update (FoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> formOf
                    |> Maybe.map (\current -> ( current.amount, current.unit, current.mealSlot ))
                    |> Expect.equal (Just ( "2", "serving", Just Lunch ))
        , test "units load success stores units" <|
            \_ ->
                FoodShow.update (FoodShow.UnitsLoaded (Ok { items = [ gram ] })) emptyModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ gram ])
        , test "display nutrients follow the current form quantity" <|
            \_ ->
                FoodShow.foodNutrientsForDisplay foodWithNutrition form
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "display nutrients fall back when serving conversion is unknown" <|
            \_ ->
                FoodShow.foodNutrientsForDisplay
                    foodWithNutrition
                    { form | unit = "cup" }
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "submit requests local context after validation" <|
            \_ ->
                FoodShow.update FoodShow.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal FoodShow.RequestLocalContext
        , test "local context uses selected diary date for log request" <|
            \_ ->
                FoodShow.update
                    (FoodShow.LocalContextReceived
                        { date = "2026-06-04"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    contextReadyModel
                    |> third
                    |> Expect.equal
                        (FoodShow.RequestCreateLog
                            { logDate = sampleDate
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "local context without selected diary date falls back to device date" <|
            \_ ->
                FoodShow.update
                    (FoodShow.LocalContextReceived
                        { date = "2026-06-04"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    contextReadyWithoutDateModel
                    |> third
                    |> Expect.equal
                        (FoodShow.RequestCreateLog
                            { logDate = date "2026-06-04"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "bad device date fails when no diary date is selected" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        FoodShow.update
                            (FoodShow.LocalContextReceived
                                { date = "not-a-date"
                                , timezone = "Asia/Kolkata"
                                }
                            )
                            contextReadyWithoutDateModel

                    formError : Maybe String
                    formError =
                        formOf model
                            |> Maybe.andThen .error
                in
                ( outMsg
                , formError
                )
                    |> Expect.equal
                        ( FoodShow.NoOp
                        , Just "Could not read device date."
                        )
        , test "log success navigates back to selected diary day" <|
            \_ ->
                FoodShow.update (FoodShow.LogCompleted (Ok log)) savingModel
                    |> third
                    |> Expect.equal (FoodShow.Navigate (DiaryDay (Just "2026-05-29")))
        , test "log failure keeps form state and stores error" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodShow.update
                            (FoodShow.LogCompleted (Err Client.NetworkError))
                            savingModel
                in
                ( Maybe.map (\current -> ( current.amount, current.submitting )) (formOf model)
                , errorOf model
                )
                    |> Expect.equal ( Just ( "2", False ), Just "Network error" )
        ]


emptyModel : FoodShow.Model
emptyModel =
    FoodShow.Loading
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = Nothing
        , units = Nothing
        }


loadedModel : FoodShow.Model
loadedModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodShow.Idle
        }


contextReadyModel : FoodShow.Model
contextReadyModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodShow.RequestingLocalContext
        }


contextReadyWithoutDateModel : FoodShow.Model
contextReadyWithoutDateModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Nothing
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodShow.RequestingLocalContext
        }


savingModel : FoodShow.Model
savingModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = { form | submitting = True }
        , error = Nothing
        , request = FoodShow.Saving
        }


formOf : FoodShow.Model -> Maybe FoodLogForm.Model
formOf model =
    case model of
        FoodShow.Loaded loaded ->
            Just loaded.form

        _ ->
            Nothing


unitsOf : FoodShow.Model -> Maybe (List UnitItem)
unitsOf model =
    case model of
        FoodShow.Loading loading ->
            loading.units

        FoodShow.Loaded loaded ->
            Just loaded.units

        FoodShow.LoadFailed _ ->
            Nothing


errorOf : FoodShow.Model -> Maybe String
errorOf model =
    case model of
        FoodShow.Loaded loaded ->
            loaded.error

        FoodShow.LoadFailed message ->
            Just message

        FoodShow.Loading _ ->
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
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
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
    , item = { itemType = ItemRef.Product, id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = []
    , notes = Nothing
    }


sampleDate : LocalDate
sampleDate =
    sampleDateFromString "2026-05-29"


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
