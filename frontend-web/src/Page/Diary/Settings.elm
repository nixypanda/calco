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
import Element exposing (Device, Element)
import Element.Input as Input
import Ui
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Skeleton as Skeleton
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
                                    ValidationFailed "Select at least one meal slot."
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


canonical : List MealSlot -> List MealSlot
canonical selected =
    List.filter (\slot -> List.member slot selected) MealSlot.all


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        (case model of
            Loading ->
                [ diarySettingsSkeleton theme ]

            Failed message ->
                [ Ui.errorBanner theme message ]

            Ready loaded ->
                [ Ui.card theme
                    (Typography.sectionTitle theme "Meal slots"
                        :: Typography.mutedParagraph theme
                            "Choose the fixed meal slots shown in your diary."
                        :: List.map (slotCheckbox loaded.selected) MealSlot.all
                    )
                , Ui.maybeErrorBanner theme (saveError loaded.saveState)
                , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label =
                        if loaded.saveState == Saved then
                            "Saved"

                        else
                            "Save meal slots"
                    , onPress = SaveClicked
                    , submitState = Just (Button.submittingOrIdle (loaded.saveState == Saving))
                    , submittingLabel = Just "Saving..."
                    , trailing = Nothing
                    }
                ]
        )


slotCheckbox : List MealSlot -> MealSlot -> Element Msg
slotCheckbox selected slot =
    Input.checkbox
        [ Element.width Element.fill
        , Element.paddingXY 0 DesignTokens.space8
        ]
        { onChange = SlotToggled slot
        , icon = Input.defaultCheckbox
        , checked = List.member slot selected
        , label =
            Input.labelRight []
                (Element.el [ Typography.body ] (Element.text (MealSlot.label slot)))
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
    Ui.card theme
        [ Skeleton.bar theme
        , Skeleton.bar theme
        , Skeleton.bar theme
        , Skeleton.bar theme
        , Skeleton.button theme
        ]
