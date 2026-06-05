module Page.Admin.Dashboard exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User as User
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.Loadable exposing (Loadable(..))
import Ui
import View.User


type alias Model =
    { users : Loadable Client.ApiError (List User.User)
    }


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
    ( { users = Loading }
    , RequestUsers
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsersLoaded result ->
            case result of
                Ok users ->
                    ( { model | users = Success users }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | users = Failure error }, Cmd.none, SessionExpired )

                    else
                        ( { model | users = Failure error }, Cmd.none, NoOp )

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
    case model.users of
        Success [] ->
            Ui.card [ createUserRow ]

        Success users ->
            Ui.card
                (List.map
                    (\user -> View.User.userListRow { user = user, onSelect = NavigateEditUser })
                    users
                    ++ [ createUserRow ]
                )

        Loading ->
            Ui.loading "Loading users..."

        NotAsked ->
            Element.none

        Failure error ->
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
