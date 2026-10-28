module Page.FoodLog.CreateWithAiTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (UnitItem)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Editor
import Data.FoodAssistant exposing (FoodDraftTurn(..))
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot exposing (MealSlot(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Html.Attributes as Attr
import I18n
import Lib.Date exposing (LocalDate)
import Page.FoodLog.CreateAdHoc as Review
import Page.FoodLog.CreateWithAi as CreateWithAi
import Page.FoodLog.ReviewStory as ReviewStory
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
    describe "Page.FoodLog.CreateWithAi"
        [ test "a draft without a date asks for local context, then retries a save-off failure" <|
            \_ ->
                expectSteps
                    (draftModel Nothing Nothing)
                    (\( drafted, _ ) ->
                        let
                            portioned : CreateWithAi.Model
                            portioned =
                                stepReview
                                    (Review.FormMsg (Editor.LogQuantityChanged "2"))
                                    drafted

                            submitting : CreateWithAi.Model
                            submitting =
                                stepReview Review.SubmitClicked portioned

                            received : CreateWithAi.Model
                            received =
                                stepReview (Review.LocalCtxReceived context) submitting

                            failed : CreateWithAi.Model
                            failed =
                                stepReview
                                    (Review.AdHocLogCompleted (Err Client.NetworkError))
                                    received

                            retrying : CreateWithAi.Model
                            retrying =
                                stepReview Review.SubmitClicked failed
                        in
                        Expect.all
                            [ \_ ->
                                outReview Review.SubmitClicked portioned
                                    |> Expect.equal CreateWithAi.RequestLocalCtx
                            , \_ ->
                                outReview Review.SubmitClicked submitting
                                    |> Expect.equal CreateWithAi.NoOp
                            , \_ ->
                                inputShows "1000" portioned
                            , \_ ->
                                contentFor portioned
                                    |> Query.hasNot
                                        [ Selector.text (I18n.en TidNutrientFiber) ]
                            , \_ ->
                                adHocOut (outReview (Review.LocalCtxReceived context) submitting)
                                    |> Expect.equal
                                        (Just
                                            { name = "Paneer wrap"
                                            , date = "2026-06-04"
                                            , timezone = Just "Asia/Kolkata"
                                            , mealSlot = Nothing
                                            , amount = "2"
                                            , unit = "serving"
                                            , nutrients =
                                                [ "ENERGY_KCAL:1000"
                                                , "PROTEIN_G:50"
                                                , "CARBS_G:100"
                                                , "FAT_G:60"
                                                , "FIBER_G:25"
                                                ]
                                            , notes = Nothing
                                            }
                                        )
                            , \_ ->
                                contentFor failed
                                    |> Query.has [ Selector.text Fixtures.networkErrorMessage ]
                            , \_ ->
                                outReview
                                    (Review.AdHocLogCompleted (Err Fixtures.unauthorized))
                                    received
                                    |> Expect.equal CreateWithAi.SessionExpired
                            , \_ ->
                                adHocOut (outReview Review.SubmitClicked failed)
                                    |> Expect.equal
                                        (Just
                                            { name = "Paneer wrap"
                                            , date = "2026-06-04"
                                            , timezone = Just "Asia/Kolkata"
                                            , mealSlot = Nothing
                                            , amount = "2"
                                            , unit = "serving"
                                            , nutrients =
                                                [ "ENERGY_KCAL:1000"
                                                , "PROTEIN_G:50"
                                                , "CARBS_G:100"
                                                , "FAT_G:60"
                                                , "FIBER_G:25"
                                                ]
                                            , notes = Nothing
                                            }
                                        )
                            , \_ ->
                                outReview
                                    (Review.AdHocLogCompleted (Ok localAdHocLog))
                                    retrying
                                    |> Expect.equal (CreateWithAi.LogCreated localAdHocLog)
                            ]
                            ()
                    )
        , test "save-on creates the food once and retries only the failed product log" <|
            \_ ->
                expectSteps
                    (draftModel (Just ReviewStory.day) (Just Lunch))
                    (\( estimated, _ ) ->
                        let
                            saving : CreateWithAi.Model
                            saving =
                                estimated
                                    |> stepReview (Review.FormMsg Editor.LogPersistenceToggled)
                                    |> stepReview
                                        (Review.FormMsg (Editor.PortionWeightChanged "240"))

                            submitting : CreateWithAi.Model
                            submitting =
                                stepReview Review.SubmitClicked saving

                            foodSaved : CreateWithAi.Model
                            foodSaved =
                                stepReview
                                    (Review.CustomFoodCompleted (Ok { id = "food-1" }))
                                    submitting

                            failed : CreateWithAi.Model
                            failed =
                                stepReview
                                    (Review.ProductLogCompleted (Err Client.NetworkError))
                                    foodSaved

                            retried : CreateWithAi.Model
                            retried =
                                stepReview Review.SubmitClicked failed
                        in
                        Expect.all
                            [ \_ ->
                                createFoodOut (outReview Review.SubmitClicked saving)
                                    |> Expect.equal
                                        (Just
                                            { name = "Paneer wrap"
                                            , defaultUnit = Just "serving"
                                            , defaultQuantity = Just "1"
                                            , servings = [ "serving:250", "piece:125" ]
                                            }
                                        )
                            , \_ ->
                                outReview Review.SubmitClicked submitting
                                    |> Expect.equal CreateWithAi.NoOp
                            , \_ ->
                                productOut
                                    (outReview
                                        (Review.CustomFoodCompleted (Ok { id = "food-1" }))
                                        submitting
                                    )
                                    |> Expect.equal (Just "food-1")
                            , \_ ->
                                contentFor failed
                                    |> Query.has
                                        [ Selector.text ReviewStory.savedNotLogged
                                        , Selector.text ReviewStory.retryLabel
                                        ]
                            , \_ ->
                                productOut (outReview Review.SubmitClicked failed)
                                    |> Expect.equal (Just "food-1")
                            , \_ ->
                                outReview
                                    (Review.ProductLogCompleted (Ok productLog))
                                    retried
                                    |> Expect.equal (CreateWithAi.LogCreated productLog)
                            ]
                            ()
                    )
        , test "additional nutrients toggle, ask for changes, and unit filtering" <|
            \_ ->
                expectSteps
                    (draftModel (Just ReviewStory.day) (Just Lunch))
                    (\( estimated, _ ) ->
                        let
                            toggled : CreateWithAi.Model
                            toggled =
                                step CreateWithAi.ToggleAdditionalNutrients estimated

                            asked : CreateWithAi.Model
                            asked =
                                step CreateWithAi.AskForChangesClicked toggled

                            reapplied : CreateWithAi.Model
                            reapplied =
                                step
                                    (CreateWithAi.AssistantMsg
                                        (Assistant.ApplyDraftClicked False)
                                    )
                                    asked

                            filtered : CreateWithAi.Model
                            filtered =
                                step
                                    (CreateWithAi.UnitsLoaded
                                        (Ok { items = unitsWithExtra })
                                    )
                                    reapplied

                            filteredShown : CreateWithAi.Model
                            filteredShown =
                                step CreateWithAi.ToggleAdditionalNutrients filtered

                            unitsOpen : CreateWithAi.Model
                            unitsOpen =
                                stepReview
                                    (Review.FormMsg Editor.ToggleLogUnitDropdown)
                                    filtered
                        in
                        Expect.all
                            [ \_ ->
                                contentFor estimated
                                    |> Query.has
                                        [ Selector.text
                                            (I18n.en TidAssistantShowAdditionalNutrients)
                                        ]
                            , \_ ->
                                contentFor estimated
                                    |> Query.hasNot
                                        [ Selector.text (I18n.en TidNutrientFiber) ]
                            , \_ ->
                                contentFor toggled
                                    |> Query.has
                                        [ Selector.text
                                            (I18n.en TidAssistantHideAdditionalNutrients)
                                        , Selector.text (I18n.en TidNutrientFiber)
                                        ]
                            , \_ ->
                                contentFor asked
                                    |> Query.has
                                        [ Selector.text (I18n.en TidAssistantChangesLabel) ]
                            , \_ -> inputShows "500" filteredShown
                            , \_ -> inputShows "25" filteredShown
                            , \_ -> inputShows "50" filteredShown
                            , \_ -> inputShows "30" filteredShown
                            , \_ -> inputShows "12.5" filteredShown
                            , \_ ->
                                contentFor unitsOpen
                                    |> Query.has
                                        [ Selector.text "Gram"
                                        , Selector.text "Serving"
                                        , Selector.text "Piece"
                                        ]
                            , \_ ->
                                contentFor unitsOpen
                                    |> Query.hasNot [ Selector.text "Cup" ]
                            , \_ ->
                                out (CreateWithAi.UnitsLoaded (Ok { items = unitsWithExtra }))
                                    reapplied
                                    |> Expect.equal CreateWithAi.NoOp
                            ]
                            ()
                    )
        ]



-- PROJECTIONS AND VIEW


inputShows : String -> CreateWithAi.Model -> Expect.Expectation
inputShows value model =
    contentFor model
        |> Query.has [ Selector.attribute (Attr.value value) ]


contentFor : CreateWithAi.Model -> Query.Single CreateWithAi.Msg
contentFor model =
    CreateWithAi.view
        { theme = Theme.light
        , device = { class = Phone, orientation = Portrait }
        , language = Util.EN_US
        }
        model
        |> Element.layout []
        |> Query.fromHtml


adHocOut : CreateWithAi.OutMsg -> Maybe ReviewStory.AdHocRequest
adHocOut outMsg =
    case outMsg of
        CreateWithAi.RequestAdHocLog request ->
            Just (ReviewStory.adHocRequest request)

        _ ->
            Nothing


createFoodOut : CreateWithAi.OutMsg -> Maybe ReviewStory.CreateFoodProjection
createFoodOut outMsg =
    case outMsg of
        CreateWithAi.RequestCreateFood request ->
            Just (ReviewStory.createFoodRequest request)

        _ ->
            Nothing


productOut : CreateWithAi.OutMsg -> Maybe String
productOut outMsg =
    case outMsg of
        CreateWithAi.RequestProductLog request ->
            Just (ReviewStory.productLogItemId request)

        _ ->
            Nothing



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


step : CreateWithAi.Msg -> CreateWithAi.Model -> CreateWithAi.Model
step msg model =
    Fixtures.tupleFirst (CreateWithAi.update msg model)


stepWithOut :
    CreateWithAi.Msg
    -> CreateWithAi.Model
    -> Maybe ( CreateWithAi.Model, CreateWithAi.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            CreateWithAi.update msg model
    in
    if next == model && outMsg == CreateWithAi.NoOp then
        Nothing

    else
        Just ( next, outMsg )


out : CreateWithAi.Msg -> CreateWithAi.Model -> CreateWithAi.OutMsg
out msg model =
    Fixtures.tupleThird (CreateWithAi.update msg model)


stepReview : Review.Msg -> CreateWithAi.Model -> CreateWithAi.Model
stepReview msg model =
    step (CreateWithAi.ReviewMsg msg) model


outReview : Review.Msg -> CreateWithAi.Model -> CreateWithAi.OutMsg
outReview msg model =
    out (CreateWithAi.ReviewMsg msg) model


draftModel :
    Maybe LocalDate
    -> Maybe MealSlot
    -> Result String ( CreateWithAi.Model, List CreateWithAi.OutMsg )
draftModel date mealSlot =
    runStepsResult stepWithOut
        [ CreateWithAi.NutrientsLoaded (Ok { items = ReviewStory.catalog })
        , CreateWithAi.UnitsLoaded (Ok { items = unitOptions })
        , CreateWithAi.AssistantMsg
            (Assistant.StatusLoaded (Ok { enabled = True, supportsImages = True }))
        , CreateWithAi.AssistantMsg
            (Assistant.DescriptionChanged "Paneer wrap with paneer and spices")
        , CreateWithAi.AssistantMsg Assistant.SendClicked
        , CreateWithAi.AssistantMsg (Assistant.DraftCompleted (Ok readyTurn))
        , CreateWithAi.AssistantMsg (Assistant.ApplyDraftClicked False)
        ]
        (CreateWithAi.init date mealSlot |> Tuple.first)


context : LocalCtx
context =
    { date = Fixtures.date "2026-06-04", timezone = "Asia/Kolkata" }


piece : UnitItem
piece =
    { code = "piece", name = "Piece", kind = "serving" }


cup : UnitItem
cup =
    { code = "cup", name = "Cup", kind = "volume" }


unitOptions : List UnitItem
unitOptions =
    [ ReviewStory.gram, ReviewStory.serving, piece ]


unitsWithExtra : List UnitItem
unitsWithExtra =
    [ ReviewStory.gram, ReviewStory.serving, piece, cup ]


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft =
            { name = "Paneer wrap"
            , brand = Nothing
            , categories = [ "wrap" ]
            , defaultQuantity = Just "1"
            , defaultUnit = Just "serving"
            , nutrients =
                [ { code = "ENERGY_KCAL", amountPer100g = "200" }
                , { code = "PROTEIN_G", amountPer100g = "10" }
                , { code = "CARBS_G", amountPer100g = "20" }
                , { code = "FAT_G", amountPer100g = "12" }
                , { code = "FIBER_G", amountPer100g = "5" }
                ]
            , servings =
                [ { unit = "serving", gramsPerUnit = "250" }
                , { unit = "piece", gramsPerUnit = "125" }
                ]
            }
        , suggestedLog =
            Just { amount = "1", unit = "serving", totalWeightGrams = "250" }
        , warnings = [ "Estimated from description" ]
        }


localAdHocLog : FoodLog
localAdHocLog =
    { adHocLog
        | logDate = context.date
        , deviceTimezone = Just context.timezone
    }


adHocLog : FoodLog
adHocLog =
    { id = "log-1"
    , logDate = ReviewStory.day
    , deviceTimezone = Nothing
    , mealSlot = Just Lunch
    , item = FoodLog.AdHocLogItem { name = "Paneer wrap", brand = Nothing }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "1000", unit = "kcal" }
        , { code = "PROTEIN_G", amount = "50", unit = "g" }
        , { code = "CARBS_G", amount = "100", unit = "g" }
        , { code = "FAT_G", amount = "60", unit = "g" }
        , { code = "FIBER_G", amount = "25", unit = "g" }
        ]
    , notes = Nothing
    }


productLog : FoodLog
productLog =
    { adHocLog
        | id = "log-2"
        , item =
            FoodLog.ProductLogItem
                { id = "food-1", name = "Paneer wrap", brand = Nothing }
        , quantity = { amount = "1", unit = "serving" }
        , nutrients =
            [ { code = "ENERGY_KCAL", amount = "500", unit = "kcal" }
            , { code = "PROTEIN_G", amount = "25", unit = "g" }
            , { code = "CARBS_G", amount = "50", unit = "g" }
            , { code = "FAT_G", amount = "30", unit = "g" }
            , { code = "FIBER_G", amount = "12.5", unit = "g" }
            ]
    }
