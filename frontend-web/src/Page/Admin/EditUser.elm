module Page.Admin.EditUser exposing
    ( ActionState(..)
    , LoadedUser
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , State(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Result as ApiResult
import Data.User as User
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Page.Admin.StatusBadge
import Ui
import Ui.Theme exposing (Theme)



-- MODEL


type alias Model =
    { userId : String
    , state : State
    }


type State
    = Loading
    | LoadFailed Client.ApiError
    | Ready LoadedUser ActionState


type alias LoadedUser =
    { user : User.User
    , password : String
    }


type ActionState
    = Idle
    | Invalid Problem
    | ResettingPassword
    | DisablingUser
    | EnablingUser
    | ActionFailed String


type Problem
    = NewPasswordRequired


init : String -> ( Model, OutMsg )
init userId =
    ( { userId = userId
      , state = Loading
      }
    , RequestUser userId
    )



-- UPDATE


type Msg
    = UserLoaded (Result Client.ApiError User.User)
    | PasswordChanged String
    | ResetSubmitted
    | ResetCompleted (Result Client.ApiError ())
    | DisableClicked
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
                    ( { model | state = Ready { user = user, password = "" } Idle }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \_ current -> { current | state = LoadFailed error }
                        }
                        error
                        model

        PasswordChanged password ->
            case model.state of
                Ready loadedUser actionState ->
                    ( { model
                        | state =
                            Ready
                                { loadedUser | password = password }
                                (actionStateAfterEdit actionState)
                      }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        ResetSubmitted ->
            case model.state of
                Ready loadedUser actionState ->
                    if String.isEmpty loadedUser.password then
                        ( { model | state = Ready loadedUser (Invalid NewPasswordRequired) }
                        , Cmd.none
                        , NoOp
                        )

                    else if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | state = Ready loadedUser ResettingPassword }
                        , Cmd.none
                        , RequestResetPassword model.userId { newPassword = loadedUser.password }
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        ResetCompleted result ->
            completePendingAction ResettingPassword
                result
                model
                (\loadedUser -> Ready { loadedUser | password = "" } Idle)

        DisableClicked ->
            case model.state of
                Ready loadedUser actionState ->
                    if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | state = Ready loadedUser DisablingUser }
                        , Cmd.none
                        , RequestDisableUser model.userId
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        DisableCompleted result ->
            completePendingAction DisablingUser result model (\loadedUser -> Ready loadedUser Idle)

        EnableClicked ->
            case model.state of
                Ready loadedUser actionState ->
                    if isPending actionState then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | state = Ready loadedUser EnablingUser }
                        , Cmd.none
                        , RequestEnableUser model.userId
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        EnableCompleted result ->
            completePendingAction EnablingUser result model (\loadedUser -> Ready loadedUser Idle)


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
    -> (LoadedUser -> State)
    -> ( Model, Cmd Msg, OutMsg )
completePendingAction pendingAction result model successState =
    case model.state of
        Ready loadedUser actionState ->
            if actionState == pendingAction then
                case result of
                    Ok _ ->
                        ( { model | state = successState loadedUser }, Cmd.none, UpdateSucceeded )

                    Err error ->
                        ApiResult.failure
                            { noOp = NoOp
                            , sessionExpired = SessionExpired
                            , applyError =
                                \message current ->
                                    { current | state = Ready loadedUser (ActionFailed message) }
                            }
                            error
                            model

            else
                ( model, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        (errorView theme model.state
            ++ userInfoView theme model
            ++ resetPasswordView theme model
            ++ enableDisableView theme model
        )


userInfoView : Theme -> Model -> List (Element Msg)
userInfoView theme model =
    case model.state of
        Loading ->
            [ Ui.loading theme "Loading user..." ]

        LoadFailed error ->
            [ Ui.errorBanner theme ("Unable to load user: " ++ Client.displayError error) ]

        Ready loadedUser _ ->
            [ userSummaryCard theme loadedUser.user ]


resetPasswordView : Theme -> Model -> List (Element Msg)
resetPasswordView theme model =
    [ Ui.card theme
        [ Element.el [ Font.medium, Ui.body ] (Element.text "Reset Password")
        , Element.column [ Element.spacing Ui.space8, Element.width Element.fill ]
            [ Ui.passwordInput theme "New password" (currentPassword model.state) PasswordChanged
            , Ui.button theme "Reset Password" ResetSubmitted
            ]
        ]
    ]


enableDisableView : Theme -> Model -> List (Element Msg)
enableDisableView theme model =
    case model.state of
        Ready loadedUser _ ->
            [ Ui.card theme
                [ Element.column
                    [ Element.width Element.fill
                    , Background.color theme.statusDisabledBg
                    , Border.rounded 16
                    , Element.padding Ui.space16
                    , Element.spacing Ui.space12
                    ]
                    [ Element.el
                        [ Font.medium
                        , Ui.body
                        , Font.color theme.dangerFg
                        ]
                        (Element.text "Danger Zone")
                    , if loadedUser.user.status == "active" then
                        Ui.dangerButton theme "Disable User" DisableClicked

                      else
                        Ui.button theme "Enable User" EnableClicked
                    ]
                ]
            ]

        _ ->
            []


currentPassword : State -> String
currentPassword state =
    case state of
        Ready loadedUser _ ->
            loadedUser.password

        _ ->
            ""


errorView : Theme -> State -> List (Element msg)
errorView theme state =
    case state of
        Ready _ (Invalid problem) ->
            [ Ui.errorBanner theme (problemMessage problem) ]

        Ready _ (ActionFailed message) ->
            [ Ui.errorBanner theme message ]

        _ ->
            []


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        NewPasswordRequired ->
            "New password is required"


userSummaryCard : Theme -> User.User -> Element msg
userSummaryCard theme user =
    Ui.card theme
        [ Element.column [ Element.spacing Ui.space8, Element.width Element.fill ]
            [ Ui.sectionTitle theme user.username
            , Ui.detailRow theme
                "Display Name"
                (Element.el [ Ui.caption ] (Element.text user.displayName))
            , Ui.detailRow theme "Status" (Page.Admin.StatusBadge.statusBadge theme user.status)
            , Ui.detailRow theme
                "Created"
                (Element.el [ Ui.caption ] (Element.text user.createdAt))
            ]
        ]
