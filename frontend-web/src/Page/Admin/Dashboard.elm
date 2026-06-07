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
import Element exposing (Device, Element)
import Page.Admin.StatusBadge
import Ui
import Ui.Theme exposing (Theme)



-- MODEL


type alias Model =
    { state : State
    }


type State
    = Loading
    | LoadFailed Client.ApiError
    | Ready (List User.User)


init : ( Model, OutMsg )
init =
    ( { state = Loading }
    , RequestUsers
    )



-- UPDATE


type Msg
    = UsersLoaded (Result Client.ApiError (List User.User))
    | NavigateCreateUser
    | NavigateEditUser String


type OutMsg
    = NoOp
    | RequestUsers
    | Navigate Route
    | SessionExpired


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



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ bodyView theme model
        ]


bodyView : Theme -> Model -> Element Msg
bodyView theme model =
    case model.state of
        Ready users ->
            Ui.listCard theme
                { rows =
                    List.map
                        (\user -> userListRow theme { user = user, onSelect = NavigateEditUser })
                        users
                , createButton = Ui.ghostButton theme "+ Create User" NavigateCreateUser
                }

        Loading ->
            Ui.loading theme "Loading users..."

        LoadFailed error ->
            Ui.errorBanner theme (Client.displayError error)


userListRow : Theme -> { user : User.User, onSelect : String -> msg } -> Element msg
userListRow theme config =
    Ui.listRow
        { onSelect = config.onSelect config.user.id
        , leading = []
        , title = Ui.sectionTitle theme config.user.username
        , subtitle = [ Ui.mutedBody theme config.user.displayName ]
        , trailing = [ Page.Admin.StatusBadge.statusBadge theme config.user.status ]
        }
