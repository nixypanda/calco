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
import Data.User as User
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Ui


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


init : String -> ( Model, OutMsg )
init userId =
    ( { userId = userId
      , state = Loading
      }
    , RequestUser userId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UserLoaded result ->
            case result of
                Ok user ->
                    ( { model | state = Ready { user = user, password = "" } Idle }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | state = LoadFailed error }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model | state = LoadFailed error }
                        , Cmd.none
                        , NoOp
                        )

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
                        ( { model | state = Ready loadedUser (Invalid NewPasswordRequired) }, Cmd.none, NoOp )

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
                        ( { model | state = Ready loadedUser DisablingUser }, Cmd.none, RequestDisableUser model.userId )

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
                        ( { model | state = Ready loadedUser EnablingUser }, Cmd.none, RequestEnableUser model.userId )

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
                        if Client.isUnauthorized error then
                            ( { model | state = Ready loadedUser (ActionFailed (Client.displayError error)) }
                            , Cmd.none
                            , SessionExpired
                            )

                        else
                            ( { model | state = Ready loadedUser (ActionFailed (Client.displayError error)) }
                            , Cmd.none
                            , NoOp
                            )

            else
                ( model, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (errorView model.state
            ++ userInfoView model
            ++ resetPasswordView model
            ++ enableDisableView model
        )


userInfoView : Model -> List (Element Msg)
userInfoView model =
    case model.state of
        Loading ->
            [ Ui.loading "Loading user..." ]

        LoadFailed error ->
            [ Ui.errorBanner ("Unable to load user: " ++ Client.displayError error) ]

        Ready loadedUser _ ->
            [ Ui.card
                [ Element.column [ Element.spacing 8, Element.width Element.fill ]
                    [ Element.el [ Font.bold, Ui.heading3 ] (Element.text loadedUser.user.username)
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Display Name:")
                        , Element.el [ Ui.caption ] (Element.text loadedUser.user.displayName)
                        ]
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Status:")
                        , statusBadge loadedUser.user.status
                        ]
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Created:")
                        , Element.el [ Ui.caption ] (Element.text loadedUser.user.createdAt)
                        ]
                    ]
                ]
            ]


statusBadge : String -> Element Msg
statusBadge status =
    Element.el
        [ Font.size 12
        , Font.medium
        , Element.paddingXY 8 2
        , Border.rounded 4
        , Background.color
            (if status == "active" then
                Element.rgb255 220 252 231

             else
                Element.rgb255 254 226 226
            )
        , Font.color
            (if status == "active" then
                Element.rgb255 22 101 52

             else
                Element.rgb255 153 27 27
            )
        ]
        (Element.text status)


resetPasswordView : Model -> List (Element Msg)
resetPasswordView model =
    [ Ui.card
        [ Element.el [ Font.medium, Ui.body ] (Element.text "Reset Password")
        , Element.column [ Element.spacing 8, Element.width Element.fill ]
            [ Ui.passwordInput "New password" (currentPassword model.state) PasswordChanged
            , Ui.button "Reset Password" ResetSubmitted
            ]
        ]
    ]


enableDisableView : Model -> List (Element Msg)
enableDisableView model =
    case model.state of
        Ready loadedUser _ ->
            [ Ui.card
                [ Element.el [ Font.medium, Ui.body, Font.color (Element.rgb255 153 27 27) ]
                    (Element.text "Danger Zone")
                , if loadedUser.user.status == "active" then
                    Ui.dangerButton "Disable User" DisableClicked

                  else
                    Ui.button "Enable User" EnableClicked
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


errorView : State -> List (Element msg)
errorView state =
    case state of
        Ready _ (Invalid problem) ->
            [ Ui.errorBanner (problemMessage problem) ]

        Ready _ (ActionFailed message) ->
            [ Ui.errorBanner message ]

        _ ->
            []


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        NewPasswordRequired ->
            "New password is required"
