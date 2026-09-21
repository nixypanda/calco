module Page.Diary.Settings exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , SaveState(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.DiaryPreferences exposing (DiaryPreferences)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type Model
    = Loading
    | Ready { selected : List MealSlot, saveState : SaveState }
    | Failed String


type SaveState
    = Editing
    | Saving
    | Saved
    | ValidationFailed String
    | SaveFailed String


type Msg
    = PreferencesLoaded (Result Client.ApiError DiaryPreferences)
    | SlotToggled MealSlot Bool
    | SaveClicked
    | SaveCompleted (Result Client.ApiError DiaryPreferences)
    | RetryClicked


type OutMsg
    = NoOp
    | RequestPreferences
    | RequestSave DiaryPreferences
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestPreferences )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        PreferencesLoaded result ->
            case result of
                Ok preferences ->
                    ( Ready
                        { selected = canonical preferences.enabledMealSlots
                        , saveState = Editing
                        }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message _ -> Failed message
                        }
                        error
                        model

        SlotToggled slot enabled ->
            case model of
                Ready loaded ->
                    ( Ready
                        { loaded
                            | selected =
                                canonical
                                    (if enabled then
                                        slot :: loaded.selected

                                     else
                                        List.filter ((/=) slot) loaded.selected
                                    )
                            , saveState = Editing
                        }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveClicked ->
            case model of
                Ready loaded ->
                    if List.isEmpty loaded.selected then
                        ( Ready
                            { loaded
                                | saveState =
                                    ValidationFailed (I18n.en TidDiarySettingsSelectAtLeastOne)
                            }
                        , Cmd.none
                        , NoOp
                        )

                    else
                        ( Ready { loaded | saveState = Saving }
                        , Cmd.none
                        , RequestSave { enabledMealSlots = loaded.selected }
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case ( model, result ) of
                ( Ready _, Ok preferences ) ->
                    ( Ready
                        { selected = canonical preferences.enabledMealSlots
                        , saveState = Saved
                        }
                    , Cmd.none
                    , NoOp
                    )

                ( Ready loaded, Err error ) ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message _ ->
                                Ready { loaded | saveState = SaveFailed message }
                        }
                        error
                        model

                _ ->
                    ( model, Cmd.none, NoOp )

        RetryClicked ->
            ( Loading, Cmd.none, RequestPreferences )


canonical : List MealSlot -> List MealSlot
canonical selected =
    List.filter (\slot -> List.member slot selected) MealSlot.all


view : { model : Model, env : Env } -> Element Msg
view { model, env } =
    UiPage.pageContainer
        (case model of
            Loading ->
                [ diarySettingsSkeleton env.theme ]

            Failed message ->
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = message, onRetry = RetryClicked }
                ]

            Ready loaded ->
                [ Surface.section env.theme
                    { header =
                        Just
                            (Surface.sectionHeader
                                { title =
                                    Typography.sectionTitle env.theme
                                        (I18n.t env.language TidDiarySettingsMealSlotsTitle)
                                , description =
                                    Just
                                        (Typography.mutedParagraph env.theme
                                            (I18n.t env.language
                                                TidDiarySettingsMealSlotsDescription
                                            )
                                        )
                                , trailing = Nothing
                                }
                            )
                    , body = List.map (slotCheckbox env loaded.selected) MealSlot.all
                    , footer = Nothing
                    }
                , Feedback.maybeErrorBanner env.theme (saveError loaded.saveState)
                , Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label =
                        if loaded.saveState == Saved then
                            I18n.t env.language TidDiarySettingsSaved

                        else
                            I18n.t env.language TidDiarySettingsSave
                    , onPress = SaveClicked
                    , submitState = Just (Button.submittingOrIdle (loaded.saveState == Saving))
                    , submittingLabel = Just (I18n.t env.language TidCommonSaving)
                    , trailing = Nothing
                    }
                ]
        )


slotCheckbox : Env -> List MealSlot -> MealSlot -> Element Msg
slotCheckbox env selected slot =
    UiInput.checkbox env.theme
        { label = MealSlot.label env.language slot
        , checked = List.member slot selected
        , onChange = SlotToggled slot
        }


saveError : SaveState -> Maybe String
saveError state =
    case state of
        ValidationFailed message ->
            Just message

        SaveFailed message ->
            Just message

        _ ->
            Nothing


diarySettingsSkeleton : Theme -> Element msg
diarySettingsSkeleton theme =
    Surface.section theme
        { header =
            Just
                (Skeleton.barCustom theme
                    { width = Element.px 140, height = 24 }
                )
        , body =
            [ Skeleton.bar theme
            , Skeleton.bar theme
            , Skeleton.bar theme
            , Skeleton.bar theme
            , Skeleton.button theme
            ]
        , footer = Nothing
        }
