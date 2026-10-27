module Page.Diary.SettingsTest exposing (tests)

import Api.Client as Client
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Page.Diary.Settings as Settings
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


validationMessage : String
validationMessage =
    "Select at least one meal slot."


tests : Test
tests =
    describe "Page.Diary.Settings"
        [ test "a user loads preferences, toggles a slot, and saves the canonical selection" <|
            \_ ->
                let
                    ( loading, initialOut ) =
                        Settings.init

                    loaded : Settings.Model
                    loaded =
                        step
                            (Settings.PrefsLoaded
                                (Ok { enabledMealSlots = [ LateNightSnack, Breakfast ] })
                            )
                            loading

                    toggled : Settings.Model
                    toggled =
                        step (Settings.SlotToggled Lunch True) loaded

                    saveRequest : Settings.OutMsg
                    saveRequest =
                        out Settings.SaveClicked toggled

                    saved : Settings.Model
                    saved =
                        step
                            (Settings.SaveCompleted
                                (Ok { enabledMealSlots = [ Dinner, Lunch ] })
                            )
                            (step Settings.SaveClicked toggled)
                in
                { initial = initialOut
                , loaded = toScreen loaded
                , saveRequest = saveRequest
                , saved = toScreen saved
                }
                    |> Expect.equal
                        { initial = Settings.RequestPrefs
                        , loaded =
                            { phase = "ready"
                            , selected = [ Breakfast, LateNightSnack ]
                            , saveState = Just Settings.Editing
                            , error = Nothing
                            }
                        , saveRequest =
                            Settings.RequestSave
                                { enabledMealSlots = [ Breakfast, Lunch, LateNightSnack ] }
                        , saved =
                            { phase = "ready"
                            , selected = [ Lunch, Dinner ]
                            , saveState = Just Settings.Saved
                            , error = Nothing
                            }
                        }
        , test "clearing every meal slot blocks save with a validation message" <|
            \_ ->
                let
                    cleared : Settings.Model
                    cleared =
                        Settings.init
                            |> Tuple.first
                            |> step
                                (Settings.PrefsLoaded
                                    (Ok { enabledMealSlots = [ Breakfast ] })
                                )
                            |> step (Settings.SlotToggled Breakfast False)
                in
                { request = out Settings.SaveClicked cleared
                , screen = toScreen (step Settings.SaveClicked cleared)
                }
                    |> Expect.equal
                        { request = Settings.NoOp
                        , screen =
                            { phase = "ready"
                            , selected = []
                            , saveState = Just (Settings.ValidationFailed validationMessage)
                            , error = Just validationMessage
                            }
                        }
        , test "a failed save keeps the selection and a retry re-requests it" <|
            \_ ->
                let
                    saving : Settings.Model
                    saving =
                        Settings.init
                            |> Tuple.first
                            |> step
                                (Settings.PrefsLoaded
                                    (Ok { enabledMealSlots = [ Breakfast, Lunch ] })
                                )
                            |> step Settings.SaveClicked

                    failed : Settings.Model
                    failed =
                        step
                            (Settings.SaveCompleted (Err Client.NetworkError))
                            saving

                    retried : Settings.Model
                    retried =
                        step Settings.SaveClicked failed
                in
                { failed = toScreen failed
                , retryRequest = out Settings.SaveClicked failed
                , retried = saveState retried
                }
                    |> Expect.equal
                        { failed =
                            { phase = "ready"
                            , selected = [ Breakfast, Lunch ]
                            , saveState = Just (Settings.SaveFailed networkErrorMessage)
                            , error = Just networkErrorMessage
                            }
                        , retryRequest =
                            Settings.RequestSave
                                { enabledMealSlots = [ Breakfast, Lunch ] }
                        , retried = Just Settings.Saving
                        }
        , test "an unauthorized load or save expires the session" <|
            \_ ->
                let
                    saving : Settings.Model
                    saving =
                        Settings.init
                            |> Tuple.first
                            |> step
                                (Settings.PrefsLoaded
                                    (Ok { enabledMealSlots = [ Breakfast ] })
                                )
                            |> step Settings.SaveClicked
                in
                { load =
                    Settings.update
                        (Settings.PrefsLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        Settings.Loading
                        |> third
                , save =
                    Settings.update
                        (Settings.SaveCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        saving
                        |> third
                }
                    |> Expect.equal
                        { load = Settings.SessionExpired
                        , save = Settings.SessionExpired
                        }
        , test "a failed preferences load shows an error and retrying re-requests them" <|
            \_ ->
                let
                    failed : Settings.Model
                    failed =
                        step (Settings.PrefsLoaded (Err Client.NetworkError)) Settings.Loading
                in
                { failed = toScreen failed
                , retryRequest = out Settings.RetryClicked failed
                , retrying = toScreen (step Settings.RetryClicked failed)
                }
                    |> Expect.equal
                        { failed =
                            { phase = "failed"
                            , selected = []
                            , saveState = Nothing
                            , error = Just networkErrorMessage
                            }
                        , retryRequest = Settings.RequestPrefs
                        , retrying =
                            { phase = "loading"
                            , selected = []
                            , saveState = Nothing
                            , error = Nothing
                            }
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , selected : List MealSlot
    , saveState : Maybe Settings.SaveState
    , error : Maybe String
    }


toScreen : Settings.Model -> Screen
toScreen model =
    case model of
        Settings.Loading ->
            { phase = "loading", selected = [], saveState = Nothing, error = Nothing }

        Settings.Failed message ->
            { phase = "failed", selected = [], saveState = Nothing, error = Just message }

        Settings.Ready ready ->
            { phase = "ready"
            , selected = ready.selected
            , saveState = Just ready.saveState
            , error = saveError ready.saveState
            }


saveError : Settings.SaveState -> Maybe String
saveError state =
    case state of
        Settings.ValidationFailed message ->
            Just message

        Settings.SaveFailed message ->
            Just message

        _ ->
            Nothing


saveState : Settings.Model -> Maybe Settings.SaveState
saveState model =
    (toScreen model).saveState


step : Settings.Msg -> Settings.Model -> Settings.Model
step msg model =
    first (Settings.update msg model)


out : Settings.Msg -> Settings.Model -> Settings.OutMsg
out msg model =
    third (Settings.update msg model)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
