module Page.CustomFood.ListTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail)
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.List as CustomFoodList
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.List"
        [ test "a loaded list opens a food, returns, and starts both create flows" <|
            \_ ->
                let
                    loaded : CustomFoodList.Model
                    loaded =
                        step (CustomFoodList.FoodsLoaded (Ok { items = [ food ] }))
                            initModel

                    actions : Result String ( CustomFoodList.Model, List CustomFoodList.OutMsg )
                    actions =
                        runStepsResult stepWithOut
                            [ CustomFoodList.OpenFoodClicked "food-1"
                            , CustomFoodList.BackClicked
                            , CustomFoodList.CreateManuallyClicked
                            , CustomFoodList.CreateWithAiClicked
                            ]
                            loaded
                in
                case actions of
                    Ok ( final, [ openOut, backOut, manualOut, aiOut ] ) ->
                        { openOut = openOut
                        , backOut = backOut
                        , manualOut = manualOut
                        , aiOut = aiOut
                        , screen = toScreen final
                        }
                            |> Expect.equal
                                { openOut = CustomFoodList.Navigate (CustomFoodShow "food-1")
                                , backOut =
                                    CustomFoodList.Navigate (DiaryDay Nothing Nothing)
                                , manualOut = CustomFoodList.Navigate CustomFoodCreate
                                , aiOut = CustomFoodList.Navigate CustomFoodCreateWithAi
                                , screen =
                                    { names = [ "Paneer" ], error = Nothing }
                                }

                    Ok _ ->
                        Expect.fail "the list story produced unexpected out messages"

                    Err message ->
                        Expect.fail message
        , test "a failed load returns to the diary, then re-entry loads and a 401 expires" <|
            \_ ->
                let
                    failed : CustomFoodList.Model
                    failed =
                        step (CustomFoodList.FoodsLoaded (Err Client.NetworkError))
                            initModel

                    actions : Result String ( CustomFoodList.Model, List CustomFoodList.OutMsg )
                    actions =
                        runStepsResult stepWithOut
                            [ CustomFoodList.CreateManuallyClicked
                            , CustomFoodList.BackClicked
                            ]
                            failed

                    reentered : CustomFoodList.Model
                    reentered =
                        step (CustomFoodList.FoodsLoaded (Ok { items = [ food ] }))
                            initModel

                    expired : CustomFoodList.Model
                    expired =
                        step
                            (CustomFoodList.FoodsLoaded (Err Fixtures.unauthorized))
                            reentered
                in
                case actions of
                    Ok ( _, [ createOut, backOut ] ) ->
                        { failed = toScreen failed
                        , createOut = createOut
                        , backOut = backOut
                        , reentryOut = Tuple.second CustomFoodList.init
                        , reentered = toScreen reentered
                        , screen = toScreen expired
                        , finalOut =
                            out
                                (CustomFoodList.FoodsLoaded (Err Fixtures.unauthorized))
                                reentered
                        }
                            |> Expect.equal
                                { failed =
                                    { names = [], error = Just Fixtures.networkErrorMessage }
                                , createOut = CustomFoodList.Navigate CustomFoodCreate
                                , backOut =
                                    CustomFoodList.Navigate (DiaryDay Nothing Nothing)
                                , reentryOut = CustomFoodList.RequestFoods
                                , reentered = { names = [ "Paneer" ], error = Nothing }
                                , screen = { names = [], error = Just "Sign in again" }
                                , finalOut = CustomFoodList.SessionExpired
                                }

                    Ok _ ->
                        Expect.fail "the failed-load story produced unexpected out messages"

                    Err message ->
                        Expect.fail message
        ]


type alias Screen =
    { names : List String
    , error : Maybe String
    }


toScreen : CustomFoodList.Model -> Screen
toScreen model =
    case model of
        CustomFoodList.Loaded foods ->
            { names = List.map .name foods, error = Nothing }

        CustomFoodList.LoadFailed message ->
            { names = [], error = Just message }

        CustomFoodList.Loading ->
            { names = [], error = Nothing }


initModel : CustomFoodList.Model
initModel =
    Tuple.first CustomFoodList.init


step : CustomFoodList.Msg -> CustomFoodList.Model -> CustomFoodList.Model
step msg model =
    Fixtures.tupleFirst (CustomFoodList.update msg model)


out : CustomFoodList.Msg -> CustomFoodList.Model -> CustomFoodList.OutMsg
out msg model =
    Fixtures.tupleThird (CustomFoodList.update msg model)


stepWithOut :
    CustomFoodList.Msg
    -> CustomFoodList.Model
    -> Maybe ( CustomFoodList.Model, CustomFoodList.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            CustomFoodList.update msg model
    in
    if next == model && outMsg == CustomFoodList.NoOp then
        Nothing

    else
        Just ( next, outMsg )


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Paneer"
    , brand = Just "Local"
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary =
        { per100g =
            { energyKcal = Just "120"
            , proteinG = Nothing
            , carbsG = Nothing
            , fatG = Nothing
            , fiberG = Nothing
            }
        }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }
