module Page.FoodLog.EntryTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (UnitItem)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import I18n
import Lib.Date exposing (LocalDate)
import Page.FoodLog.Entry as FoodLogEntry
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util
import Ui.Env as UiEnv
import Ui.Theme as Theme
import View.DeleteModal exposing (DeleteState(..))


tests : Test
tests =
    describe "Page.FoodLog.Entry"
        [ test "a product log is edited, rejected once, retried, and saved" <|
            \_ ->
                let
                    loaded : FoodLogEntry.Model
                    loaded =
                        loadingModel
                            |> runSteps step
                                [ FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] })
                                , FoodLogEntry.LogLoaded "log-1" (Ok productLog)
                                , FoodLogEntry.ProductDetailLoaded (Err Client.NetworkError)
                                ]

                    blanked : FoodLogEntry.Model
                    blanked =
                        step (FoodLogEntry.FormMsg (FoodLogForm.AmountChanged " ")) loaded

                    rejected : FoodLogEntry.Model
                    rejected =
                        step FoodLogEntry.SubmitClicked blanked

                    edited : FoodLogEntry.Model
                    edited =
                        blanked
                            |> step FoodLogEntry.SubmitClicked
                            |> step (FoodLogEntry.FormMsg (FoodLogForm.AmountChanged "4"))
                            |> step (FoodLogEntry.FormMsg (FoodLogForm.NotesChanged "Updated"))

                    submitting : FoodLogEntry.Model
                    submitting =
                        step FoodLogEntry.SubmitClicked edited

                    failed : FoodLogEntry.Model
                    failed =
                        step (FoodLogEntry.UpdateCompleted (Err Client.NetworkError)) submitting

                    retrying : FoodLogEntry.Model
                    retrying =
                        step FoodLogEntry.SubmitClicked failed
                in
                Expect.all
                    [ \_ ->
                        visibleSubmitError rejected
                            |> Expect.equal (Just amountRequired)
                    , \_ ->
                        updateRequest (out FoodLogEntry.SubmitClicked edited)
                            |> Expect.equal
                                (Just
                                    { mealSlot = Just "lunch"
                                    , amount = "4"
                                    , unit = "serving"
                                    , notes = Just "Updated"
                                    }
                                )
                    , \_ ->
                        out FoodLogEntry.SubmitClicked submitting
                            |> Expect.equal FoodLogEntry.NoOp
                    , \_ ->
                        visibleSubmitError failed
                            |> Expect.equal (Just Fixtures.networkErrorMessage)
                    , \_ ->
                        out (FoodLogEntry.UpdateCompleted (Err Fixtures.unauthorized)) submitting
                            |> Expect.equal FoodLogEntry.SessionExpired
                    , \_ ->
                        contentFor loaded
                            |> Query.has [ Selector.text "Apple" ]
                    , \_ ->
                        contentFor loaded
                            |> Query.hasNot [ Selector.text Fixtures.networkErrorMessage ]
                    , \_ ->
                        contentFor edited
                            |> Query.has [ Selector.text "240.000" ]
                    , \_ ->
                        out (FoodLogEntry.LogLoaded "other" (Ok mealLog)) loaded
                            |> Expect.equal FoodLogEntry.NoOp
                    , \_ ->
                        out (FoodLogEntry.UpdateCompleted (Ok updatedLog)) retrying
                            |> Expect.equal (FoodLogEntry.LogUpdated sampleDate)
                    ]
                    ()
        , test "deleting a meal log cancels, fails, retries, and reports the deleted date" <|
            \_ ->
                let
                    loaded : FoodLogEntry.Model
                    loaded =
                        FoodLogEntry.init "log-2"
                            |> Tuple.first
                            |> runSteps step
                                [ FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] })
                                , FoodLogEntry.LogLoaded "log-2" (Ok mealLog)
                                ]

                    confirming : FoodLogEntry.Model
                    confirming =
                        step FoodLogEntry.DeleteClicked loaded

                    cancelled : FoodLogEntry.Model
                    cancelled =
                        step FoodLogEntry.CancelDeleteClicked confirming

                    reopened : FoodLogEntry.Model
                    reopened =
                        step FoodLogEntry.DeleteClicked cancelled

                    deleting : FoodLogEntry.Model
                    deleting =
                        step FoodLogEntry.ConfirmDeleteClicked reopened

                    failed : FoodLogEntry.Model
                    failed =
                        step (FoodLogEntry.DeleteCompleted (Err Client.NetworkError)) deleting

                    retrying : FoodLogEntry.Model
                    retrying =
                        step FoodLogEntry.ConfirmDeleteClicked failed
                in
                Expect.all
                    [ \_ -> modalVisible confirming |> Expect.equal True
                    , \_ -> modalVisible cancelled |> Expect.equal False
                    , \_ ->
                        modalFor confirming
                            |> Query.has
                                [ Selector.text (I18n.en TidFoodLogDeleteConfirmTitle)
                                , Selector.text (I18n.en TidCustomFoodConfirmDelete)
                                ]
                    , \_ ->
                        deleteRequest (out FoodLogEntry.ConfirmDeleteClicked reopened)
                            |> Expect.equal (Just "log-2")
                    , \_ ->
                        visibleDeleteError failed
                            |> Expect.equal (Just Fixtures.networkErrorMessage)
                    , \_ -> modalVisible failed |> Expect.equal True
                    , \_ ->
                        modalFor failed
                            |> Query.has [ Selector.text Fixtures.networkErrorMessage ]
                    , \_ ->
                        deleteRequest (out FoodLogEntry.ConfirmDeleteClicked failed)
                            |> Expect.equal (Just "log-2")
                    , \_ ->
                        out (FoodLogEntry.DeleteCompleted (Ok ())) cancelled
                            |> Expect.equal FoodLogEntry.NoOp
                    , \_ ->
                        out (FoodLogEntry.DeleteCompleted (Err Fixtures.unauthorized)) deleting
                            |> Expect.equal FoodLogEntry.SessionExpired
                    , \_ ->
                        out (FoodLogEntry.DeleteCompleted (Ok ())) retrying
                            |> Expect.equal
                                (FoodLogEntry.LogDeleted sampleDate (DiaryDay Nothing Nothing))
                    ]
                    ()
        ]



