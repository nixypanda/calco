module Page.Admin.Dashboard exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , State(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Result as ApiResult
import Data.Route exposing (Route(..))
import Data.User as User
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui


type alias Model =
    { state : State
    }


type State
    = Loading
    | LoadFailed Client.ApiError
    | Ready (List User.User)


type Msg
    = UsersLoaded (Result Client.ApiError (List User.User))
    | NavigateCreateUser
    | NavigateEditUser String


type OutMsg
    = NoOp
    | RequestUsers
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { state = Loading }
    , RequestUsers
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsersLoaded result ->
            case result of
                Ok users ->
                    ( { model | state = Ready users }, Cmd.none, NoOp )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \_ current -> { current | state = LoadFailed error }
                        }
                        error
                        model

        NavigateCreateUser ->
            ( model, Cmd.none, Navigate AdminCreateUser )

        NavigateEditUser userId ->
            ( model, Cmd.none, Navigate (AdminEditUser userId) )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ bodyView model
        ]


bodyView : Model -> Element Msg
bodyView model =
    case model.state of
        Ready [] ->
            Ui.card [ createUserRow ]

        Ready users ->
            Ui.card
                (List.map
                    (\user -> userListRow { user = user, onSelect = NavigateEditUser })
                    users
                    ++ [ createUserRow ]
                )

        Loading ->
            Ui.loading "Loading users..."

        LoadFailed error ->
            Ui.errorBanner (Client.displayError error)


createUserRow : Element Msg
createUserRow =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 0, left = 0 }
        , Border.color Ui.borderGray
        , Font.color Ui.primaryTeal
        , Font.medium
        ]
        { onPress = Just NavigateCreateUser
        , label = Element.text "Create User"
        }


statusBadge : String -> Element msg
statusBadge status =
    Ui.coloredBadge
        { label = status
        , background =
            if status == "active" then
                Element.rgb255 220 252 231

            else
                Element.rgb255 254 226 226
        , foreground =
            if status == "active" then
                Element.rgb255 22 101 52

            else
                Element.rgb255 153 27 27
        }


userListRow : { user : User.User, onSelect : String -> msg } -> Element msg
userListRow config =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        ]
        { onPress = Just (config.onSelect config.user.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.column [ Element.width Element.fill, Element.spacing 2 ]
                    [ Element.el [ Font.bold ] (Element.text config.user.username)
                    , Ui.mutedText config.user.displayName
                    ]
                , Element.el [ Element.alignRight ] (statusBadge config.user.status)
                ]
        }
