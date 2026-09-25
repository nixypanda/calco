module Page.CustomFood.ListTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.List as CustomFoodList
import Test exposing (Test, describe, test)
import Translations.Util as Util


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.CustomFood.List"
        [ test "the list loads and every action navigates to its destination" <|
            \_ ->
                let
                    ( initial, initialRequest ) =
                        CustomFoodList.init

                    loaded : CustomFoodList.Model
                    loaded =
                        step (CustomFoodList.FoodsLoaded (Ok { items = [ food ] })) initial
                in
                { initialRequest = initialRequest
                , initialPhase = toScreen initial |> .phase
                , loaded = toScreen loaded
                , open = out (CustomFoodList.OpenFoodClicked "food-1") loaded
                , manual = out CustomFoodList.CreateManuallyClicked loaded
                , withAi = out CustomFoodList.CreateWithAiClicked loaded
                , back = out CustomFoodList.BackClicked loaded
                }
                    |> Expect.equal
                        { initialRequest = CustomFoodList.RequestFoods
                        , initialPhase = "loading"
                        , loaded = { phase = "loaded", names = [ "Paneer" ], error = Nothing }
                        , open = CustomFoodList.Navigate (CustomFoodShow "food-1")
                        , manual = CustomFoodList.Navigate CustomFoodCreate
                        , withAi = CustomFoodList.Navigate CustomFoodCreateWithAi
                        , back = CustomFoodList.Navigate (DiaryDay Nothing Nothing)
                        }
        , test "a failed load shows an error and an unauthorized load expires the session" <|
            \_ ->
                let
                    failed : CustomFoodList.Model
                    failed =
                        step (CustomFoodList.FoodsLoaded (Err Client.NetworkError)) emptyModel
                in
                { failed = toScreen failed
                , unauthorized =
                    out
                        (CustomFoodList.FoodsLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        emptyModel
                }
                    |> Expect.equal
                        { failed =
                            { phase = "failed"
                            , names = []
                            , error = Just networkErrorMessage
                            }
                        , unauthorized = CustomFoodList.SessionExpired
                        }
        , test "the food summary omits brand and calories when missing" <|
            \_ ->
                CustomFoodList.foodSummaryText Util.EN_US food
                    |> Expect.equal ""
        , test "the food summary shows brand and calories when present" <|
            \_ ->
                CustomFoodList.foodSummaryText
                    Util.EN_US
                    { food
                        | brand = Just "Local"
                        , nutritionSummary =
                            { per100g =
                                { energyKcal = Just "120"
                                , proteinG = Nothing
                                , carbsG = Nothing
                                , fatG = Nothing
                                , fiberG = Nothing
                                }
                            }
                    }
                    |> Expect.equal "Local ⋅ 120 kcal per 100 g"
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , names : List String
    , error : Maybe String
    }


toScreen : CustomFoodList.Model -> Screen
toScreen model =
    case model of
        CustomFoodList.Loaded foods ->
            { phase = "loaded"
            , names = List.map .name foods
            , error = Nothing
            }

        CustomFoodList.LoadFailed message ->
            { phase = "failed"
            , names = []
            , error = Just message
            }

        CustomFoodList.Loading ->
            { phase = "loading"
            , names = []
            , error = Nothing
            }


step : CustomFoodList.Msg -> CustomFoodList.Model -> CustomFoodList.Model
step msg model =
    first (CustomFoodList.update msg model)


out : CustomFoodList.Msg -> CustomFoodList.Model -> CustomFoodList.OutMsg
out msg model =
    third (CustomFoodList.update msg model)


emptyModel : CustomFoodList.Model
emptyModel =
    Tuple.first CustomFoodList.init


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Paneer"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
