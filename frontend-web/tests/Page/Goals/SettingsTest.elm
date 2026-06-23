module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
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
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok savedSnapshot))
                    GoalsSettings.Loading
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
                ( outMsg, saveState model )
                    |> Expect.equal
                        ( GoalsSettings.NoOp
                        , Just
                            (GoalsSettings.ValidationFailed
                                "Calories must equal protein*4 + carbs*4 + fat*9."
                            )
                        )
        , test "save click requests local context after validation" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked (GoalsSettings.Ready loadedModel)
                    |> third
                    |> Expect.equal GoalsSettings.RequestLocalContext
        , test "invalid numeric input blocks save with validation failure" <|
            \_ ->
                let
                    invalidModel : GoalsSettings.Model
                    invalidModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | proteinTargetG = "abc"
                            }
                in
                GoalsSettings.update GoalsSettings.SaveClicked invalidModel
                    |> first
                    |> saveState
                    |> Expect.equal
                        (Just
                            (GoalsSettings.ValidationFailed
                                "Enter valid numbers for all goal fields."
                            )
                        )
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
        , test "stale local context is ignored outside waiting state" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.LocalContextReceived
                        { date = "2026-06-16"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    (GoalsSettings.Ready loadedModel)
                    |> third
                    |> Expect.equal GoalsSettings.NoOp
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
                saveState model
                    |> Expect.equal (Just (GoalsSettings.SaveFailed "Network error"))
        , test "stale save completion is ignored outside saving state" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    (GoalsSettings.Ready loadedModel)
                    |> third
                    |> Expect.equal GoalsSettings.NoOp
        , test "editing after failure clears failure state" <|
            \_ ->
                let
                    failedModel : GoalsSettings.Model
                    failedModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | saveState = GoalsSettings.SaveFailed "Network error"
                            }
                in
                GoalsSettings.update
                    (GoalsSettings.CalorieTargetChanged "2300")
                    failedModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Editing)
        , test "protein target change updates protein field" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.ProteinTargetChanged "180")
                    (GoalsSettings.Ready loadedModel)
                    |> first
                    |> (\m -> ( fields m, saveState m ))
                    |> Expect.equal
                        ( Just [ "2290", "180", "255", "70" ]
                        , Just GoalsSettings.Editing
                        )
        , test "carbs target change updates carbs field" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.CarbsTargetChanged "300")
                    (GoalsSettings.Ready loadedModel)
                    |> first
                    |> (\m -> ( fields m, saveState m ))
                    |> Expect.equal
                        ( Just [ "2290", "160", "300", "70" ]
                        , Just GoalsSettings.Editing
                        )
        , test "fat target change updates fat field" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.FatTargetChanged "80")
                    (GoalsSettings.Ready loadedModel)
                    |> first
                    |> (\m -> ( fields m, saveState m ))
                    |> Expect.equal
                        ( Just [ "2290", "160", "255", "80" ]
                        , Just GoalsSettings.Editing
                        )
        , test "protein target change clears save failure" <|
            \_ ->
                let
                    failedModel : GoalsSettings.Model
                    failedModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | saveState = GoalsSettings.SaveFailed "error"
                            }
                in
                GoalsSettings.update
                    (GoalsSettings.ProteinTargetChanged "180")
                    failedModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Editing)
        , test "goal load error on loading moves to failed" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err Client.NetworkError))
                    GoalsSettings.Loading
                    |> first
                    |> Expect.equal (GoalsSettings.Failed "Network error")
        , test "goal load error on ready stores save error" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err Client.NetworkError))
                    (GoalsSettings.Ready loadedModel)
                    |> first
                    |> saveState
                    |> Expect.equal (Just (GoalsSettings.SaveFailed "Network error"))
        , test "goal load 401 on loading triggers session expired" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err (Client.BadStatus 401 "" "")))
                    GoalsSettings.Loading
                    |> third
                    |> Expect.equal GoalsSettings.SessionExpired
        , test "calorie target change on loading is no-op" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.CalorieTargetChanged "100")
                    GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "protein target change on loading is no-op" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.ProteinTargetChanged "100")
                    GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "carbs target change on loading is no-op" <|
            \_ ->
                GoalsSettings.update (GoalsSettings.CarbsTargetChanged "100") GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "fat target change on loading is no-op" <|
            \_ ->
                GoalsSettings.update (GoalsSettings.FatTargetChanged "100") GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "save click on loading is no-op" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "save click on failed is no-op" <|
            \_ ->
                GoalsSettings.update
                    GoalsSettings.SaveClicked
                    (GoalsSettings.Failed "old")
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Failed "old", GoalsSettings.NoOp )
        , test "local context received on loading is no-op" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.LocalContextReceived
                        { date = "2026-06-16"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "save completed on loading is no-op" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    GoalsSettings.Loading
                    |> (\( m, _, out ) -> ( m, out ))
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.NoOp )
        , test "save completed 401 triggers session expired" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err (Client.BadStatus 401 "" "")))
                    savingModel
                    |> third
                    |> Expect.equal GoalsSettings.SessionExpired
        , test "negative calorie target blocks save" <|
            \_ ->
                let
                    badModel : GoalsSettings.Model
                    badModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | calorieTarget = "-1"
                            }
                in
                GoalsSettings.update GoalsSettings.SaveClicked badModel
                    |> first
                    |> saveState
                    |> Expect.equal
                        (Just
                            (GoalsSettings.ValidationFailed
                                "Calories must be greater than 0."
                            )
                        )
        , test "zero calorie target blocks save" <|
            \_ ->
                let
                    badModel : GoalsSettings.Model
                    badModel =
                        GoalsSettings.Ready
                            { loadedModel
                                | calorieTarget = "0"
                            }
                in
                GoalsSettings.update GoalsSettings.SaveClicked badModel
                    |> first
                    |> saveState
                    |> Expect.equal
                        (Just
                            (GoalsSettings.ValidationFailed
                                "Calories must be greater than 0."
                            )
                        )
        ]


loadedModel : GoalsSettings.LoadedModel
loadedModel =
    { today = today
    , snapshot = savedSnapshot
    , calorieTarget = "2290"
    , proteinTargetG = "160"
    , carbsTargetG = "255"
    , fatTargetG = "70"
    , saveState = GoalsSettings.Editing
    }


waitingModel : GoalsSettings.Model
waitingModel =
    GoalsSettings.Ready { loadedModel | saveState = GoalsSettings.WaitingForLocalContext }


savingModel : GoalsSettings.Model
savingModel =
    GoalsSettings.Ready { loadedModel | saveState = GoalsSettings.Saving }


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


saveState : GoalsSettings.Model -> Maybe GoalsSettings.SaveState
saveState model =
    case model of
        GoalsSettings.Ready loaded ->
            Just loaded.saveState

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
