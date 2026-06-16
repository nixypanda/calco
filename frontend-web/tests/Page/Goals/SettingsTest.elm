module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSource(..), GoalSnapshot)
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as GoalsSettings
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "init requests today's goals" <|
            \_ ->
                GoalsSettings.init today
                    |> Tuple.second
                    |> Expect.equal (GoalsSettings.RequestGoal today)
        , test "goal load success populates the form" <|
            \_ ->
                GoalsSettings.update (GoalsSettings.GoalLoaded (Ok savedSnapshot)) GoalsSettings.Loading
                    |> first
                    |> fields
                    |> Expect.equal (Just [ "2290", "160", "255", "70" ])
        , test "invalid macro formula blocks save" <|
            \_ ->
                let
                    badModel : GoalsSettings.Model
                    badModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | calorieTarget = "2200"
                            }

                    ( model, _, outMsg ) =
                        GoalsSettings.update GoalsSettings.SaveClicked badModel
                in
                ( outMsg, formError model )
                    |> Expect.equal
                        ( GoalsSettings.NoOp
                        , Just "Calories must equal protein*4 + carbs*4 + fat*9."
                        )
        , test "save click requests local context after validation" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked (GoalsSettings.Ready loadedModel)
                    |> third
                    |> Expect.equal GoalsSettings.RequestLocalContext
        , test "local context produces save request" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.LocalContextReceived
                        { date = "2026-06-16"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    waitingModel
                    |> third
                    |> Expect.equal
                        (GoalsSettings.RequestSaveGoal
                            { localDate = "2026-06-16"
                            , deviceTimezone = "Asia/Kolkata"
                            , targets =
                                { calorieTarget = 2290
                                , proteinTargetG = 160
                                , carbsTargetG = 255
                                , fatTargetG = 70
                                }
                            }
                        )
        , test "save success refreshes snapshot and fields" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Ok updatedSnapshot))
                    savingModel
                    |> first
                    |> fields
                    |> Expect.equal (Just [ "2100", "150", "240", "60" ])
        , test "save failure stores request error" <|
            \_ ->
                let
                    model : GoalsSettings.Model
                    model =
                        GoalsSettings.update
                            (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                            savingModel
                            |> first
                in
                requestError model
                    |> Expect.equal (Just "Network error")
        ]


loadedModel : GoalsSettings.LoadedModel
loadedModel =
    { today = today
    , snapshot = savedSnapshot
    , calorieTarget = "2290"
    , proteinTargetG = "160"
    , carbsTargetG = "255"
    , fatTargetG = "70"
    , formError = Nothing
    , requestError = Nothing
    , requestState = GoalsSettings.Idle
    }


waitingModel : GoalsSettings.Model
waitingModel =
    GoalsSettings.Ready { loadedModel | requestState = GoalsSettings.WaitingForLocalContext }


savingModel : GoalsSettings.Model
savingModel =
    GoalsSettings.Ready { loadedModel | requestState = GoalsSettings.Saving }


savedSnapshot : GoalSnapshot
savedSnapshot =
    { requestedDate = today
    , effectiveFrom = Just today
    , source = Saved
    , targets =
        { calorieTarget = 2290
        , proteinTargetG = 160
        , carbsTargetG = 255
        , fatTargetG = 70
        }
    }


updatedSnapshot : GoalSnapshot
updatedSnapshot =
    { requestedDate = today
    , effectiveFrom = Just today
    , source = Saved
    , targets =
        { calorieTarget = 2100
        , proteinTargetG = 150
        , carbsTargetG = 240
        , fatTargetG = 60
        }
    }


today : LocalDate
today =
    date "2026-06-16"


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            case LocalDate.fromParts 1970 1 1 of
                Just fallback ->
                    fallback

                Nothing ->
                    date "1970-01-01"


fields : GoalsSettings.Model -> Maybe (List String)
fields model =
    case model of
        GoalsSettings.Ready loaded ->
            Just
                [ loaded.calorieTarget
                , loaded.proteinTargetG
                , loaded.carbsTargetG
                , loaded.fatTargetG
                ]

        _ ->
            Nothing


formError : GoalsSettings.Model -> Maybe String
formError model =
    case model of
        GoalsSettings.Ready loaded ->
            loaded.formError

        _ ->
            Nothing


requestError : GoalsSettings.Model -> Maybe String
requestError model =
    case model of
        GoalsSettings.Ready loaded ->
            loaded.requestError

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
