module Page.Users.Dashboard exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , init
    , isBusy
    , skeletonView
    , update
    )

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.Env exposing (Env)
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
    ( Loading, RequestUsers )


{-| Only the initial fetch is busy; `LoadFailed` is a settled error state.
-}
isBusy : Model -> Bool
isBusy model =
    case model of
        Loading ->
            True

        _ ->
            False



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


contentView : Env -> Model -> Element Msg
contentView env model =
    bodyView env model


bodyView : Env -> Model -> Element Msg
bodyView env model =
    case model of
        Loaded users ->
            Surface.section env.theme
                { header =
                    Just
                        (Typography.sectionTitle env.theme
                            (I18n.t env.language TidUsersSectionTitle)
                        )
                , body =
                    List.map
                        (\user ->
                            userListRow env.theme { user = user, onSelect = NavigateEditUser }
                        )
                        users
                , footer =
                    Just
                        (Element.el
                            [ Element.width Element.fill, UiCommon.testId "list-footer" ]
                            (Button.textButton env.device
                                env.theme
                                { tone = Button.Ghost
                                , width = Button.FullWidth
                                , label = I18n.t env.language TidUsersCreateUser
                                , onPress = NavigateCreateUser
                                , submitState = Nothing
                                , submittingLabel = Nothing
                                , trailing = Nothing
                                }
                            )
                        )
                }

        Loading ->
            Skeleton.busy
                { label = I18n.t env.language TidCommonLoading }
                [ skeletonView env ]

        LoadFailed error ->
            Feedback.errorBanner env.theme (Client.displayError error)


userListRow : Theme -> { user : User, onSelect : String -> msg } -> Element msg
userListRow theme config =
    Surface.listRow
        { onSelect = config.onSelect config.user.id
        , leading = []
        , title = Typography.wrappedListItemTitle theme config.user.username
        , subtitle = [ Typography.mutedBodyParagraph theme config.user.displayName ]
        , trailing = [ Chip.statusBadge theme config.user.status ]
        }


{-| The admin list body. The caller owns the single `Skeleton.busy` wrapper so
the page view and `Page.bootstrapView` cannot nest status regions.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Surface.section env.theme
        { header =
            Just
                (Skeleton.elLine env.theme
                    { size = 24, width = Element.px 120 }
                )
        , body =
            List.map (\_ -> userRowSkeleton env) (List.range 1 3)
        , footer =
            Just
                (Element.el
                    [ Element.width Element.fill, UiCommon.testId "list-footer" ]
                    (Skeleton.button env.theme)
                )
        }


userRowSkeleton : Env -> Element msg
userRowSkeleton env =
    Skeleton.row
        { leading = []
        , -- The loaded username and display name are single-line 16px
          -- paragraphs; each measured line box is 17px.
          title = Skeleton.elLine env.theme { size = 17, width = Element.fill }
        , subtitle = [ Skeleton.elLine env.theme { size = 17, width = Element.fill } ]
        , trailing = [ Skeleton.badge env.theme ]
        }
