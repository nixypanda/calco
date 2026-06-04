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
import Element.Input as Input
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
        [ case model.actionError of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , bodyView model
        ]


bodyView : Model -> Element Msg
bodyView model =
    case model.users of
        Success [] ->
            Ui.card [ createUserRow ]

        Success users ->
            Ui.card (List.map userRow users ++ [ createUserRow ])

        Loading ->
            Ui.loading "Loading users..."

        _ ->
            Element.none


userRow : User.User -> Element Msg
userRow user =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        ]
        { onPress = Just (EditClicked user.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.column [ Element.width Element.fill, Element.spacing 2 ]
                    [ Element.el [ Font.bold ] (Element.text user.username)
                    , Ui.mutedText user.displayName
                    ]
                , statusPill user.status
                ]
        }


statusPill : String -> Element Msg
statusPill status =
    Element.el
        [ Element.paddingXY 8 3
        , Border.rounded 10
        , Font.size 12
        , Font.medium
        , Element.alignRight
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
