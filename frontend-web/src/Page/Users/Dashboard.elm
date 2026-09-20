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
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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


contentView : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
contentView { model, device, theme, language } =
    bodyView device theme language model


bodyView : Device -> Theme -> Language -> Model -> Element Msg
bodyView device theme language model =
    case model of
        Loaded users ->
            Surface.section theme
                { header =
                    Just (Typography.sectionTitle theme (I18n.t language TidUsersSectionTitle))
                , body =
                    List.map
                        (\user ->
                            userListRow
                                theme
                                { user = user, onSelect = NavigateEditUser }
                        )
                        users
                , footer =
                    Just
                        (Button.textButton device
                            theme
                            { tone = Button.Ghost
                            , width = Button.FullWidth
                            , label = I18n.t language TidUsersCreateUser
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
            Feedback.errorBanner theme (Client.displayError error)


userListRow : Theme -> { user : User, onSelect : String -> msg } -> Element msg
userListRow theme config =
    Surface.listRow
        { onSelect = config.onSelect config.user.id
        , leading = []
        , title = Typography.wrappedListItemTitle theme config.user.username
        , subtitle = [ Typography.mutedBodyParagraph theme config.user.displayName ]
        , trailing = [ Chip.statusBadge theme config.user.status ]
        }


adminDashboardSkeleton : Theme -> Element msg
adminDashboardSkeleton theme =
    Surface.section theme
        { header =
            Just
                (Skeleton.barCustom theme
                    { width = Element.px 120, height = 24 }
                )
        , body =
            List.map (\_ -> Skeleton.listRow theme)
                (List.range 1 3)
        , footer = Just (Skeleton.button theme)
        }
