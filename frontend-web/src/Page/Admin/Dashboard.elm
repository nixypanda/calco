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
import View.User


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
                    (\user -> View.User.userListRow { user = user, onSelect = NavigateEditUser })
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
