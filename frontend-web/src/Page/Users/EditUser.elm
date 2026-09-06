module Page.Users.EditUser exposing
    ( ActionState(..)
    , LoadedUser
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , Status(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.User as User exposing (User)
import Element exposing (Device, Element)
import Element.Font as Font
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        (errorView theme model.status
            ++ userInfoView theme model
            ++ resetPasswordView device theme model
            ++ accountActionView device theme model
        )


userInfoView : Theme -> Model -> List (Element Msg)
userInfoView theme model =
    case model.status of
        Loading ->
            [ Ui.skeletonLoading theme ]

        LoadFailed error ->
            [ Ui.errorBanner theme ("Unable to load user: " ++ Client.displayError error) ]

        Loaded loadedUser _ ->
            [ userSummaryCard theme loadedUser.user ]


resetPasswordView : Device -> Theme -> Model -> List (Element Msg)
resetPasswordView device theme model =
    [ Ui.card theme
        [ Element.el [ Font.medium, Typography.body ] (Element.text "Reset Password")
        , Element.column [ Element.spacing DesignTokens.space8, Element.width Element.fill ]
            [ Ui.passwordInput theme
                { label = "New password"
                , value = currentPassword model.status
                , onChange = PasswordChanged
                }
            , Ui.textButton device
                theme
                { tone = Ui.Ghost
                , width = Ui.FullWidth
                , label =
                    if isResetPending model.status then
                        "Resetting..."

                    else
                        "Reset Password"
                , onPress = ResetSubmitted
                , submitState = Nothing
                , submittingLabel = Nothing
                , trailing = Nothing
                }
            ]
        ]
    ]


accountActionView : Device -> Theme -> Model -> List (Element Msg)
accountActionView device theme model =
    case model.status of
        Loaded loadedUser _ ->
            [ Ui.bottomActionButtons device
                theme
                [ if loadedUser.user.status == "active" then
                    { label =
                        if isDisablePending model.status then
                            "Disabling..."

                        else
                            "Disable User"
                    , onPress = DisableClicked
                    , tone = Ui.Danger
                    }

                  else
                    { label =
                        if isEnablePending model.status then
                            "Enabling..."

                        else
                            "Enable User"
                    , onPress = EnableClicked
                    , tone = Ui.Primary
                    }
                ]
            ]

        _ ->
            []


currentPassword : Status -> String
currentPassword status =
    case status of
        Loaded loadedUser _ ->
            loadedUser.password

        _ ->
            ""


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


errorView : Theme -> Status -> List (Element msg)
errorView theme status =
    case status of
        Loaded _ (Invalid problem) ->
            [ Ui.errorBanner theme (problemMessage problem) ]

        Loaded _ (ActionFailed message) ->
            [ Ui.errorBanner theme message ]

        _ ->
            []


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        NewPasswordRequired ->
            "New password is required"


userSummaryCard : Theme -> User -> Element msg
userSummaryCard theme user =
    Ui.card theme
        [ Element.column [ Element.spacing DesignTokens.space8, Element.width Element.fill ]
            [ Typography.wrappedListItemTitle theme user.username
            , Ui.detailRow theme
                "Display Name"
                (Typography.mutedCaptionParagraph theme user.displayName)
            , Ui.detailRow theme "Status" (Ui.statusBadge theme user.status)
            , Ui.detailRow theme
                "Created"
                (Element.el [ Typography.caption ] (Element.text user.createdAt))
            ]
        ]
