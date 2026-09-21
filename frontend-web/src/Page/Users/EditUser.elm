module Page.Users.EditUser exposing
    ( ActionState(..)
    , LoadedUser
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , Status(..)
    , init
    , modalView
    , update
    , view
    )

import Api.Client as Client
import Data.User as User exposing (User)
import Element exposing (Device, Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.DeleteModal



-- MODEL


type alias Model =
    { userId : String
    , status : Status
    }


type Status
    = Loading
    | LoadFailed Client.ApiError
    | Loaded LoadedUser ActionState


type alias LoadedUser =
    { user : User
    , password : String
    }


type ActionState
    = Idle
    | Invalid Problem
    | ResettingPassword
    | DisableConfirming
    | DisablingUser
    | EnablingUser
    | ActionFailed String


type Problem
    = NewPasswordRequired


init : String -> ( Model, OutMsg )
init userId =
    ( { userId = userId
      , status = Loading
      }
    , RequestUser userId
    )



-- UPDATE


type Msg
    = UserLoaded (Result Client.ApiError User)
    | PasswordChanged String
    | ResetSubmitted
    | ResetCompleted (Result Client.ApiError ())
    | DisableClicked
    | CancelDisableClicked
    | DisableConfirmClicked
    | DisableCompleted (Result Client.ApiError ())
    | EnableClicked
    | EnableCompleted (Result Client.ApiError ())


type OutMsg
    = NoOp
    | RequestUser String
    | RequestResetPassword String User.ResetPasswordRequest
    | RequestDisableUser String
    | RequestEnableUser String
    | UpdateSucceeded
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UserLoaded result ->
            case result of
                Ok user ->
                    ( { model | status = Loaded { user = user, password = "" } Idle }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \_ current -> { current | status = LoadFailed error }
                        }
                        error
                        model

        PasswordChanged password ->
            case model.status of
                Loaded loadedUser actionState ->
                    ( { model
                        | status =
                            Loaded
                                { loadedUser | password = password }
                                (actionStateAfterEdit actionState)
                      }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        ResetSubmitted ->
            case model.status of
                Loaded loadedUser actionState ->
                    if String.isEmpty loadedUser.password then
                        ( { model | status = Loaded loadedUser (Invalid NewPasswordRequired) }
                        , Cmd.none
                        , NoOp
                        )

                    else if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | status = Loaded loadedUser ResettingPassword }
                        , Cmd.none
                        , RequestResetPassword model.userId { newPassword = loadedUser.password }
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        ResetCompleted result ->
            completePendingAction ResettingPassword
                result
                model
                (\loadedUser -> Loaded { loadedUser | password = "" } Idle)

        DisableClicked ->
            case model.status of
                Loaded loadedUser actionState ->
                    if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | status = Loaded loadedUser DisableConfirming }
                        , Cmd.none
                        , NoOp
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        CancelDisableClicked ->
            case model.status of
                Loaded loadedUser DisableConfirming ->
                    ( { model | status = Loaded loadedUser Idle }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        DisableConfirmClicked ->
            case model.status of
                Loaded loadedUser DisableConfirming ->
                    ( { model | status = Loaded loadedUser DisablingUser }
                    , Cmd.none
                    , RequestDisableUser model.userId
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        DisableCompleted result ->
            completePendingAction DisablingUser result model (\loadedUser -> Loaded loadedUser Idle)

        EnableClicked ->
            case model.status of
                Loaded loadedUser actionState ->
                    if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | status = Loaded loadedUser EnablingUser }
                        , Cmd.none
                        , RequestEnableUser model.userId
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        EnableCompleted result ->
            completePendingAction EnablingUser result model (\loadedUser -> Loaded loadedUser Idle)


actionStateAfterEdit : ActionState -> ActionState
actionStateAfterEdit actionState =
    case actionState of
        Invalid _ ->
            Idle

        ActionFailed _ ->
            Idle

        _ ->
            actionState


isPending : ActionState -> Bool
isPending actionState =
    case actionState of
        ResettingPassword ->
            True

        DisablingUser ->
            True

        EnablingUser ->
            True

        _ ->
            False


completePendingAction :
    ActionState
    -> Result Client.ApiError ()
    -> Model
    -> (LoadedUser -> Status)
    -> ( Model, Cmd Msg, OutMsg )
completePendingAction pendingAction result model successStatus =
    case model.status of
        Loaded loadedUser actionState ->
            if actionState == pendingAction then
                case result of
                    Ok _ ->
                        ( { model | status = successStatus loadedUser }, Cmd.none, UpdateSucceeded )

                    Err error ->
                        Client.failure
                            { noOp = NoOp
                            , sessionExpired = SessionExpired
                            , applyError =
                                \message current ->
                                    { current | status = Loaded loadedUser (ActionFailed message) }
                            }
                            error
                            model

            else
                ( model, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )



-- VIEW


view : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
view { model, device, theme, language } =
    UiPage.pageContainer
        (errorView theme language model.status
            ++ userDetailsView device theme language model
            ++ accountActionView device theme language model
        )


modalView :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Maybe (Element Msg)
modalView { model, device, theme, language } =
    case model.status of
        Loaded _ DisableConfirming ->
            Just (disableConfirmModal device theme language { pending = False })

        Loaded _ DisablingUser ->
            Just (disableConfirmModal device theme language { pending = True })

        _ ->
            Nothing


disableConfirmModal : Device -> Theme -> Language -> { pending : Bool } -> Element Msg
disableConfirmModal device theme language state =
    View.DeleteModal.confirmModalView theme
        language
        device
        { title = I18n.t language TidUsersDisableConfirmTitle
        , description = I18n.t language TidUsersDisableConfirmDescription
        , confirmLabel = I18n.t language TidUsersDisableUser
        , pendingLabel = I18n.t language TidUsersDisabling
        , onCancel = CancelDisableClicked
        , onConfirm = DisableConfirmClicked
        }
        { pending = state.pending, error = Nothing }


userDetailsView : Device -> Theme -> Language -> Model -> List (Element Msg)
userDetailsView device theme language model =
    case model.status of
        Loading ->
            [ editUserSkeleton theme ]

        LoadFailed error ->
            [ Feedback.errorBanner theme
                (I18n.t language (TidUsersLoadFailed (Client.displayError error)))
            ]

        Loaded loadedUser _ ->
            [ userCard device theme language model.status loadedUser ]


userCard : Device -> Theme -> Language -> Status -> LoadedUser -> Element Msg
userCard device theme language status loadedUser =
    Surface.section theme
        { header =
            Just
                (Element.column
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space4
                    ]
                    [ Typography.sectionTitle theme loadedUser.user.displayName
                    , Typography.mutedParagraph theme loadedUser.user.username
                    ]
                )
        , body =
            [ Surface.detailRow theme
                language
                (I18n.t language TidCommonStatus)
                (Chip.statusBadge theme loadedUser.user.status)
            , Surface.detailRow theme
                language
                (I18n.t language TidCommonCreated)
                (Element.el [ Typography.caption ] (Element.text loadedUser.user.createdAt))
            , Surface.hairline theme
            , Element.column [ Element.spacing DesignTokens.space8, Element.width Element.fill ]
                [ Typography.wrappedListItemTitle theme (I18n.t language TidUsersResetPassword)
                , UiInput.passwordInput theme
                    { label = I18n.t language TidUsersNewPassword
                    , value = loadedUser.password
                    , onChange = PasswordChanged
                    }
                , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label =
                        if isResetPending status then
                            I18n.t language TidUsersResetting

                        else
                            I18n.t language TidUsersResetPassword
                    , onPress = ResetSubmitted
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                ]
            ]
        , footer = Nothing
        }


