module Page.Goals.Settings exposing
    ( Form
    , FormState(..)
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , ReadyModel
    , SaveState(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Goals exposing (SaveGoalRequest)
import Data.Goals as Goals exposing (GoalSnapshot, GoalSource(..), GoalStatus, GoalTargets)
import Data.LocalContext exposing (LocalContext)
import Element exposing (Device, Element)
import Lib.Date as LocalDate
import Ui
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



-- MODEL


type Model
    = Loading
    | Ready ReadyModel
    | Failed String


type alias ReadyModel =
    { status : GoalStatus
    , form : Form
    , formState : FormState
    , save : SaveState
    }


type alias Form =
    { calorieTarget : String
    , proteinTargetG : String
    , carbsTargetG : String
    , fatTargetG : String
    }


type FormState
    = Pristine
    | Edited


type SaveState
    = Idle
    | ValidationFailed String
    | AwaitingLocalContext GoalTargets
    | Saving
    | SaveFailed String


type OutMsg
    = NoOp
    | RequestGoal
    | RequestLocalContext
    | RequestSaveGoal SaveGoalRequest
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestGoal )



-- UPDATE


type Msg
    = GoalLoaded (Result Client.ApiError GoalSnapshot)
    | CalorieTargetChanged String
    | ProteinTargetChanged String
    | CarbsTargetChanged String
    | FatTargetChanged String
    | SaveClicked
    | LocalContextReceived LocalContext
    | SaveCompleted (Result Client.ApiError GoalSnapshot)


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GoalLoaded (Ok snapshot) ->
            case model of
                Ready ready ->
                    ( Ready (refreshedWith snapshot ready), Cmd.none, NoOp )

                _ ->
                    ( Ready (readyModelFor snapshot), Cmd.none, NoOp )

        GoalLoaded (Err error) ->
            case model of
                Ready _ ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \_ unchanged -> unchanged
                        }
                        error
                        model

                Failed _ ->
                    ( model, Cmd.none, NoOp )

                Loading ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message _ -> Failed message
                        }
                        error
                        model

        CalorieTargetChanged value ->
            updateForm (\form -> { form | calorieTarget = value }) model

        ProteinTargetChanged value ->
            updateForm (\form -> { form | proteinTargetG = value }) model

        CarbsTargetChanged value ->
            updateForm (\form -> { form | carbsTargetG = value }) model

        FatTargetChanged value ->
            updateForm (\form -> { form | fatTargetG = value }) model

        SaveClicked ->
            case model of
                Ready ready ->
                    case validate ready.form of
                        Ok targets ->
                            ( Ready
                                { ready
                                    | save = AwaitingLocalContext targets
                                    , formState = Pristine
                                }
                            , Cmd.none
                            , RequestLocalContext
                            )

                        Err message ->
                            ( Ready { ready | save = ValidationFailed message }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        LocalContextReceived context ->
            case model of
                Ready ready ->
                    case ready.save of
                        AwaitingLocalContext targets ->
                            ( Ready { ready | save = Saving }
                            , Cmd.none
                            , RequestSaveGoal
                                { localDate = context.date
                                , deviceTimezone = context.timezone
                                , targets = targets
                                }
                            )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case model of
                Ready ready ->
                    case ( ready.save, result ) of
                        ( Saving, Ok snapshot ) ->
                            ( Ready (refreshedWith snapshot { ready | save = Idle })
                            , Cmd.none
                            , NoOp
                            )

                        ( Saving, Err error ) ->
                            Client.failure
                                { noOp = NoOp
                                , sessionExpired = SessionExpired
                                , applyError =
                                    \message _ ->
                                        Ready { ready | save = SaveFailed message }
                                }
                                error
                                model

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


updateForm : (Form -> Form) -> Model -> ( Model, Cmd Msg, OutMsg )
updateForm transform model =
    case model of
        Ready ready ->
            ( Ready
                { ready
                    | form = transform ready.form
                    , formState = Edited
                    , save = editingSave ready.save
                }
            , Cmd.none
            , NoOp
            )

        _ ->
            ( model, Cmd.none, NoOp )


refreshedWith : GoalSnapshot -> ReadyModel -> ReadyModel
refreshedWith snapshot ready =
    case ready.formState of
        Pristine ->
            { ready
                | status = Goals.statusOf snapshot
                , form = formFor snapshot.targets
            }

        Edited ->
            { ready | status = Goals.statusOf snapshot }


editingSave : SaveState -> SaveState
editingSave save =
    case save of
        ValidationFailed _ ->
            Idle

        SaveFailed _ ->
            Idle

        _ ->
            save


validate : Form -> Result String GoalTargets
validate form =
    let
        maybeTargets : Maybe GoalTargets
        maybeTargets =
            Maybe.map4 GoalTargets
                (String.toFloat form.calorieTarget)
                (String.toFloat form.proteinTargetG)
                (String.toFloat form.carbsTargetG)
                (String.toFloat form.fatTargetG)
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


readyModelFor : GoalSnapshot -> ReadyModel
readyModelFor snapshot =
    { status = Goals.statusOf snapshot
    , form = formFor snapshot.targets
    , formState = Pristine
    , save = Idle
    }


formFor : GoalTargets -> Form
formFor targets =
    { calorieTarget = String.fromFloat targets.calorieTarget
    , proteinTargetG = String.fromFloat targets.proteinTargetG
    , carbsTargetG = String.fromFloat targets.carbsTargetG
    , fatTargetG = String.fromFloat targets.fatTargetG
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

            Ready ready ->
                [ Ui.maybeErrorBanner theme (requestError ready.save)
                , Ui.card theme
                    [ Typography.sectionTitle theme "Daily Targets"
                    , Typography.mutedParagraph theme (statusMessage ready.status)
                    , Ui.decimalInput theme
                        { label = "Calories"
                        , value = ready.form.calorieTarget
                        , onChange = CalorieTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Protein (g)"
                        , value = ready.form.proteinTargetG
                        , onChange = ProteinTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Carbs (g)"
                        , value = ready.form.carbsTargetG
                        , onChange = CarbsTargetChanged
                        }
                    , Ui.decimalInput theme
                        { label = "Fat (g)"
                        , value = ready.form.fatTargetG
                        , onChange = FatTargetChanged
                        }
                    , Ui.maybeErrorBanner theme (formError ready.save)
                    ]
                , Ui.primarySubmitButton device
                    theme
                    { state = Ui.submittingOrIdle (isSaving ready.save)
                    , idleLabel = "Save Goals"
                    , submittingLabel = "Saving..."
                    , onPress = SaveClicked
                    }
                ]
        )


statusMessage : GoalStatus -> String
statusMessage status =
    case ( status.source, status.effectiveFrom ) of
        ( Default, Nothing ) ->
            "Using backend defaults for this date."

        ( Saved, Just effectiveFrom ) ->
            "Saved goals effective from " ++ LocalDate.display effectiveFrom ++ "."

        ( Saved, Nothing ) ->
            "Saved goals are active."

        ( Default, Just effectiveFrom ) ->
            "Using backend defaults after " ++ LocalDate.display effectiveFrom ++ "."


isSaving : SaveState -> Bool
isSaving save =
    case save of
        AwaitingLocalContext _ ->
            True

        Saving ->
            True

        _ ->
            False


formError : SaveState -> Maybe String
formError save =
    case save of
        ValidationFailed message ->
            Just message

        _ ->
            Nothing


requestError : SaveState -> Maybe String
requestError save =
    case save of
        SaveFailed message ->
            Just message

        _ ->
            Nothing
