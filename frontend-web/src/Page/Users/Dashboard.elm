module Page.Users.Dashboard exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , init
    , update
    )

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Element exposing (Device, Element)
import Ui
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



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


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView { model, device, theme } =
    bodyView device theme model


bodyView : Device -> Theme -> Model -> Element Msg
bodyView device theme model =
    case model of
        Loaded users ->
            Ui.listCard theme
                { rows =
                    List.map
                        (\user ->
                            userListRow
                                theme
                                { user = user, onSelect = NavigateEditUser }
                        )
                        users
                , footer =
                    Just
                        (Ui.textButton device
                            theme
                            { tone = Ui.Ghost
                            , width = Ui.FullWidth
                            , label = "+ Create User"
                            , onPress = NavigateCreateUser
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        )
                }

        Loading ->
            adminDashboardSkeleton theme

        LoadFailed error ->
            Ui.errorBanner theme (Client.displayError error)


userListRow : Theme -> { user : User, onSelect : String -> msg } -> Element msg
userListRow theme config =
    Ui.listRow
        { onSelect = config.onSelect config.user.id
        , leading = []
        , title = Typography.wrappedListItemTitle theme config.user.username
        , subtitle = [ Typography.mutedBodyParagraph theme config.user.displayName ]
        , trailing = [ Ui.statusBadge theme config.user.status ]
        }


adminDashboardSkeleton : Theme -> Element msg
adminDashboardSkeleton theme =
    Ui.listCard theme
        { rows =
            List.map (\_ -> Skeleton.listRow theme)
                (List.range 1 3)
        , footer = Just (Skeleton.button theme)
        }
