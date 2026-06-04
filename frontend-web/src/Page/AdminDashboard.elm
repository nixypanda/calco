module Page.AdminDashboard exposing
    ( CreateForm
    , Model
    , Msg(..)
    , OutMsg(..)
    , ResetForm
    , createUserPayload
    , init
    , resetPasswordPayload
    , update
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Data.User as User
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Loadable exposing (Loadable(..))
import Ui


type alias CreateForm =
    { username : String
    , displayName : String
    , initialPassword : String
    }


type alias ResetForm =
    { userId : String
    , password : String
    }


type alias Model =
    { users : Loadable Client.ApiError (List User.User)
    , showCreate : Bool
    , createForm : CreateForm
    , resetForm : Maybe ResetForm
    , actionError : Maybe String
    }


type Msg
    = UsersLoaded (Result Client.ApiError (List User.User))
    | ToggleCreate
    | CreateUsernameChanged String
    | CreateDisplayNameChanged String
    | CreatePasswordChanged String
    | CreateSubmitted
    | CreateCompleted (Result Client.ApiError Auth.LoginSession)
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
    | RequestCreateUser User.CreateUserRequest
    | RequestResetPassword String User.ResetPasswordRequest
    | RequestDisableUser String
    | RequestEnableUser String
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { users = Loading
      , showCreate = False
      , createForm = emptyCreateForm
      , resetForm = Nothing
      , actionError = Nothing
      }
    , RequestUsers
    )


emptyCreateForm : CreateForm
emptyCreateForm =
    { username = "", displayName = "", initialPassword = "" }


createUserPayload : Model -> Result String User.CreateUserRequest
createUserPayload model =
    let
        username : String
        username =
            String.trim model.createForm.username

        displayName : String
        displayName =
            String.trim model.createForm.displayName
    in
    if String.isEmpty username then
        Err "Username is required"

    else if String.isEmpty displayName then
        Err "Display name is required"

    else if String.isEmpty model.createForm.initialPassword then
        Err "Initial password is required"

    else
        Ok
            { username = username
            , displayName = displayName
            , initialPassword = model.createForm.initialPassword
            }


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

        ToggleCreate ->
            ( { model | showCreate = not model.showCreate }, Cmd.none, NoOp )

        CreateUsernameChanged username ->
            ( { model | createForm = updateCreateUsername username model.createForm }
            , Cmd.none
            , NoOp
            )

        CreateDisplayNameChanged displayName ->
            ( { model
                | createForm = updateCreateDisplayName displayName model.createForm
              }
            , Cmd.none
            , NoOp
            )

        CreatePasswordChanged password ->
            ( { model | createForm = updateCreatePassword password model.createForm }
            , Cmd.none
            , NoOp
            )

        CreateSubmitted ->
            case createUserPayload model of
                Ok request ->
                    ( { model | actionError = Nothing }, Cmd.none, RequestCreateUser request )

                Err message ->
                    ( { model | actionError = Just message }, Cmd.none, NoOp )

        CreateCompleted result ->
            case result of
                Ok _ ->
                    ( { model
                        | showCreate = False
                        , createForm = emptyCreateForm
                        , actionError = Nothing
                      }
                    , Cmd.none
                    , RequestUsers
                    )

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


updateCreateUsername : String -> CreateForm -> CreateForm
updateCreateUsername username form =
    { form | username = username }


updateCreateDisplayName : String -> CreateForm -> CreateForm
updateCreateDisplayName displayName form =
    { form | displayName = displayName }


updateCreatePassword : String -> CreateForm -> CreateForm
updateCreatePassword password form =
    { form | initialPassword = password }


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (Element.el
            [ Element.alignRight ]
            (Ui.button
                (if model.showCreate then
                    "Cancel"

                 else
                    "Create User"
                )
                ToggleCreate
            )
            :: (errorView model.actionError
                    ++ createFormView model
                    ++ usersView model
                    ++ resetFormView model
               )
        )


createFormView : Model -> List (Element Msg)
createFormView model =
    if model.showCreate then
        [ Ui.card
            [ Ui.input "Username" model.createForm.username CreateUsernameChanged
            , Ui.input "Display Name" model.createForm.displayName CreateDisplayNameChanged
            , Ui.passwordInput
                "Initial Password"
                model.createForm.initialPassword
                CreatePasswordChanged
            , Ui.button "Save" CreateSubmitted
            ]
        ]

    else
        []


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
