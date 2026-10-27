module Page.Settings.ApiKeys exposing
    ( Dialog(..)
    , LoadedModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , modalView
    , update
    , view
    )

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..))
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Html.Attributes
import I18n
import Lib.Date as LocalDate
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.DeleteModal



-- MODEL


type Model
    = Loading
    | LoadFailed Client.ApiError
    | Loaded LoadedModel


type alias LoadedModel =
    { keys : List ApiKey
    , dialog : Dialog
    , nextRequestId : Int
    }


type Dialog
    = NoDialog
    | ConfirmRevoke ApiKey (Maybe String)
    | Revoking Int ApiKey


type OutMsg
    = NoOp
    | RequestList
    | RequestRevoke Int ApiKey
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestList )



-- UPDATE


type Msg
    = ApiKeysLoaded (Result Client.ApiError (List ApiKey))
    | RetryClicked
    | CreateClicked
    | RevokeClicked ApiKey
    | RevokeCancelled
    | RevokeConfirmed ApiKey
    | RevokeCompleted Int ApiKey (Result Client.ApiError ())


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ApiKeysLoaded result ->
            case result of
                Ok keys ->
                    case model of
                        Loaded loaded ->
                            ( Loaded
                                { loaded
                                    | keys = keys
                                    , dialog = refreshDialog loaded.dialog keys
                                }
                            , Cmd.none
                            , NoOp
                            )

                        _ ->
                            ( Loaded
                                { keys = keys
                                , dialog = NoDialog
                                , nextRequestId = 1
                                }
                            , Cmd.none
                            , NoOp
                            )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \_ current ->
                                case current of
                                    Loaded _ ->
                                        current

                                    _ ->
                                        LoadFailed error
                        }
                        error
                        model

        RetryClicked ->
            case model of
                LoadFailed _ ->
                    ( Loading, Cmd.none, RequestList )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateClicked ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        NoDialog ->
                            ( model, Cmd.none, Navigate SettingsApiKeyCreate )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RevokeClicked key ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        NoDialog ->
                            ( Loaded { loaded | dialog = ConfirmRevoke key Nothing }
                            , Cmd.none
                            , NoOp
                            )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RevokeCancelled ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        ConfirmRevoke _ _ ->
                            ( Loaded { loaded | dialog = NoDialog }, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RevokeConfirmed key ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        ConfirmRevoke current _ ->
                            if current.id == key.id then
                                let
                                    requestId : Int
                                    requestId =
                                        loaded.nextRequestId
                                in
                                ( Loaded
                                    { loaded
                                        | dialog = Revoking requestId current
                                        , nextRequestId = requestId + 1
                                    }
                                , Cmd.none
                                , RequestRevoke requestId current
                                )

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RevokeCompleted requestId key result ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Revoking pendingRequestId current ->
                            if pendingRequestId == requestId && current.id == key.id then
                                case result of
                                    Ok _ ->
                                        ( Loaded
                                            { loaded
                                                | keys =
                                                    List.filter
                                                        (\item -> item.id /= key.id)
                                                        loaded.keys
                                                , dialog = NoDialog
                                            }
                                        , Cmd.none
                                        , NoOp
                                        )

                                    Err error ->
                                        Client.failure
                                            { noOp = NoOp
                                            , sessionExpired = SessionExpired
                                            , applyError = applyRevokeFailure requestId key.id
                                            }
                                            error
                                            model

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


refreshDialog : Dialog -> List ApiKey -> Dialog
refreshDialog dialog keys =
    case dialog of
        NoDialog ->
            NoDialog

        ConfirmRevoke key maybeError ->
            case findKey key.id keys of
                Just refreshed ->
                    ConfirmRevoke refreshed maybeError

                Nothing ->
                    NoDialog

        Revoking requestId key ->
            case findKey key.id keys of
                Just refreshed ->
                    Revoking requestId refreshed

                Nothing ->
                    NoDialog


findKey : String -> List ApiKey -> Maybe ApiKey
findKey keyId keys =
    keys
        |> List.filter (\key -> key.id == keyId)
        |> List.head


applyRevokeFailure : Int -> String -> String -> Model -> Model
applyRevokeFailure requestId keyId message model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                Revoking pendingRequestId current ->
                    if pendingRequestId == requestId && current.id == keyId then
                        Loaded { loaded | dialog = ConfirmRevoke current (Just message) }

                    else
                        model

                _ ->
                    model

        _ ->
            model



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    case model of
        Loading ->
            UiPage.pageContainer
                [ apiKeysSkeleton env.theme ]

        LoadFailed error ->
            UiPage.pageContainer
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = Client.displayError error, onRetry = RetryClicked }
                ]

        Loaded loaded ->
            UiPage.pageContainer
                [ Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidApiKeysDescription)
                , keysSection env loaded
                ]


