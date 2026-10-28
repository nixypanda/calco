module Page.Food.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Logs as Logs
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Html.Attributes as Attr
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Food.Show as FoodShow
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Food.Show"
        [ test "a last-used portion, an unknown unit, and a failed save retried" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodShow.LastUsedLoaded "food-1"
                            (Ok { items = [ recentItem ] })
                        , FoodShow.FoodLoaded "food-1" (Ok food)
                        , FoodShow.UnitsLoaded (Ok { items = [ gram, serving ] })
                        ]
                        loadingModel
                    )
                    (\( loaded, _ ) ->
                        let
                            fallback : FoodShow.Model
                            fallback =
                                step
                                    (FoodShow.FormMsg (FoodLogForm.UnitChanged "cup"))
                                    loaded

                            blanked : FoodShow.Model
                            blanked =
                                step (FoodShow.FormMsg (FoodLogForm.AmountChanged " ")) loaded

                            rejected : FoodShow.Model
                            rejected =
                                step FoodShow.SubmitClicked blanked

                            filled : FoodShow.Model
                            filled =
                                blanked
                                    |> step FoodShow.SubmitClicked
                                    |> step (FoodShow.FormMsg (FoodLogForm.AmountChanged "3"))

                            submitting : FoodShow.Model
                            submitting =
                                step FoodShow.SubmitClicked filled

                            failed : FoodShow.Model
                            failed =
                                step
                                    (FoodShow.LogCompleted (Err Client.NetworkError))
                                    submitting

                            retrying : FoodShow.Model
                            retrying =
                                step FoodShow.SubmitClicked failed
                        in
                        Expect.all
                            [ \_ -> inputShows "250" loaded
                            , \_ ->
                                contentFor loaded
                                    |> Query.has [ Selector.text "Gram (g)" ]
                            , \_ ->
                                visibleSubmitError rejected
                                    |> Expect.equal (Just amountRequired)
                            , \_ ->
                                contentFor fallback
                                    |> Query.has
                                        [ Selector.text (I18n.en TidNutrientEnergy)
                                        , Selector.text "120.000"
                                        ]
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodShow.SubmitClicked
                                        , FoodShow.LocalCtxReceived context
                                        ]
                                        filled
                                    )
                                    (\( _, createOuts ) ->
                                        Maybe.andThen createLog
                                            (List.drop 1 createOuts |> List.head)
                                            |> Expect.equal
                                                (Just
                                                    { date = "2026-05-29"
                                                    , timezone = Just "Asia/Kolkata"
                                                    , meal = Just "lunch"
                                                    , item = "product:food-1"
                                                    , amount = "3"
                                                    , unit = "g"
                                                    , notes = Nothing
                                                    }
                                                )
                                    )
                            , \_ ->
                                out FoodShow.SubmitClicked submitting
                                    |> Expect.equal FoodShow.NoOp
                            , \_ ->
                                visibleSubmitError failed
                                    |> Expect.equal (Just Fixtures.networkErrorMessage)
                            , \_ ->
                                out (FoodShow.LogCompleted (Err Fixtures.unauthorized)) submitting
                                    |> Expect.equal FoodShow.SessionExpired
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodShow.LogCompleted (Ok log) ]
                                        (step (FoodShow.LocalCtxReceived context) retrying)
                                    )
                                    (\( _, completedOuts ) ->
                                        List.head completedOuts
                                            |> Expect.equal
                                                (Just
                                                    (FoodShow.LogCreated log
                                                        (FoodSearch
                                                            (Just sampleDate)
                                                            (Just Lunch)
                                                        )
                                                    )
                                                )
                                    )
                            , \_ ->
                                out (FoodShow.UnitsLoaded (Err Fixtures.unauthorized)) loaded
                                    |> Expect.equal FoodShow.SessionExpired
                            , \_ ->
                                out
                                    (FoodShow.FoodLoaded "food-1" (Err Fixtures.unauthorized))
                                    loadingModel
                                    |> Expect.equal FoodShow.SessionExpired
                            ]
                            ()
                    )
        , test "edits survive stale other-product data and a failed load stays failed" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodShow.FoodLoaded "food-1" (Ok food)
                        , FoodShow.UnitsLoaded (Ok { items = [ gram, serving ] })
                        ]
                        loadingModel
                    )
                    (\( loaded, _ ) ->
                        let
                            edited : FoodShow.Model
                            edited =
                                loaded
                                    |> step (FoodShow.FormMsg (FoodLogForm.AmountChanged "3"))
                                    |> step (FoodShow.FormMsg (FoodLogForm.UnitChanged "g"))

                            afterLastUsed : FoodShow.Model
                            afterLastUsed =
                                step
                                    (FoodShow.LastUsedLoaded "food-1"
                                        (Ok { items = [ recentServing ] })
                                    )
                                    edited

                            afterStaleFood : FoodShow.Model
                            afterStaleFood =
                                step (FoodShow.FoodLoaded "other" (Ok otherFood)) afterLastUsed

                            afterStaleRecent : FoodShow.Model
                            afterStaleRecent =
                                step
                                    (FoodShow.LastUsedLoaded "other"
                                        (Ok { items = [ recentItem ] })
                                    )
                                    afterStaleFood

                            failed : FoodShow.Model
                            failed =
                                step
                                    (FoodShow.FoodLoaded "food-1" (Err Client.NetworkError))
                                    afterStaleRecent

                            late : FoodShow.Model
                            late =
                                step (FoodShow.FoodLoaded "food-1" (Ok food)) failed
                        in
                        Expect.all
                            [ \_ -> inputShows "3" afterLastUsed
                            , \_ -> inputShows "3" afterStaleRecent
                            , \_ ->
                                contentFor afterStaleRecent
                                    |> Query.has [ Selector.text "Apple" ]
                            , \_ ->
                                out (FoodShow.FoodLoaded "other" (Ok otherFood)) afterLastUsed
                                    |> Expect.equal FoodShow.NoOp
                            , \_ ->
                                out
                                    (FoodShow.LastUsedLoaded "other"
                                        (Ok { items = [ recentItem ] })
                                    )
                                    afterStaleFood
                                    |> Expect.equal FoodShow.NoOp
                            , \_ ->
                                visibleError failed
                                    |> Expect.equal (Just Fixtures.networkErrorMessage)
                            , \_ ->
                                visibleError late
                                    |> Expect.equal (Just Fixtures.networkErrorMessage)
                            , \_ ->
                                out (FoodShow.FoodLoaded "food-1" (Ok food)) failed
                                    |> Expect.equal FoodShow.NoOp
                            ]
                            ()
                    )
        ]



