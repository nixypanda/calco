module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..), GoalStatus, GoalTargets)
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as GoalsSettings
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "init requests today's goals" <|
            \_ ->
                GoalsSettings.init
                    |> Tuple.second
                    |> Expect.equal GoalsSettings.RequestGoal
        , test "goal load success populates the form" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok savedSnapshot))
                    GoalsSettings.Loading
                    |> first
                    |> fields
                    |> Expect.equal (Just [ "2290", "160", "255", "70" ])
        , test "a freshly loaded form is pristine" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok savedSnapshot))
                    GoalsSettings.Loading
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Pristine)
        , test "a refresh replaces a pristine form" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok updatedSnapshot))
                    (GoalsSettings.Ready pristineModel)
                    |> first
                    |> fields
                    |> Expect.equal (Just [ "2100", "150", "240", "60" ])
        , test "a refresh keeps edits the user has not saved" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok updatedSnapshot))
                    (GoalsSettings.Ready editingModel)
                    |> first
                    |> fields
                    |> Expect.equal (Just [ "2290", "160", "255", "70" ])
        , test "a refresh still updates the status of an edited form" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Ok defaultSnapshot))
                    (GoalsSettings.Ready editingModel)
                    |> first
                    |> status
                    |> Expect.equal
                        (Just { source = Default, effectiveFrom = Nothing })
        , test "invalid macro formula blocks save" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        GoalsSettings.update GoalsSettings.SaveClicked
                            (readyWith (\form -> { form | calorieTarget = "2200" }))
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
                GoalsSettings.update GoalsSettings.SaveClicked (GoalsSettings.Ready editingModel)
                    |> third
                    |> Expect.equal GoalsSettings.RequestLocalContext
        , test "save click carries the validated targets into the wait" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked (GoalsSettings.Ready editingModel)
                    |> first
                    |> saveState
                    |> Expect.equal
                        (Just
                            (GoalsSettings.AwaitingLocalContext savedTargets)
                        )
        , test "invalid numeric input blocks save with validation failure" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked
                    (readyWith (\form -> { form | proteinTargetG = "abc" }))
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
                            , targets = savedTargets
                            }
                        )
        , test "local context saves the targets validated at submit, not the current text" <|
            \_ ->
                let
                    editedWhileWaiting : GoalsSettings.Model
                    editedWhileWaiting =
                        GoalsSettings.Ready
                            { editingModel
                                | form =
                                    { calorieTarget = "abc"
                                    , proteinTargetG = "abc"
                                    , carbsTargetG = "abc"
                                    , fatTargetG = "abc"
                                    }
                                , save = GoalsSettings.AwaitingLocalContext savedTargets
                            }
                in
                GoalsSettings.update
                    (GoalsSettings.LocalContextReceived
                        { date = "2026-06-16"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    editedWhileWaiting
                    |> third
                    |> Expect.equal
                        (GoalsSettings.RequestSaveGoal
                            { localDate = "2026-06-16"
                            , deviceTimezone = "Asia/Kolkata"
                            , targets = savedTargets
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
                    (GoalsSettings.Ready editingModel)
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
        , test "save success returns the form to pristine" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Ok updatedSnapshot))
                    savingModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Pristine)
        , test "save failure stores request error" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    savingModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just (GoalsSettings.SaveFailed "Network error"))
        , test "stale save completion is ignored outside saving state" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    (GoalsSettings.Ready editingModel)
                    |> third
                    |> Expect.equal GoalsSettings.NoOp
        , test "editing after failure clears failure state" <|
            \_ ->
                let
                    failedModel : GoalsSettings.Model
                    failedModel =
                        GoalsSettings.Ready
                            { editingModel
                                | save = GoalsSettings.SaveFailed "Network error"
                            }
                in
                GoalsSettings.update
                    (GoalsSettings.CalorieTargetChanged "2300")
                    failedModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Editing)
        , test "editing a pristine form takes it out of pristine" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.CalorieTargetChanged "2300")
                    (GoalsSettings.Ready pristineModel)
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
        , test "a failed refresh leaves a loaded page untouched" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err Client.NetworkError))
                    (GoalsSettings.Ready editingModel)
                    |> first
                    |> Expect.equal (GoalsSettings.Ready editingModel)
        , test "goal load 401 on loading triggers session expired" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err (Client.BadStatus 401 "" "")))
                    GoalsSettings.Loading
                    |> third
                    |> Expect.equal GoalsSettings.SessionExpired
        , test "a 401 refresh on a loaded page still expires the session" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err (Client.BadStatus 401 "" "")))
                    (GoalsSettings.Ready editingModel)
                    |> third
                    |> Expect.equal GoalsSettings.SessionExpired
        , test "save completed 401 triggers session expired" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err (Client.BadStatus 401 "" "")))
                    savingModel
                    |> third
                    |> Expect.equal GoalsSettings.SessionExpired
        , test "negative calorie target blocks save" <|
            \_ ->
                GoalsSettings.update GoalsSettings.SaveClicked
                    (readyWith (\form -> { form | calorieTarget = "-1" }))
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
                GoalsSettings.update GoalsSettings.SaveClicked
                    (readyWith (\form -> { form | calorieTarget = "0" }))
                    |> first
                    |> saveState
                    |> Expect.equal
                        (Just
                            (GoalsSettings.ValidationFailed
                                "Calories must be greater than 0."
                            )
                        )
        ]


savedForm : GoalsSettings.Form
savedForm =
    { calorieTarget = "2290"
    , proteinTargetG = "160"
    , carbsTargetG = "255"
    , fatTargetG = "70"
    }


pristineModel : GoalsSettings.ReadyModel
pristineModel =
    { status = { source = Saved, effectiveFrom = Just today }
    , form = savedForm
    , save = GoalsSettings.Pristine
    }


editingModel : GoalsSettings.ReadyModel
editingModel =
    { pristineModel | save = GoalsSettings.Editing }


readyWith : (GoalsSettings.Form -> GoalsSettings.Form) -> GoalsSettings.Model
readyWith transform =
    GoalsSettings.Ready { editingModel | form = transform editingModel.form }


waitingModel : GoalsSettings.Model
waitingModel =
    GoalsSettings.Ready
        { editingModel | save = GoalsSettings.AwaitingLocalContext savedTargets }


savingModel : GoalsSettings.Model
savingModel =
    GoalsSettings.Ready { editingModel | save = GoalsSettings.Saving }


savedTargets : GoalTargets
savedTargets =
    { calorieTarget = 2290
    , proteinTargetG = 160
    , carbsTargetG = 255
    , fatTargetG = 70
    }


savedSnapshot : GoalSnapshot
savedSnapshot =
    { requestedDate = today
    , effectiveFrom = Just today
    , source = Saved
    , targets = savedTargets
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


defaultSnapshot : GoalSnapshot
defaultSnapshot =
    { requestedDate = today
    , effectiveFrom = Nothing
    , source = Default
    , targets = savedTargets
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
        GoalsSettings.Ready ready ->
            Just
                [ ready.form.calorieTarget
                , ready.form.proteinTargetG
                , ready.form.carbsTargetG
                , ready.form.fatTargetG
                ]

        _ ->
            Nothing


status : GoalsSettings.Model -> Maybe GoalStatus
status model =
    case model of
        GoalsSettings.Ready ready ->
            Just ready.status

        _ ->
            Nothing


saveState : GoalsSettings.Model -> Maybe GoalsSettings.SaveState
saveState model =
    case model of
        GoalsSettings.Ready ready ->
            Just ready.save

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
