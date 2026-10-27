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
import Data.LocalCtx exposing (LocalCtx)
import Element exposing (Element)
import I18n
import Lib.Date as LocalDate
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Env exposing (Env)
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
    { status : GoalStatus, form : Form, formState : FormState, save : SaveState }


type alias Form =
    { calorieTarget : String, proteinTargetG : String, carbsTargetG : String, fatTargetG : String }


type FormState
    = Pristine
    | Edited


type SaveState
    = Idle
    | ValidationFailed String
    | AwaitingLocalCtx GoalTargets
    | Saving
    | SaveFailed String


type OutMsg
    = NoOp
    | RequestGoal
    | RequestLocalCtx
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
    | LocalCtxReceived LocalCtx
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
                                    | save = AwaitingLocalCtx targets
                                    , formState = Pristine
                                }
                            , Cmd.none
                            , RequestLocalCtx
                            )

                        Err message ->
                            ( Ready { ready | save = ValidationFailed message }, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        LocalCtxReceived context ->
            case model of
                Ready ready ->
                    case ready.save of
                        AwaitingLocalCtx targets ->
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
            { ready | status = Goals.statusOf snapshot, form = formFor snapshot.targets }

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
                Err (I18n.en TidGoalSettingsErrorCaloriesPositive)

            else if
                targets.proteinTargetG
                    < 0
                    || targets.carbsTargetG
                    < 0
                    || targets.fatTargetG
                    < 0
            then
                Err (I18n.en TidGoalSettingsErrorMacrosNonNegative)

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
                Err (I18n.en TidGoalSettingsErrorCaloriesMacros)

            else
                Ok targets

        _ ->
            Err (I18n.en TidGoalSettingsErrorInvalidNumbers)


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


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        (case model of
            Loading ->
                [ goalsSettingsSkeleton env.theme ]

            Failed message ->
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = message, onRetry = RetryClicked }
                ]

            Ready ready ->
                [ case ready.save of
                    SaveFailed message ->
                        Feedback.errorBanner env.theme message

                    Idle ->
                        Element.none

                    ValidationFailed _ ->
                        Element.none

                    AwaitingLocalCtx _ ->
                        Element.none

                    Saving ->
                        Element.none
                , Surface.section env.theme
                    { header =
                        Just
                            (Surface.sectionHeader
                                { title =
                                    Typography.sectionTitle env.theme
                                        (I18n.t env.language TidGoalSettingsDailyTargetsTitle)
                                , description =
                                    Just
                                        (Typography.mutedParagraph env.theme
                                            (statusMessage env.language ready.status)
                                        )
                                , trailing = Nothing
                                }
                            )
                    , body =
                        [ UiInput.numericInput env.theme
                            { label = I18n.t env.language TidGoalSettingsCalories
                            , value = ready.form.calorieTarget
                            , onChange = CalorieTargetChanged
                            }
                        , UiInput.numericInput env.theme
                            { label = I18n.t env.language TidGoalSettingsProtein
                            , value = ready.form.proteinTargetG
                            , onChange = ProteinTargetChanged
                            }
                        , UiInput.numericInput env.theme
                            { label = I18n.t env.language TidGoalSettingsCarbs
                            , value = ready.form.carbsTargetG
                            , onChange = CarbsTargetChanged
                            }
                        , UiInput.numericInput env.theme
                            { label = I18n.t env.language TidGoalSettingsFat
                            , value = ready.form.fatTargetG
                            , onChange = FatTargetChanged
                            }
                        , case ready.save of
                            ValidationFailed message ->
                                Feedback.errorBanner env.theme message

                            Idle ->
                                Element.none

                            AwaitingLocalCtx _ ->
                                Element.none

                            Saving ->
                                Element.none

                            SaveFailed _ ->
                                Element.none
                        ]
                    , footer = Nothing
                    }
                , Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidGoalSettingsSave
                    , onPress = SaveClicked
                    , submitState = Just (Button.submittingOrIdle (isSaving ready.save))
                    , submittingLabel = Just (I18n.t env.language TidCommonSaving)
                    , trailing = Nothing
                    }
                ]
        )


statusMessage : Language -> GoalStatus -> String
statusMessage language status =
    case ( status.source, status.effectiveFrom ) of
        ( Default, Nothing ) ->
            I18n.t language TidGoalSettingsStatusDefaultForDate

        ( Saved, Just effectiveFrom ) ->
            I18n.t language
                (TidGoalSettingsStatusSavedFrom (LocalDate.display language effectiveFrom))

        ( Saved, Nothing ) ->
            I18n.t language TidGoalSettingsStatusSavedActive

        ( Default, Just effectiveFrom ) ->
            I18n.t language
                (TidGoalSettingsStatusDefaultAfter (LocalDate.display language effectiveFrom))


isSaving : SaveState -> Bool
isSaving save =
    case save of
        AwaitingLocalCtx _ ->
            True

        Saving ->
            True

        _ ->
            False


goalsSettingsSkeleton : Theme -> Element msg
goalsSettingsSkeleton theme =
    Surface.section theme
        { header =
            Just (Skeleton.barCustom theme { width = Element.px 160, height = 24 })
        , body =
            [ Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.input theme
            , Skeleton.button theme
            ]
        , footer = Nothing
        }
