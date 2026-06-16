module Page.Users.Dashboard exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Element exposing (Device, Element)
import Ui
import Ui.Theme exposing (Theme)



-- MODEL


type Model
    = Loading
    | LoadFailed Client.ApiError
    | Loaded (List User)


init : ( Model, OutMsg )
init =
    ( Loading
    , RequestUsers
    )



-- UPDATE


type Msg
    = UsersLoaded (Result Client.ApiError (List User))
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
                    ( Loaded users, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( LoadFailed error, Cmd.none, NoOp )

        NavigateCreateUser ->
            ( model, Cmd.none, Navigate AdminCreateUser )

        NavigateEditUser userId ->
            ( model, Cmd.none, Navigate (AdminEditUser userId) )



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ bodyView device theme model
        ]


bodyView : Device -> Theme -> Model -> Element Msg
bodyView device theme model =
    case model of
        Loaded users ->
            Ui.listCard theme
                { rows =
                    List.map
                        (\user ->
                            userListRow device
                                theme
                                { user = user, onSelect = NavigateEditUser }
                        )
                        users
                , footer = Just (Ui.ghostButton device theme "+ Create User" NavigateCreateUser)
                }

        Loading ->
            Ui.skeletonLoading theme

        LoadFailed error ->
            Ui.errorBanner theme (Client.displayError error)


userListRow : Device -> Theme -> { user : User, onSelect : String -> msg } -> Element msg
userListRow device theme config =
    Ui.listRow
        { onSelect = config.onSelect config.user.id
        , leading = []
        , title = Ui.sectionTitle theme device config.user.username
        , subtitle = [ Ui.mutedBody theme config.user.displayName ]
        , trailing = [ Ui.statusBadge theme config.user.status ]
        }
