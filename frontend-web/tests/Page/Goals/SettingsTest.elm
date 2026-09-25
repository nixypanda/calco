module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..), GoalStatus, GoalTargets)
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as GoalsSettings
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "a refresh replaces a pristine form" <|
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
        , test "typing during a save does not cancel the save" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.CalorieTargetChanged "2300")
                    savingModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just GoalsSettings.Saving)
        , test "a save completing under the user's typing keeps their text" <|
            \_ ->
                let
                    typedWhileSaving : GoalsSettings.Model
                    typedWhileSaving =
                        GoalsSettings.Ready
                            { pristineModel
                                | save = GoalsSettings.Saving
                                , formState = GoalsSettings.Edited
                                , form =
                                    { savedForm | calorieTarget = "2300" }
                            }
                in
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Ok defaultSnapshot))
                    typedWhileSaving
                    |> first
                    |> (\model -> ( fields model, status model ))
                    |> Expect.equal
                        ( Just [ "2300", "160", "255", "70" ]
                        , Just { source = Default, effectiveFrom = Nothing }
                        )
        , test "save failure stores request error" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    savingModel
                    |> first
                    |> saveState
                    |> Expect.equal (Just (GoalsSettings.SaveFailed networkErrorMessage))
        , test "stale save completion is ignored outside saving state" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.SaveCompleted (Err Client.NetworkError))
                    (GoalsSettings.Ready editingModel)
                    |> third
                    |> Expect.equal GoalsSettings.NoOp
        , test "goal load error on loading moves to failed" <|
            \_ ->
                GoalsSettings.update
                    (GoalsSettings.GoalLoaded (Err Client.NetworkError))
                    GoalsSettings.Loading
                    |> first
                    |> Expect.equal (GoalsSettings.Failed networkErrorMessage)
        , test "retry from failed returns to loading and requests the goal" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        GoalsSettings.update
                            GoalsSettings.RetryClicked
                            (GoalsSettings.Failed networkErrorMessage)
                in
                ( model, outMsg )
                    |> Expect.equal ( GoalsSettings.Loading, GoalsSettings.RequestGoal )
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
    , formState = GoalsSettings.Pristine
    , save = GoalsSettings.Idle
    }


editingModel : GoalsSettings.ReadyModel
editingModel =
    { pristineModel | formState = GoalsSettings.Edited }


readyWith : (GoalsSettings.Form -> GoalsSettings.Form) -> GoalsSettings.Model
readyWith transform =
    GoalsSettings.Ready { editingModel | form = transform editingModel.form }


savingModel : GoalsSettings.Model
savingModel =
    GoalsSettings.Ready { pristineModel | save = GoalsSettings.Saving }


savedTargets : GoalTargets
savedTargets =
    { calorieTarget = 2290
    , proteinTargetG = 160
    , carbsTargetG = 255
    , fatTargetG = 70
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
