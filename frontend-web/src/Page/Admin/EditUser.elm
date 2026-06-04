module Page.Admin.EditUser exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
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
import Lib.Loadable exposing (Loadable(..))
import Ui


type alias Model =
    { userId : String
    , user : Loadable Client.ApiError User.User
    , password : String
    , actionError : Maybe String
    }


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
      , user = Loading
      , password = ""
      , actionError = Nothing
      }
    , RequestUser userId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UserLoaded result ->
            case result of
                Ok user ->
                    ( { model | user = Success user, actionError = Nothing }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | user = Failure error
                            , actionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | user = Failure error
                            , actionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        PasswordChanged password ->
            ( { model | password = password }, Cmd.none, NoOp )

        ResetSubmitted ->
            if String.isEmpty model.password then
                ( { model | actionError = Just "New password is required" }, Cmd.none, NoOp )

            else
                ( { model | actionError = Nothing }
                , Cmd.none
                , RequestResetPassword model.userId { newPassword = model.password }
                )

        ResetCompleted result ->
            case result of
                Ok _ ->
                    ( { model | password = "", actionError = Nothing }, Cmd.none, UpdateSucceeded )

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

        DisableClicked ->
            ( { model | actionError = Nothing }, Cmd.none, RequestDisableUser model.userId )

        DisableCompleted result ->
            case result of
                Ok _ ->
                    ( { model | actionError = Nothing }, Cmd.none, UpdateSucceeded )

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

        EnableClicked ->
            ( { model | actionError = Nothing }, Cmd.none, RequestEnableUser model.userId )

        EnableCompleted result ->
            case result of
                Ok _ ->
                    ( { model | actionError = Nothing }, Cmd.none, UpdateSucceeded )

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
        (errorView model.actionError
            ++ userInfoView model
            ++ resetPasswordView model
            ++ enableDisableView model
        )


userInfoView : Model -> List (Element Msg)
userInfoView model =
    case model.user of
        Loading ->
            [ Ui.loading "Loading user..." ]

        NotAsked ->
            [ Element.text "User has not loaded yet." ]

        Failure error ->
            [ Ui.errorBanner ("Unable to load user: " ++ Client.displayError error) ]

        Success user ->
            [ Ui.card
                [ Element.column [ Element.spacing 8, Element.width Element.fill ]
                    [ Element.el [ Font.bold, Ui.heading3 ] (Element.text user.username)
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Display Name:")
                        , Element.el [ Ui.caption ] (Element.text user.displayName)
                        ]
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Status:")
                        , statusBadge user.status
                        ]
                    , Element.row [ Element.spacing 4 ]
                        [ Element.el [ Font.color Ui.mediumColor, Ui.caption ]
                            (Element.text "Created:")
                        , Element.el [ Ui.caption ] (Element.text user.createdAt)
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
            [ Ui.passwordInput "New password" model.password PasswordChanged
            , Ui.button "Reset Password" ResetSubmitted
            ]
        ]
    ]


enableDisableView : Model -> List (Element Msg)
enableDisableView model =
    case model.user of
        Success user ->
            [ Ui.card
                [ Element.el [ Font.medium, Ui.body, Font.color (Element.rgb255 153 27 27) ]
                    (Element.text "Danger Zone")
                , if user.status == "active" then
                    Ui.dangerButton "Disable User" DisableClicked

                  else
                    Ui.button "Enable User" EnableClicked
                ]
            ]

        _ ->
            []


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
