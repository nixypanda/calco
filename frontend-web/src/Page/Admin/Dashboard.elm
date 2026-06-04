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
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Lib.Loadable exposing (Loadable(..))
import Ui


type alias Model =
    { users : Loadable Client.ApiError (List User.User)
    , actionError : Maybe String
    }


type Msg
    = UsersLoaded (Result Client.ApiError (List User.User))
    | NavigateCreateUser
    | EditClicked String


type OutMsg
    = NoOp
    | RequestUsers
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { users = Loading
      , actionError = Nothing
      }
    , RequestUsers
    )


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

        EditClicked userId ->
            ( model, Cmd.none, Navigate (AdminEditUser userId) )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (Element.el
            [ Element.alignRight ]
            (Ui.button "Create User" NavigateCreateUser)
            :: (errorView model.actionError
                    ++ usersView model
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
        , Ui.button "Edit" (EditClicked user.id)
        ]


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
