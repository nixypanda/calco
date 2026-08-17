module Page.Goals.Settings exposing
    ( LoadedModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , SaveState(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Goals exposing (SaveGoalRequest)
import Data.Goals exposing (GoalSnapshot, GoalSource(..), GoalTargets)
import Element exposing (Device, Element)
import Lib.Date as LocalDate exposing (LocalDate)
import Ui
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



-- MODEL


type Model
    = Loading
    | Ready LoadedModel
    | Failed String


type alias LoadedModel =
    { today : LocalDate
    , snapshot : GoalSnapshot
    , calorieTarget : String
    , proteinTargetG : String
    , carbsTargetG : String
    , fatTargetG : String
    , saveState : SaveState
    }


type SaveState
    = Editing
    | ValidationFailed String
    | WaitingForLocalContext
    | Saving
    | SaveFailed String


type OutMsg
    = NoOp
    | RequestGoal LocalDate
    | RequestLocalContext
    | RequestSaveGoal SaveGoalRequest
    | SessionExpired


init : LocalDate -> ( Model, OutMsg )
init today =
    ( Loading, RequestGoal today )



-- UPDATE


type Msg
    = GoalLoaded (Result Client.ApiError GoalSnapshot)
    | CalorieTargetChanged String
    | ProteinTargetChanged String
    | CarbsTargetChanged String
    | FatTargetChanged String
    | SaveClicked
    | LocalContextReceived { date : String, timezone : String }
    | SaveCompleted (Result Client.ApiError GoalSnapshot)


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GoalLoaded result ->
            case result of
                Ok snapshot ->
                    ( Ready (loadedModelFor snapshot), Cmd.none, NoOp )

                Err error ->
                    case model of
                        Loading ->
                            Client.failure
                                { noOp = NoOp
                                , sessionExpired = SessionExpired
                                , applyError = \message _ -> Failed message
                                }
                                error
                                model

                        Ready loaded ->
                            Client.failure
                                { noOp = NoOp
                                , sessionExpired = SessionExpired
                                , applyError =
                                    \message _ ->
                                        Ready { loaded | saveState = SaveFailed message }
                                }
                                error
                                model

                        Failed _ ->
                            ( model, Cmd.none, NoOp )

        CalorieTargetChanged value ->
            updateField (\loaded -> { loaded | calorieTarget = value }) model

        ProteinTargetChanged value ->
            updateField (\loaded -> { loaded | proteinTargetG = value }) model

        CarbsTargetChanged value ->
            updateField (\loaded -> { loaded | carbsTargetG = value }) model

        FatTargetChanged value ->
            updateField (\loaded -> { loaded | fatTargetG = value }) model

        SaveClicked ->
            case model of
                Ready loaded ->
                    case validate loaded of
                        Ok _ ->
                            ( Ready
                                { loaded
                                    | saveState = WaitingForLocalContext
                                }
                            , Cmd.none
                            , RequestLocalContext
                            )

                        Err message ->
                            ( Ready
                                { loaded | saveState = ValidationFailed message }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        LocalContextReceived context ->
            case model of
                Ready loaded ->
                    case loaded.saveState of
                        WaitingForLocalContext ->
                            case validate loaded of
                                Ok targets ->
                                    ( Ready { loaded | saveState = Saving }
                                    , Cmd.none
                                    , RequestSaveGoal
                                        { localDate = context.date
                                        , deviceTimezone = context.timezone
                                        , targets = targets
                                        }
                                    )

                                Err message ->
                                    ( Ready
                                        { loaded
                                            | saveState = ValidationFailed message
                                        }
                                    , Cmd.none
                                    , NoOp
                                    )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case model of
                Ready loaded ->
                    case loaded.saveState of
                        Saving ->
                            case result of
                                Ok snapshot ->
                                    ( Ready (loadedModelFor snapshot), Cmd.none, NoOp )

                                Err error ->
                                    Client.failure
                                        { noOp = NoOp
                                        , sessionExpired = SessionExpired
                                        , applyError =
                                            \message _ ->
                                                Ready
                                                    { loaded
                                                        | saveState = SaveFailed message
                                                    }
                                        }
                                        error
                                        model

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


updateField : (LoadedModel -> LoadedModel) -> Model -> ( Model, Cmd Msg, OutMsg )
updateField transform model =
    case model of
        Ready loaded ->
            ( Ready
                (transform
                    { loaded
                        | saveState = Editing
                    }
                )
            , Cmd.none
            , NoOp
            )

        _ ->
            ( model, Cmd.none, NoOp )


validate : LoadedModel -> Result String GoalTargets
validate loaded =
    let
        maybeTargets : Maybe GoalTargets
        maybeTargets =
            Maybe.map4 GoalTargets
                (String.toFloat loaded.calorieTarget)
                (String.toFloat loaded.proteinTargetG)
                (String.toFloat loaded.carbsTargetG)
                (String.toFloat loaded.fatTargetG)
    in
    case maybeTargets of
        Just targets ->
            if targets.calorieTarget <= 0 then
                Err "Calories must be greater than 0."

            else if
                targets.proteinTargetG
                    < 0
                    || targets.carbsTargetG
                    < 0
                    || targets.fatTargetG
                    < 0
            then
                Err "Protein, carbs, and fat must be 0 or greater."

            else if
                abs
                    (targets.calorieTarget
                        - ((targets.proteinTargetG * 4)
                            + (targets.carbsTargetG * 4)
                            + (targets.fatTargetG * 9)
                          )
                    )
                    > 0.0001
            then
                Err "Calories must equal protein*4 + carbs*4 + fat*9."

            else
                Ok targets

        _ ->
            Err "Enter valid numbers for all goal fields."


loadedModelFor : GoalSnapshot -> LoadedModel
loadedModelFor snapshot =
    { today = snapshot.requestedDate
    , snapshot = snapshot
    , calorieTarget = String.fromFloat snapshot.targets.calorieTarget
    , proteinTargetG = String.fromFloat snapshot.targets.proteinTargetG
    , carbsTargetG = String.fromFloat snapshot.targets.carbsTargetG
    , fatTargetG = String.fromFloat snapshot.targets.fatTargetG
    , saveState = Editing
    }



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        (case model of
            Loading ->
                [ Ui.skeletonLoading theme ]

            Failed message ->
                [ Ui.errorBanner theme message ]

            Ready loaded ->
                [ Ui.maybeErrorBanner theme (requestError loaded.saveState)
                , Ui.card theme
                    [ Typography.sectionTitle theme "Daily Targets"
                    , Typography.mutedParagraph theme (statusMessage loaded.snapshot)
                    , Ui.decimalInput theme
                        { label = "Calories"
                        , value = loaded.calorieTarget
                        , onChange = CalorieTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Protein (g)"
                        , value = loaded.proteinTargetG
                        , onChange = ProteinTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Carbs (g)"
                        , value = loaded.carbsTargetG
                        , onChange = CarbsTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Fat (g)"
                        , value = loaded.fatTargetG
                        , onChange = FatTargetChanged
                        }
                    , Ui.maybeErrorBanner theme (formError loaded.saveState)
                    ]
                , Ui.primarySubmitButton device
                    theme
                    { state = Ui.submittingOrIdle (loaded.saveState == Saving)
                    , idleLabel = "Save Goals"
                    , submittingLabel = "Saving..."
                    , onPress = SaveClicked
                    }
                ]
        )


statusMessage : GoalSnapshot -> String
statusMessage snapshot =
    case ( snapshot.source, snapshot.effectiveFrom ) of
        ( Default, Nothing ) ->
            "Using backend defaults for this date."

        ( Saved, Just effectiveFrom ) ->
            "Saved goals effective from " ++ LocalDate.display effectiveFrom ++ "."

        ( Saved, Nothing ) ->
            "Saved goals are active."

        ( Default, Just effectiveFrom ) ->
            "Using backend defaults after " ++ LocalDate.display effectiveFrom ++ "."


formError : SaveState -> Maybe String
formError saveState =
    case saveState of
        ValidationFailed message ->
            Just message

        _ ->
            Nothing


requestError : SaveState -> Maybe String
requestError saveState =
    case saveState of
        SaveFailed message ->
            Just message

        _ ->
            Nothing