-- USER-VISIBLE PROJECTIONS


inputShows : String -> FoodShow.Model -> Expect.Expectation
inputShows value model =
    contentFor model
        |> Query.has [ Selector.attribute (Attr.value value) ]


visibleSubmitError : FoodShow.Model -> Maybe String
visibleSubmitError model =
    formField model formError |> Maybe.andThen identity


visibleError : FoodShow.Model -> Maybe String
visibleError model =
    case model of
        FoodShow.LoadFailed failed ->
            Just failed.message

        _ ->
            Nothing


formField : FoodShow.Model -> (FoodLogForm.Model -> a) -> Maybe a
formField model transform =
    case model of
        FoodShow.Loaded loaded ->
            Just (transform loaded.form)

        _ ->
            Nothing


formError : FoodLogForm.Model -> Maybe String
formError form =
    case form.submitState of
        FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage ->
            Just amountRequired

        FoodLogForm.SubmitFailed (FoodLogForm.RequestFailed message) ->
            Just message

        _ ->
            Nothing


type alias CreateLogProjection =
    { date : String
    , timezone : Maybe String
    , meal : Maybe String
    , item : String
    , amount : String
    , unit : String
    , notes : Maybe String
    }


createLog : FoodShow.OutMsg -> Maybe CreateLogProjection
createLog outMsg =
    case outMsg of
        FoodShow.RequestCreateLog request ->
            Just
                { date = LocalDate.format request.logDate
                , timezone = request.deviceTimezone
                , meal = Maybe.map MealSlot.toString request.mealSlot
                , item = ItemRef.itemTypeToString request.item.itemType ++ ":" ++ request.item.id
                , amount = request.quantity.amount
                , unit = request.quantity.unit
                , notes = request.notes
                }

        _ ->
            Nothing



-- VIEW HELPER


contentFor : FoodShow.Model -> Query.Single FoodShow.Msg
contentFor model =
    FoodShow.contentView
        { theme = Theme.light
        , device = { class = Phone, orientation = Portrait }
        , language = Util.EN_US
        }
        model
        |> Element.layout []
        |> Query.fromHtml



-- FIXTURES AND HELPERS


expectSteps :
    Result String ( model, List out )
    -> (( model, List out ) -> Expect.Expectation)
    -> Expect.Expectation
expectSteps result assertion =
    case result of
        Ok pair ->
            assertion pair

        Err message ->
            Expect.fail message


step : FoodShow.Msg -> FoodShow.Model -> FoodShow.Model
step msg model =
    Fixtures.tupleFirst (FoodShow.update msg model)


stepWithOut :
    FoodShow.Msg
    -> FoodShow.Model
    -> Maybe ( FoodShow.Model, FoodShow.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            FoodShow.update msg model
    in
    if next == model && outMsg == FoodShow.NoOp then
        Nothing

    else
        Just ( next, outMsg )


out : FoodShow.Msg -> FoodShow.Model -> FoodShow.OutMsg
out msg model =
    Fixtures.tupleThird (FoodShow.update msg model)


loadingModel : FoodShow.Model
loadingModel =
    FoodShow.init "food-1" (Just sampleDate) (Just Lunch) Nothing
        |> Tuple.first


context : LocalCtx
context =
    { date = Fixtures.date "2026-06-04", timezone = "Asia/Kolkata" }


sampleDate : LocalDate
sampleDate =
    Fixtures.date "2026-05-29"


amountRequired : String
amountRequired =
    I18n.en TidFoodLogAmountRequired


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
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients =
        [ { code = "ENERGY_KCAL"
          , amountPer100g = "120"
          , unit = "kcal"
          , source = Nothing
          , confidence = Nothing
          }
        ]
    , servings = [ { unit = "serving", gramsPerUnit = "50" } ]
    , allowedUnits = [ gram, serving ]
    }


otherFood : ProductDetail
otherFood =
    { food | id = "other", name = "Ghee" }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


serving : UnitItem
serving =
    { code = "serving", name = "Serving", kind = "serving" }


recentItem : Logs.RecentItem
recentItem =
    { item = FoodLog.ProductLogItem { id = "food-1", name = "Apple", brand = Just "Local" }
    , lastUsedDate = Fixtures.date "2026-05-28"
    , mealSlot = Just Lunch
    , quantity = { amount = "250", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , topQuantities = []
    }


recentServing : Logs.RecentItem
recentServing =
    { recentItem | quantity = { amount = "3", unit = "serving" } }


log : FoodLog
log =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "3", unit = "g" }
    , nutrients = []
    , notes = Nothing
    }
