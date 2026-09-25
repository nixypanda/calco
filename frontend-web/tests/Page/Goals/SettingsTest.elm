module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..), GoalStatus, GoalTargets)
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as GoalsSettings
import Test exposing (Test, describe, test)


macroErrorMessage : String
macroErrorMessage =
    "Calories must equal protein*4 + carbs*4 + fat*9."


invalidNumbersMessage : String
invalidNumbersMessage =
    "Enter valid numbers for all goal fields."


positiveCaloriesMessage : String
positiveCaloriesMessage =
    "Calories must be greater than 0."


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "opening the settings loads targets and a refresh replaces a pristine form" <|
            \_ ->
                let
                    loaded : GoalsSettings.Model
                    loaded =
                        loadedFrom defaultSnapshot

                    refreshed : GoalsSettings.Model
                    refreshed =
                        step (GoalsSettings.GoalLoaded (Ok savedSnapshot)) loaded
                in
                { request = Tuple.second GoalsSettings.init
                , loaded = toScreen loaded
                , refreshed = toScreen refreshed
                }
                    |> Expect.equal
                        { request = GoalsSettings.RequestGoal
                        , loaded =
                            { phase = "ready"
                            , fields = [ "2290", "160", "255", "70" ]
                            , status = Just { source = Default, effectiveFrom = Nothing }
                            , save = Just GoalsSettings.Idle
                            , error = Nothing
                            }
                        , refreshed =
                            { phase = "ready"
                            , fields = [ "2100", "150", "240", "60" ]
                            , status = Just { source = Saved, effectiveFrom = Just today }
                            , save = Just GoalsSettings.Idle
                            , error = Nothing
                            }
                        }
        , test "an incoming refresh leaves edits the user has not saved untouched" <|
            \_ ->
                loadedFrom defaultSnapshot
                    |> step (GoalsSettings.CalorieTargetChanged "2300")
                    |> step (GoalsSettings.GoalLoaded (Ok savedSnapshot))
                    |> toScreen
                    |> Expect.equal
                        { phase = "ready"
                        , fields = [ "2300", "160", "255", "70" ]
                        , status = Just { source = Saved, effectiveFrom = Just today }
                        , save = Just GoalsSettings.Idle
                        , error = Nothing
                        }
        , test "a valid save waits for local context and submits the targets validated at submit" <|
            \_ ->
                let
                    edited : GoalsSettings.Model
                    edited =
                        loadedFrom defaultSnapshot
                            |> step (GoalsSettings.CalorieTargetChanged "2330")
                            |> step (GoalsSettings.ProteinTargetChanged "170")

                    awaiting : GoalsSettings.Model
                    awaiting =
                        step GoalsSettings.SaveClicked edited

                    typedWhileWaiting : GoalsSettings.Model
                    typedWhileWaiting =
                        step (GoalsSettings.CalorieTargetChanged "abc") awaiting

                    submitted : GoalsSettings.Model
                    submitted =
                        step
                            (GoalsSettings.LocalContextReceived
                                { date = "2026-06-16", timezone = "Asia/Kolkata" }
                            )
                            typedWhileWaiting
                in
                { request = out GoalsSettings.SaveClicked edited
                , awaiting = toScreen awaiting
                , typed = toScreen typedWhileWaiting
                , save =
                    out
                        (GoalsSettings.LocalContextReceived
                            { date = "2026-06-16", timezone = "Asia/Kolkata" }
                        )
                        typedWhileWaiting
                , submitted = saveState submitted
                }
                    |> Expect.equal
                        { request = GoalsSettings.RequestLocalContext
                        , awaiting =
                            { phase = "ready"
                            , fields = [ "2330", "170", "255", "70" ]
                            , status = Just { source = Default, effectiveFrom = Nothing }
                            , save = Just (GoalsSettings.AwaitingLocalContext validatedTargets)
                            , error = Nothing
                            }
                        , typed =
                            { phase = "ready"
                            , fields = [ "abc", "170", "255", "70" ]
                            , status = Just { source = Default, effectiveFrom = Nothing }
                            , save = Just (GoalsSettings.AwaitingLocalContext validatedTargets)
                            , error = Nothing
                            }
                        , save =
                            GoalsSettings.RequestSaveGoal
                                { localDate = "2026-06-16"
                                , deviceTimezone = "Asia/Kolkata"
                                , targets = validatedTargets
                                }
                        , submitted = Just GoalsSettings.Saving
                        }
        , test "a calorie and macro imbalance blocks save" <|
            \_ ->
                let
                    imbalanced : GoalsSettings.Model
                    imbalanced =
                        loadedFrom defaultSnapshot
                            |> step (GoalsSettings.CalorieTargetChanged "2200")
                in
                { request = out GoalsSettings.SaveClicked imbalanced
                , screen = toScreen (step GoalsSettings.SaveClicked imbalanced)
                }
                    |> Expect.equal
                        { request = GoalsSettings.NoOp
                        , screen =
                            { phase = "ready"
                            , fields = [ "2200", "160", "255", "70" ]
                            , status = Just { source = Default, effectiveFrom = Nothing }
                            , save = Just (GoalsSettings.ValidationFailed macroErrorMessage)
                            , error = Just macroErrorMessage
                            }
                        }
        , test "invalid or non-positive numbers block save" <|
            \_ ->
                let
                    nonNumeric : GoalsSettings.Model
                    nonNumeric =
                        loadedFrom defaultSnapshot
                            |> step (GoalsSettings.ProteinTargetChanged "abc")

                    nonPositive : GoalsSettings.Model
                    nonPositive =
                        loadedFrom defaultSnapshot
                            |> step (GoalsSettings.CalorieTargetChanged "-1")
                in
                { invalid =
                    toScreen (step GoalsSettings.SaveClicked nonNumeric) |> .error
                , nonPositive =
                    toScreen (step GoalsSettings.SaveClicked nonPositive) |> .error
                }
                    |> Expect.equal
                        { invalid = Just invalidNumbersMessage
                        , nonPositive = Just positiveCaloriesMessage
                        }
        , test "a save completion outside saving state is ignored" <|
            \_ ->
                let
                    edited : GoalsSettings.Model
                    edited =
                        loadedFrom defaultSnapshot
                            |> step (GoalsSettings.CalorieTargetChanged "2300")
                in
                { request =
                    out (GoalsSettings.SaveCompleted (Err Client.NetworkError)) edited
                , screen = saveState (step (GoalsSettings.SaveCompleted (Ok savedSnapshot)) edited)
                }
                    |> Expect.equal
                        { request = GoalsSettings.NoOp
                        , screen = Just GoalsSettings.Idle
                        }
        , test "an unauthorized refresh or save expires the session" <|
            \_ ->
                { refresh =
                    out
                        (GoalsSettings.GoalLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        (loadedFrom defaultSnapshot)
                , save =
                    out
                        (GoalsSettings.SaveCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        savingModel
                }
                    |> Expect.equal
                        { refresh = GoalsSettings.SessionExpired
                        , save = GoalsSettings.SessionExpired
                        }
        , test "typing during a save keeps the text and the completion refreshes the status" <|
            \_ ->
                let
                    typed : GoalsSettings.Model
                    typed =
                        step (GoalsSettings.CalorieTargetChanged "2300") savingModel

                    completed : GoalsSettings.Model
                    completed =
                        step (GoalsSettings.SaveCompleted (Ok savedSnapshot)) typed
                in
                { during = toScreen typed
                , completed = toScreen completed
                }
                    |> Expect.equal
                        { during =
                            { phase = "ready"
                            , fields = [ "2300", "160", "255", "70" ]
                            , status = Just { source = Default, effectiveFrom = Nothing }
                            , save = Just GoalsSettings.Saving
                            , error = Nothing
                            }
                        , completed =
                            { phase = "ready"
                            , fields = [ "2300", "160", "255", "70" ]
                            , status = Just { source = Saved, effectiveFrom = Just today }
                            , save = Just GoalsSettings.Idle
                            , error = Nothing
                            }
                        }
        , test "a local context that arrives outside the waiting state is ignored" <|
            \_ ->
                let
                    model : GoalsSettings.Model
                    model =
                        loadedFrom defaultSnapshot
                in
                { request =
                    out
                        (GoalsSettings.LocalContextReceived
                            { date = "2026-06-16", timezone = "Asia/Kolkata" }
                        )
                        model
                , save = saveState model
                }
                    |> Expect.equal
                        { request = GoalsSettings.NoOp
                        , save = Just GoalsSettings.Idle
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , fields : List String
    , status : Maybe GoalStatus
    , save : Maybe GoalsSettings.SaveState
    , error : Maybe String
    }


toScreen : GoalsSettings.Model -> Screen
toScreen model =
    case model of
        GoalsSettings.Loading ->
            { phase = "loading", fields = [], status = Nothing, save = Nothing, error = Nothing }

        GoalsSettings.Failed message ->
            { phase = "failed"
            , fields = []
            , status = Nothing
            , save = Nothing
            , error = Just message
            }

        GoalsSettings.Ready ready ->
            { phase = "ready"
            , fields =
                [ ready.form.calorieTarget
                , ready.form.proteinTargetG
                , ready.form.carbsTargetG
                , ready.form.fatTargetG
                ]
            , status = Just ready.status
            , save = Just ready.save
            , error = saveError ready.save
            }


saveError : GoalsSettings.SaveState -> Maybe String
saveError save =
    case save of
        GoalsSettings.ValidationFailed message ->
            Just message

        GoalsSettings.SaveFailed message ->
            Just message

        _ ->
            Nothing


savingModel : GoalsSettings.Model
savingModel =
    loadedFrom defaultSnapshot
        |> step GoalsSettings.SaveClicked
        |> step
            (GoalsSettings.LocalContextReceived
                { date = "2026-06-16", timezone = "Asia/Kolkata" }
            )


loadedFrom : GoalSnapshot -> GoalsSettings.Model
loadedFrom snapshot =
    GoalsSettings.init
        |> Tuple.first
        |> step (GoalsSettings.GoalLoaded (Ok snapshot))


saveState : GoalsSettings.Model -> Maybe GoalsSettings.SaveState
saveState model =
    (toScreen model).save


step : GoalsSettings.Msg -> GoalsSettings.Model -> GoalsSettings.Model
step msg model =
    first (GoalsSettings.update msg model)


out : GoalsSettings.Msg -> GoalsSettings.Model -> GoalsSettings.OutMsg
out msg model =
    third (GoalsSettings.update msg model)


savedTargets : GoalTargets
savedTargets =
    { calorieTarget = 2290
    , proteinTargetG = 160
    , carbsTargetG = 255
    , fatTargetG = 70
    }


validatedTargets : GoalTargets
validatedTargets =
    { calorieTarget = 2330
    , proteinTargetG = 170
    , carbsTargetG = 255
    , fatTargetG = 70
    }


defaultSnapshot : GoalSnapshot
defaultSnapshot =
    { requestedDate = today
    , effectiveFrom = Nothing
    , source = Default
    , targets = savedTargets
    }


savedSnapshot : GoalSnapshot
savedSnapshot =
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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
