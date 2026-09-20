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
import I18n
import Lib.Date as LocalDate
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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
    | RetryClicked


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

        RetryClicked ->
            ( Loading, Cmd.none, RequestGoal )


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
                Err (I18n.t TidGoalSettingsErrorCaloriesPositive)

            else if
                targets.proteinTargetG
                    < 0
                    || targets.carbsTargetG
                    < 0
                    || targets.fatTargetG
                    < 0
            then
                Err (I18n.t TidGoalSettingsErrorMacrosNonNegative)

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
                Err (I18n.t TidGoalSettingsErrorCaloriesMacros)

            else
                Ok targets

        _ ->
            Err (I18n.t TidGoalSettingsErrorInvalidNumbers)


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
    UiPage.pageContainer
        (case model of
            Loading ->
                [ goalsSettingsSkeleton theme ]

            Failed message ->
                [ Feedback.errorRetry theme device { message = message, onRetry = RetryClicked } ]

            Ready ready ->
                [ Feedback.maybeErrorBanner theme (requestError ready.save)
                , Surface.section theme
                    { header =
                        Just
                            (Surface.sectionHeader
                                { title =
                                    Typography.sectionTitle theme
                                        (I18n.t TidGoalSettingsDailyTargetsTitle)
                                , description =
                                    Just
                                        (Typography.mutedParagraph theme
                                            (statusMessage ready.status)
                                        )
                                , trailing = Nothing
                                }
                            )
                    , body =
                        [ UiInput.numericInput theme
                            { label = I18n.t TidGoalSettingsCalories
                            , value = ready.form.calorieTarget
                            , onChange = CalorieTargetChanged
                            }
                        , UiInput.numericInput theme
                            { label = I18n.t TidGoalSettingsProtein
                            , value = ready.form.proteinTargetG
                            , onChange = ProteinTargetChanged
                            }
                        , UiInput.numericInput theme
                            { label = I18n.t TidGoalSettingsCarbs
                            , value = ready.form.carbsTargetG
                            , onChange = CarbsTargetChanged
                            }
                        , UiInput.numericInput theme
                            { label = I18n.t TidGoalSettingsFat
                            , value = ready.form.fatTargetG
                            , onChange = FatTargetChanged
                            }
                        , Feedback.maybeErrorBanner theme (formError ready.save)
                        ]
                    , footer = Nothing
                    }
                , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t TidGoalSettingsSave
                    , onPress = SaveClicked
                    , submitState = Just (Button.submittingOrIdle (isSaving ready.save))
                    , submittingLabel = Just (I18n.t TidCommonSaving)
                    , trailing = Nothing
                    }
                ]
        )


statusMessage : GoalStatus -> String
statusMessage status =
    case ( status.source, status.effectiveFrom ) of
        ( Default, Nothing ) ->
            I18n.t TidGoalSettingsStatusDefaultForDate

        ( Saved, Just effectiveFrom ) ->
            I18n.t (TidGoalSettingsStatusSavedFrom (LocalDate.display effectiveFrom))

        ( Saved, Nothing ) ->
            I18n.t TidGoalSettingsStatusSavedActive

        ( Default, Just effectiveFrom ) ->
            I18n.t (TidGoalSettingsStatusDefaultAfter (LocalDate.display effectiveFrom))


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


goalsSettingsSkeleton : Theme -> Element msg
goalsSettingsSkeleton theme =
    Surface.section theme
        { header =
            Just
                (Skeleton.barCustom theme
                    { width = Element.px 160, height = 24 }
                )
        , body =
            [ Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.button theme
            ]
        , footer = Nothing
        }
