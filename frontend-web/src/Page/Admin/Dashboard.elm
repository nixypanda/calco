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


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
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
    Ui.ghostButton "+ Create User" NavigateCreateUser


statusBadge : String -> Element msg
statusBadge status =
    Ui.coloredPill
        { label = status
        , bg =
            if status == "active" then
                Ui.accentSoftGreen

            else
                Ui.accentSoftPink
        , fg =
            if status == "active" then
                Element.rgb255 50 110 60

            else
                Element.rgb255 180 60 80
        }


userListRow : { user : User.User, onSelect : String -> msg } -> Element msg
userListRow config =
    Input.button
        [ Element.width Element.fill
        , Element.padding 16
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