accountActionView : Device -> Theme -> Language -> Model -> List (Element Msg)
accountActionView device theme language model =
    case model.status of
        Loaded loadedUser _ ->
            [ Button.bottomActionButtons device
                theme
                [ if loadedUser.user.status == "active" then
                    { label =
                        if isDisablePending model.status then
                            I18n.t language TidUsersDisabling

                        else
                            I18n.t language TidUsersDisableUser
                    , onPress = DisableClicked
                    , tone = Button.Danger
                    }

                  else
                    { label =
                        if isEnablePending model.status then
                            I18n.t language TidUsersEnabling

                        else
                            I18n.t language TidUsersEnableUser
                    , onPress = EnableClicked
                    , tone = Button.Primary
                    }
                ]
            ]

        _ ->
            []


isResetPending : Status -> Bool
isResetPending status =
    case status of
        Loaded _ ResettingPassword ->
            True

        _ ->
            False


isDisablePending : Status -> Bool
isDisablePending status =
    case status of
        Loaded _ DisablingUser ->
            True

        _ ->
            False


isEnablePending : Status -> Bool
isEnablePending status =
    case status of
        Loaded _ EnablingUser ->
            True

        _ ->
            False


errorView : Theme -> Language -> Status -> List (Element msg)
errorView theme language status =
    case status of
        Loaded _ (Invalid problem) ->
            [ Feedback.errorBanner theme (problemMessage language problem) ]

        Loaded _ (ActionFailed message) ->
            [ Feedback.errorBanner theme message ]

        _ ->
            []


problemMessage : Language -> Problem -> String
problemMessage language problem =
    case problem of
        NewPasswordRequired ->
            I18n.t language TidUsersNewPasswordRequired


editUserSkeleton : Theme -> Element msg
editUserSkeleton theme =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Skeleton.card theme { rows = 5 }
        , Skeleton.button theme
        ]