-- USER-VISIBLE PROJECTIONS


visibleSubmitError : FoodLogEntry.Model -> Maybe String
visibleSubmitError model =
    loadedForm model formError |> Maybe.andThen identity


visibleDeleteError : FoodLogEntry.Model -> Maybe String
visibleDeleteError model =
    case model of
        FoodLogEntry.Loaded loaded ->
            deleteError loaded.delete

        _ ->
            Nothing


modalVisible : FoodLogEntry.Model -> Bool
modalVisible model =
    FoodLogEntry.modalView env model /= Nothing


loadedForm : FoodLogEntry.Model -> (FoodLogForm.Model -> a) -> Maybe a
loadedForm model transform =
    case model of
        FoodLogEntry.Loaded loaded ->
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


deleteError : DeleteState -> Maybe String
deleteError state =
    case state of
        DeleteFailed message ->
            Just message

        _ ->
            Nothing


updateRequest :
    FoodLogEntry.OutMsg
    -> Maybe { mealSlot : Maybe String, amount : String, unit : String, notes : Maybe String }
updateRequest outMsg =
    case outMsg of
        FoodLogEntry.RequestUpdateLog _ request ->
            Just
                { mealSlot = Maybe.map MealSlot.toString request.mealSlot
                , amount = request.quantity.amount
                , unit = request.quantity.unit
                , notes = request.notes
                }

        _ ->
            Nothing


deleteRequest : FoodLogEntry.OutMsg -> Maybe String
deleteRequest outMsg =
    case outMsg of
        FoodLogEntry.RequestDeleteLog logId ->
            Just logId

        _ ->
            Nothing



-- VIEW HELPERS


env : UiEnv.Env
env =
    { theme = Theme.light
    , device = { class = Phone, orientation = Portrait }
    , language = Util.EN_US
    }


contentFor : FoodLogEntry.Model -> Query.Single FoodLogEntry.Msg
contentFor model =
    FoodLogEntry.contentView env model
        |> Element.layout []
        |> Query.fromHtml


modalFor : FoodLogEntry.Model -> Query.Single FoodLogEntry.Msg
modalFor model =
    FoodLogEntry.modalView env model
        |> Maybe.withDefault Element.none
        |> Element.layout []
        |> Query.fromHtml



-- FIXTURES AND HELPERS


step : FoodLogEntry.Msg -> FoodLogEntry.Model -> FoodLogEntry.Model
step msg model =
    Fixtures.tupleFirst (FoodLogEntry.update msg model)


out : FoodLogEntry.Msg -> FoodLogEntry.Model -> FoodLogEntry.OutMsg
out msg model =
    Fixtures.tupleThird (FoodLogEntry.update msg model)


loadingModel : FoodLogEntry.Model
loadingModel =
    FoodLogEntry.init "log-1" |> Tuple.first


sampleDate : LocalDate
sampleDate =
    Fixtures.date "2026-06-04"


amountRequired : String
amountRequired =
    I18n.en TidFoodLogAmountRequired


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
    , notes = Just "Good"
    }


mealLog : FoodLog
mealLog =
    { productLog
        | id = "log-2"
        , item = FoodLog.MealLogItem { id = "meal-1", name = "Lunch meal" }
        , nutrients =
            [ { code = "ENERGY_KCAL", amount = "400", unit = "kcal" } ]
    }


updatedLog : FoodLog
updatedLog =
    { productLog
        | quantity = { amount = "4", unit = "serving" }
        , notes = Just "Updated"
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