keysSection : Env -> LoadedModel -> Element Msg
keysSection env loaded =
    Surface.section env.theme
        { header =
            Just
                (Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysCreate
                    , onPress = CreateClicked
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
        , body =
            if List.isEmpty loaded.keys then
                [ Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidApiKeysEmpty)
                ]

            else
                List.intersperse (Surface.hairline env.theme)
                    (List.map (keyRow env) loaded.keys)
        , footer = Nothing
        }


keyRow : Env -> ApiKey -> Element Msg
keyRow env key =
    Surface.staticRow
        { leading = []
        , title = Typography.wrappedListItemTitle env.theme key.name
        , subtitle =
            [ Typography.mutedBodyParagraph env.theme
                (I18n.t env.language (TidApiKeysHint key.tokenHint))
            , Typography.mutedCaptionParagraph env.theme
                (keyMeta env.language key)
            ]
        , trailing =
            [ Chip.badge env.theme (scopeLabel env.language key.scope)
            , Button.textButtonWithAttributes env.device
                env.theme
                [ Element.htmlAttribute
                    (Html.Attributes.attribute
                        "aria-label"
                        (I18n.t env.language (TidApiKeysRevokeNamed key.name))
                    )
                ]
                { tone = Button.DangerOutline
                , width = Button.ContentWidth
                , label = I18n.t env.language TidApiKeysRevoke
                , onPress = RevokeClicked key
                , submitState = Nothing
                , submittingLabel = Nothing
                , trailing = Nothing
                }
            ]
        }


keyMeta : Language -> ApiKey -> String
keyMeta language key =
    Text.dotSeparated
        [ Just
            (I18n.t language
                (TidApiKeysCreatedOn (formatTimestamp language key.createdAt))
            )
        , Just
            (case key.lastUsedAt of
                Just timestamp ->
                    I18n.t language
                        (TidApiKeysLastUsed (formatTimestamp language timestamp))

                Nothing ->
                    I18n.t language TidApiKeysNeverUsed
            )
        , Just
            (case key.expiresAt of
                Just timestamp ->
                    I18n.t language
                        (TidApiKeysExpires (formatTimestamp language timestamp))

                Nothing ->
                    I18n.t language TidApiKeysNeverExpires
            )
        ]


formatTimestamp : Language -> String -> String
formatTimestamp language raw =
    case LocalDate.fromString (String.left 10 raw) of
        Just date ->
            LocalDate.display language date

        Nothing ->
            raw


scopeLabel : Language -> ApiKeyScope -> String
scopeLabel language scope =
    case scope of
        Read ->
            I18n.t language TidApiKeysScopeRead

        ReadWrite ->
            I18n.t language TidApiKeysScopeReadWrite

        UnknownScope ->
            I18n.t language TidApiKeysScopeUnknown


modalView : Env -> Model -> Maybe (Element Msg)
modalView env model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                NoDialog ->
                    Nothing

                ConfirmRevoke key maybeError ->
                    Just
                        (revokeModal env
                            key
                            { pending = False, error = maybeError }
                        )

                Revoking _ key ->
                    Just (revokeModal env key { pending = True, error = Nothing })

        _ ->
            Nothing


revokeModal :
    Env
    -> ApiKey
    -> { pending : Bool, error : Maybe String }
    -> Element Msg
revokeModal env key state =
    View.DeleteModal.confirmModalView env
        { title = I18n.t env.language TidApiKeysRevokeTitle
        , description =
            I18n.t env.language (TidApiKeysRevokeDescription key.name key.tokenHint)
        , confirmLabel = I18n.t env.language TidApiKeysConfirmRevoke
        , pendingLabel = I18n.t env.language TidApiKeysRevoking
        , onCancel = RevokeCancelled
        , onConfirm = RevokeConfirmed key
        }
        state


apiKeysSkeleton : Theme -> Element msg
apiKeysSkeleton theme =
    Surface.section theme
        { header =
            Just (Skeleton.button theme)
        , body =
            List.intersperse (Surface.hairline theme)
                (List.map (\_ -> Skeleton.listRow theme) (List.range 1 3))
        , footer = Nothing
        }
