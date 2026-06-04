module Page.Admin.Dashboard exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , ResetForm
    , init
    , resetPasswordPayload
    , update
    , view
    )

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User as User
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Lib.Loadable exposing (Loadable(..))
import Ui


type alias ResetForm =
    { userId : String
    , password : String
    }


type alias Model =
    { users : Loadable Client.ApiError (List User.User)
    , resetForm : Maybe ResetForm
    , actionError : Maybe String
    }


type Msg
    = UsersLoaded (Result Client.ApiError (List User.User))
    | NavigateCreateUser
    | OpenReset String
    | ResetPasswordChanged String
    | ResetSubmitted String
    | ResetCompleted (Result Client.ApiError ())
    | DisableClicked String
    | DisableCompleted (Result Client.ApiError ())
    | EnableClicked String
    | EnableCompleted (Result Client.ApiError ())


type OutMsg
    = NoOp
    | RequestUsers
    | Navigate Route
    | RequestResetPassword String User.ResetPasswordRequest
    | RequestDisableUser String
    | RequestEnableUser String
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { users = Loading
      , resetForm = Nothing
      , actionError = Nothing
      }
    , RequestUsers
    )


resetPasswordPayload : Model -> Result String ( String, User.ResetPasswordRequest )
resetPasswordPayload model =
    case model.resetForm of
        Just form ->
            if String.isEmpty form.password then
                Err "New password is required"

            else
                Ok ( form.userId, { newPassword = form.password } )

        Nothing ->
            Err "Choose a user first"


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsersLoaded result ->
            case result of
                Ok users ->
                    ( { model | users = Success users, actionError = Nothing }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | users = Failure error
                            , actionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | users = Failure error
                            , actionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        NavigateCreateUser ->
            ( model, Cmd.none, Navigate AdminCreateUser )

        OpenReset userId ->
            case model.resetForm of
                Just form ->
                    if form.userId == userId then
                        ( { model | resetForm = Nothing }, Cmd.none, NoOp )

                    else
                        ( { model | resetForm = Just { userId = userId, password = "" } }
                        , Cmd.none
                        , NoOp
                        )

                Nothing ->
                    ( { model | resetForm = Just { userId = userId, password = "" } }
                    , Cmd.none
                    , NoOp
                    )

        ResetPasswordChanged password ->
            case model.resetForm of
                Just form ->
                    ( { model | resetForm = Just { form | password = password } }, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        ResetSubmitted userId ->
            case resetPasswordPayload model of
                Ok ( selectedUserId, request ) ->
                    if selectedUserId == userId then
                        ( { model | actionError = Nothing }
                        , Cmd.none
                        , RequestResetPassword userId request
                        )

                    else
                        ( model, Cmd.none, NoOp )

                Err message ->
                    ( { model | actionError = Just message }, Cmd.none, NoOp )

        ResetCompleted result ->
            case result of
                Ok _ ->
                    ( { model | resetForm = Nothing, actionError = Nothing }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | actionError = Just (Client.displayError error) }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model | actionError = Just (Client.displayError error) }
                        , Cmd.none
                        , NoOp
                        )

        DisableClicked userId ->
            ( { model | actionError = Nothing }, Cmd.none, RequestDisableUser userId )

        DisableCompleted result ->
            actionReloadResult result model

        EnableClicked userId ->
            ( { model | actionError = Nothing }, Cmd.none, RequestEnableUser userId )

        EnableCompleted result ->
            actionReloadResult result model


actionReloadResult : Result Client.ApiError () -> Model -> ( Model, Cmd Msg, OutMsg )
actionReloadResult result model =
    case result of
        Ok _ ->
            ( { model | actionError = Nothing }, Cmd.none, RequestUsers )

        Err error ->
            if Client.isUnauthorized error then
                ( { model | actionError = Just (Client.displayError error) }
                , Cmd.none
                , SessionExpired
                )

            else
                ( { model | actionError = Just (Client.displayError error) }
                , Cmd.none
                , NoOp
                )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (Element.el
            [ Element.alignRight ]
            (Ui.button "Create User" NavigateCreateUser)
            :: (errorView model.actionError
                    ++ usersView model
                    ++ resetFormView model
               )
        )


usersView : Model -> List (Element Msg)
usersView model =
    case model.users of
        NotAsked ->
            [ Element.text "Users have not loaded yet." ]

        Loading ->
            [ Ui.loading "Loading users..." ]

        Failure error ->
            [ Ui.errorBanner ("Unable to load users: " ++ Client.displayError error) ]

        Success users ->
            if List.isEmpty users then
                [ Ui.emptyState "No users yet." ]

            else
                [ Element.column
                    [ Element.width Element.fill, Element.spacing 8 ]
                    (List.map userRow users)
                ]


userRow : User.User -> Element Msg
userRow user =
    Element.row
        [ Element.width Element.fill
        , Element.spacing 12
        , Element.padding 12
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color Ui.borderGray
        ]
        [ Element.column [ Element.width Element.fill, Element.spacing 4 ]
            [ Element.el [ Font.medium ] (Element.text user.username)
            , Element.text user.displayName
            , Element.el
                [ Font.color Ui.mediumColor
                , Ui.caption
                ]
                (Element.text user.status)
            ]
        , Ui.button "Reset Password" (OpenReset user.id)
        , if user.status == "active" then
            Ui.button "Disable" (DisableClicked user.id)

          else
            Ui.button "Enable" (EnableClicked user.id)
        ]


resetFormView : Model -> List (Element Msg)
resetFormView model =
    case model.resetForm of
        Just form ->
            [ Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.el
                    [ Element.width Element.fill ]
                    (Ui.passwordInput "New password" form.password ResetPasswordChanged)
                , Ui.button "Confirm Reset" (ResetSubmitted form.userId)
                ]
            ]

        Nothing ->
            []


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
