module Page.FoodLog.CreateAdHocTest exposing (tests)

import Api.Client as Client
import Component.FoodEditor as Editor
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Page.FoodLog.CreateAdHoc as CreateAdHoc
import Page.FoodLog.ReviewStory as ReviewStory
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateAdHoc"
        [ test "a missing name is rejected, then an ad-hoc save fails and retries" <|
            \_ ->
                let
                    rejected : CreateAdHoc.Model
                    rejected =
                        step CreateAdHoc.SubmitClicked preparedModel

                    named : CreateAdHoc.Model
                    named =
                        step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap")) rejected

                    submitting : CreateAdHoc.Model
                    submitting =
                        step CreateAdHoc.SubmitClicked named

                    failed : CreateAdHoc.Model
                    failed =
                        step
                            (CreateAdHoc.AdHocLogCompleted (Err Client.NetworkError))
                            submitting

                    retrying : CreateAdHoc.Model
                    retrying =
                        step CreateAdHoc.SubmitClicked failed
                in
                Expect.all
                    [ \_ ->
                        ReviewStory.submitError rejected
                            |> Expect.equal (Just ReviewStory.nameRequired)
                    , \_ ->
                        adHocOut (out CreateAdHoc.SubmitClicked named)
                            |> Expect.equal
                                (Just
                                    { name = "Paneer wrap"
                                    , date = "2026-09-14"
                                    , timezone = Nothing
                                    , mealSlot = Just "lunch"
                                    , amount = "1"
                                    , unit = "serving"
                                    , nutrients =
                                        [ "ENERGY_KCAL:520"
                                        , "PROTEIN_G:24"
                                        , "CARBS_G:48"
                                        , "FAT_G:25"
                                        ]
                                    , notes = Nothing
                                    }
                                )
                    , \_ ->
                        out CreateAdHoc.SubmitClicked submitting
                            |> Expect.equal CreateAdHoc.NoOp
                    , \_ ->
                        ReviewStory.submitError failed
                            |> Expect.equal (Just Fixtures.networkErrorMessage)
                    , \_ ->
                        out (CreateAdHoc.AdHocLogCompleted (Err Fixtures.unauthorized)) submitting
                            |> Expect.equal CreateAdHoc.SessionExpired
                    , \_ ->
                        out (CreateAdHoc.AdHocLogCompleted (Ok adHocLog)) retrying
                            |> Expect.equal (CreateAdHoc.LogCreated adHocLog)
                    ]
                    ()
        , test "save-on creates a custom food once, then a failed product log is retried" <|
            \_ ->
                let
                    prepared : CreateAdHoc.Model
                    prepared =
                        preparedModel
                            |> step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap"))
                            |> step (CreateAdHoc.FormMsg Editor.LogPersistenceToggled)
                            |> step (CreateAdHoc.FormMsg (Editor.PortionWeightChanged "160"))

                    submitting : CreateAdHoc.Model
                    submitting =
                        step CreateAdHoc.SubmitClicked prepared

                    foodSaved : CreateAdHoc.Model
                    foodSaved =
                        step
                            (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" }))
                            submitting

                    failed : CreateAdHoc.Model
                    failed =
                        step
                            (CreateAdHoc.ProductLogCompleted (Err Client.NetworkError))
                            foodSaved

                    retried : CreateAdHoc.Model
                    retried =
                        step CreateAdHoc.SubmitClicked failed
                in
                Expect.all
                    [ \_ ->
                        createFoodOut (out CreateAdHoc.SubmitClicked prepared)
                            |> Expect.equal
                                (Just
                                    { name = "Paneer wrap"
                                    , defaultUnit = Just "serving"
                                    , defaultQuantity = Just "1"
                                    , servings = [ "serving:160" ]
                                    }
                                )
                    , \_ ->
                        out CreateAdHoc.SubmitClicked submitting
                            |> Expect.equal CreateAdHoc.NoOp
                    , \_ ->
                        productOut
                            (out
                                (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" }))
                                submitting
                            )
                            |> Expect.equal (Just "food-1")
                    , \_ ->
                        step
                            (CreateAdHoc.CustomFoodCompleted (Err Client.NetworkError))
                            submitting
                            |> ReviewStory.submitError
                            |> Expect.equal (Just Fixtures.networkErrorMessage)
                    , \_ ->
                        out
                            (CreateAdHoc.CustomFoodCompleted (Err Fixtures.unauthorized))
                            submitting
                            |> Expect.equal CreateAdHoc.SessionExpired
                    , \_ ->
                        out
                            (CreateAdHoc.ProductLogCompleted (Err Fixtures.unauthorized))
                            foodSaved
                            |> Expect.equal CreateAdHoc.SessionExpired
                    , \_ ->
                        ReviewStory.submitError failed
                            |> Expect.equal (Just ReviewStory.savedNotLogged)
                    , \_ ->
                        ReviewStory.submitLabel failed
                            |> Expect.equal (Just ReviewStory.retryLabel)
                    , \_ ->
                        productOut (out CreateAdHoc.SubmitClicked failed)
                            |> Expect.equal (Just "food-1")
                    , \_ ->
                        out (CreateAdHoc.ProductLogCompleted (Ok productLog)) retried
                            |> Expect.equal (CreateAdHoc.LogCreated productLog)
                    ]
                    ()
        , test "a blank date waits for local context and fills it before logging" <|
            \_ ->
                let
                    prepared : CreateAdHoc.Model
                    prepared =
                        CreateAdHoc.init Nothing Nothing
                            |> step (CreateAdHoc.UnitsLoaded (Ok { items = ReviewStory.units }))
                            |> step
                                (CreateAdHoc.NutrientsLoaded (Ok { items = ReviewStory.catalog }))
                            |> runSteps step ReviewStory.fillNutrients
                            |> step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap"))

                    awaiting : CreateAdHoc.Model
                    awaiting =
                        step CreateAdHoc.SubmitClicked prepared
                in
                Expect.all
                    [ \_ ->
                        out CreateAdHoc.SubmitClicked prepared
                            |> Expect.equal CreateAdHoc.RequestLocalCtx
                    , \_ ->
                        out CreateAdHoc.SubmitClicked awaiting
                            |> Expect.equal CreateAdHoc.NoOp
                    , \_ ->
                        ReviewStory.dateOf awaiting |> Expect.equal ""
                    , \_ ->
                        out (CreateAdHoc.LocalCtxReceived context) awaiting
                            |> adHocOut
                            |> Expect.equal
                                (Just
                                    { name = "Paneer wrap"
                                    , date = "2026-09-16"
                                    , timezone = Just "Asia/Kolkata"
                                    , mealSlot = Nothing
                                    , amount = "1"
                                    , unit = "serving"
                                    , nutrients =
                                        [ "ENERGY_KCAL:520"
                                        , "PROTEIN_G:24"
                                        , "CARBS_G:48"
                                        , "FAT_G:25"
                                        ]
                                    , notes = Nothing
                                    }
                                )
                    , \_ ->
                        out
                            (CreateAdHoc.AdHocLogCompleted (Ok adHocLog))
                            (step (CreateAdHoc.LocalCtxReceived context) awaiting)
                            |> Expect.equal (CreateAdHoc.LogCreated adHocLog)
                    ]
                    ()
        ]



-- OUTMSG PROJECTIONS


adHocOut : CreateAdHoc.OutMsg -> Maybe ReviewStory.AdHocRequest
adHocOut outMsg =
    case outMsg of
        CreateAdHoc.RequestAdHocLog request ->
            Just (ReviewStory.adHocRequest request)

        _ ->
            Nothing


createFoodOut : CreateAdHoc.OutMsg -> Maybe ReviewStory.CreateFoodProjection
createFoodOut outMsg =
    case outMsg of
        CreateAdHoc.RequestCreateFood request ->
            Just (ReviewStory.createFoodRequest request)

        _ ->
            Nothing


productOut : CreateAdHoc.OutMsg -> Maybe String
productOut outMsg =
    case outMsg of
        CreateAdHoc.RequestProductLog request ->
            Just (ReviewStory.productLogItemId request)

        _ ->
            Nothing



-- FIXTURES AND HELPERS


step : CreateAdHoc.Msg -> CreateAdHoc.Model -> CreateAdHoc.Model
step msg model =
    Fixtures.tupleFirst (CreateAdHoc.update msg model)


out : CreateAdHoc.Msg -> CreateAdHoc.Model -> CreateAdHoc.OutMsg
out msg model =
    Fixtures.tupleThird (CreateAdHoc.update msg model)


preparedModel : CreateAdHoc.Model
preparedModel =
    CreateAdHoc.init (Just ReviewStory.day) (Just Lunch)
        |> step (CreateAdHoc.UnitsLoaded (Ok { items = ReviewStory.units }))
        |> step (CreateAdHoc.NutrientsLoaded (Ok { items = ReviewStory.catalog }))
        |> runSteps step ReviewStory.fillNutrients


context : LocalCtx
context =
    { date = Fixtures.date "2026-09-16", timezone = "Asia/Kolkata" }


nutrients : List { code : String, amount : String, unit : String }
nutrients =
    [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
    , { code = "PROTEIN_G", amount = "24", unit = "g" }
    , { code = "CARBS_G", amount = "48", unit = "g" }
    , { code = "FAT_G", amount = "25", unit = "g" }
    ]


adHocLog : FoodLog
adHocLog =
    { id = "log-1"
    , logDate = ReviewStory.day
    , deviceTimezone = Nothing
    , mealSlot = Just Lunch
    , item = FoodLog.AdHocLogItem { name = "Paneer wrap", brand = Nothing }
    , quantity = { amount = "1", unit = "serving" }
    , nutrients = nutrients
    , notes = Nothing
    }


productLog : FoodLog
productLog =
    { adHocLog
        | id = "log-2"
        , item =
            FoodLog.ProductLogItem
                { id = "food-1", name = "Paneer wrap", brand = Nothing }
    }
