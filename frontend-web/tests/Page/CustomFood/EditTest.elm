module Page.CustomFood.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (NutrientItem, ProductDetail, UnitItem)
import Component.FoodEditor as Form
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import I18n
import Page.CustomFood.Edit as CustomFoodEdit
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.CustomFood.Edit"
        [ test "load, validation, and a failed save retried from the same form" <|
            \_ ->
                let
                    loaded : CustomFoodEdit.Model
                    loaded =
                        CustomFoodEdit.init "food-1"
                            |> Tuple.first
                            |> runSteps step
                                [ CustomFoodEdit.FoodLoaded "food-1" (Ok food)
                                , CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems })
                                , CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] })
                                ]

                    cleared : CustomFoodEdit.Model
                    cleared =
                        step (CustomFoodEdit.FormMsg (Form.NameChanged "")) loaded

                    invalid : CustomFoodEdit.Model
                    invalid =
                        step CustomFoodEdit.SubmitClicked cleared

                    named : CustomFoodEdit.Model
                    named =
                        step (CustomFoodEdit.FormMsg (Form.NameChanged "Paneer")) invalid

                    ( submitting, updateOut ) =
                        stepWithOut CustomFoodEdit.SubmitClicked named

                    ( failed, _ ) =
                        stepWithOut
                            (CustomFoodEdit.SaveCompleted (Err Client.NetworkError))
                            submitting

                    ( retrying, retryOut ) =
                        stepWithOut CustomFoodEdit.SubmitClicked failed

                    ( saved, completionOut ) =
                        stepWithOut
                            (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                            retrying
                in
                { loaded = ( (toScreen loaded).name, (toScreen loaded).unitOptions )
                , validation = (toScreen invalid).error
                , request = updateRequest updateOut
                , failure = (toScreen failed).error
                , screen = toScreen saved
                , retryRequest = updateRequest retryOut
                , finalOut = completionOut
                }
                    |> Expect.equal
                        { loaded = ( "Curd", [ "g" ] )
                        , validation = Just nameRequired
                        , request = Just paneerRequest
                        , failure = Just Fixtures.networkErrorMessage
                        , screen =
                            { name = "Paneer"
                            , categories = [ "dairy" ]
                            , nutrients = []
                            , unitOptions = [ "g" ]
                            , disabled = True
                            , error = Nothing
                            }
                        , retryRequest = Just paneerRequest
                        , finalOut =
                            CustomFoodEdit.Navigate (CustomFoodShow "food-1")
                        }
        , test "stale loads and late completions are ignored, retry reloads, then 401 expires" <|
            \_ ->
                let
                    started : CustomFoodEdit.Model
                    started =
                        CustomFoodEdit.init "food-1" |> Tuple.first

                    staleOther : CustomFoodEdit.Model
                    staleOther =
                        step (CustomFoodEdit.FoodLoaded "other" (Ok otherFood)) started

                    failed : CustomFoodEdit.Model
                    failed =
                        step
                            (CustomFoodEdit.FoodLoaded "food-1" (Err Client.NetworkError))
                            staleOther

                    late : CustomFoodEdit.Model
                    late =
                        step (CustomFoodEdit.FoodLoaded "food-1" (Ok food)) failed

                    retried : CustomFoodEdit.Model
                    retried =
                        step CustomFoodEdit.RetryClicked late

                    loaded : CustomFoodEdit.Model
                    loaded =
                        retried
                            |> runSteps step
                                [ CustomFoodEdit.FoodLoaded "food-1" (Ok food)
                                , CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems })
                                , CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] })
                                ]

                    staleAfter : CustomFoodEdit.Model
                    staleAfter =
                        step (CustomFoodEdit.FoodLoaded "other" (Ok otherFood)) loaded

                    ( submitting, updateOut ) =
                        stepWithOut CustomFoodEdit.SubmitClicked staleAfter

                    ( saveFailed, _ ) =
                        stepWithOut
                            (CustomFoodEdit.SaveCompleted (Err Client.NetworkError))
                            submitting

                    lateSaveOut : CustomFoodEdit.OutMsg
                    lateSaveOut =
                        out
                            (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                            saveFailed

                    ( retrying, retryOut ) =
                        stepWithOut CustomFoodEdit.SubmitClicked saveFailed

                    ( final, completionOut ) =
                        stepWithOut
                            (CustomFoodEdit.SaveCompleted (Err Fixtures.unauthorized))
                            retrying
                in
                { staleOther = (toScreen staleOther).name
                , failed = (toScreen failed).error
                , late = (toScreen late).error
                , retried = (toScreen retried).error
                , staleAfter = (toScreen staleAfter).name
                , request = updateRequest updateOut
                , lateSaveOut = lateSaveOut
                , retryRequest = updateRequest retryOut
                , screen = toScreen final
                , finalOut = completionOut
                }
                    |> Expect.equal
                        { staleOther = ""
                        , failed = Just Fixtures.networkErrorMessage
                        , late = Just Fixtures.networkErrorMessage
                        , retried = Nothing
                        , staleAfter = "Curd"
                        , request = Just curdRequest
                        , lateSaveOut = CustomFoodEdit.NoOp
                        , retryRequest = Just curdRequest
                        , screen =
                            { name = "Curd"
                            , categories = [ "dairy" ]
                            , nutrients = []
                            , unitOptions = [ "g" ]
                            , disabled = False
                            , error = Just "Sign in again"
                            }
                        , finalOut = CustomFoodEdit.SessionExpired
                        }
        ]


type alias Screen =
    { name : String
    , categories : List String
    , nutrients : List String
    , unitOptions : List String
    , disabled : Bool
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
            , disabled = Form.isSubmitting loaded.form.submit
            , error = submitError loaded.form.submit
            }

        CustomFoodEdit.LoadFailed failed ->
            { name = ""
            , categories = []
            , nutrients = []
            , unitOptions = []
            , disabled = False
            , error = Just failed.message
            }

        CustomFoodEdit.Loading _ ->
            { name = ""
            , categories = []
            , nutrients = []
            , unitOptions = []
            , disabled = False
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


updateRequest : CustomFoodEdit.OutMsg -> Maybe Api.Foods.CreateFoodRequest
updateRequest outMsg =
    case outMsg of
        CustomFoodEdit.RequestUpdateFood "food-1" request ->
            Just request

        _ ->
            Nothing


step : CustomFoodEdit.Msg -> CustomFoodEdit.Model -> CustomFoodEdit.Model
step msg model =
    Fixtures.tupleFirst (CustomFoodEdit.update msg model)


stepWithOut :
    CustomFoodEdit.Msg
    -> CustomFoodEdit.Model
    -> ( CustomFoodEdit.Model, CustomFoodEdit.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            CustomFoodEdit.update msg model
    in
    ( next, outMsg )


out : CustomFoodEdit.Msg -> CustomFoodEdit.Model -> CustomFoodEdit.OutMsg
out msg model =
    Fixtures.tupleThird (CustomFoodEdit.update msg model)


nameRequired : String
nameRequired =
    I18n.en TidCustomFoodNameRequired


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


paneerRequest : Api.Foods.CreateFoodRequest
paneerRequest =
    { curdRequest | name = "Paneer" }


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


otherFood : ProductDetail
otherFood =
    { food | id = "food-2", name = "Ghee" }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" }
    , { code = "ENERGY_KCAL", name = "Energy", unit = "kcal", category = "energy" }
    ]
