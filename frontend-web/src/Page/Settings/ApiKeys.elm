module Page.Settings.ApiKeys exposing
    ( Dialog(..)
    , LoadedModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , isBusy
    , modalView
    , skeletonView
    , update
    , view
    )

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..))
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Region as Region
import I18n
import Lib.Date as LocalDate
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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
                            ( Loaded { keys = keys, dialog = NoDialog, nextRequestId = 1 }
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
                                                    List.filter (\item -> item.id /= key.id)
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
    keys |> List.filter (\key -> key.id == keyId) |> List.head


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
                [ Skeleton.busy
                    { label = I18n.t env.language TidCommonLoading }
                    [ skeletonView env ]
                ]

        LoadFailed error ->
            UiPage.pageContainer
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = Client.displayError error, onRetry = RetryClicked }
                ]

        Loaded loaded ->
            UiPage.pageContainer
                [ Element.el
                    [ Element.width Element.fill
                    , UiCommon.testId "api-keys-description"
                    ]
                    (Typography.mutedBodyParagraph env.theme
                        (I18n.t env.language TidApiKeysDescription)
                    )
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
                [ Element.el
                    [ Element.width Element.fill
                    , UiCommon.testId "empty-state"
                    ]
                    (Typography.mutedBodyParagraph env.theme
                        (I18n.t env.language TidApiKeysEmpty)
                    )
                ]

            else
                List.intersperse (Surface.hairline env.theme) (List.map (keyRow env) loaded.keys)
        , footer = Nothing
        }


keyRow : Env -> ApiKey -> Element Msg
keyRow env key =
    keyRowFrame env
        { rootAttrs = []
        , title = Typography.wrappedListItemTitle env.theme key.name
        , subtitle =
            [ Typography.mutedBodyParagraph env.theme
                (I18n.t env.language (TidApiKeysHint key.tokenHint))
            , Typography.mutedCaptionParagraph env.theme (keyMeta env.language key)
            ]
        , trailing =
            [ Chip.badge env.theme (scopeLabel env.language key.scope)
            , Button.textButtonWithAttributes env.device
                env.theme
                [ Region.description (I18n.t env.language (TidApiKeysRevokeNamed key.name)) ]
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


{-| Phone rows stack the badge/revoke actions below the text so the text keeps
the full width and the row geometry matches the skeleton. Wider screens keep
the inline `Surface.staticRow` layout.
-}
keyRowFrame :
    Env
    ->
        { rootAttrs : List (Element.Attribute msg)
        , title : Element msg
        , subtitle : List (Element msg)
        , trailing : List (Element msg)
        }
    -> Element msg
keyRowFrame env config =
    Element.el
        (Element.width Element.fill :: config.rootAttrs)
        (if UiCommon.isSmall env.device then
            Element.column
                [ Element.width Element.fill
                , Element.padding DesignTokens.space16
                , Element.spacing DesignTokens.space12
                , UiCommon.testId "list-row"
                ]
                [ Element.column
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space4
                    , UiCommon.minWidthZero
                    , Element.alignTop
                    ]
                    (config.title :: config.subtitle)
                , Element.row
                    [ Element.padding DesignTokens.space8
                    , Element.spacing DesignTokens.space12
                    , Element.alignTop
                    ]
                    config.trailing
                ]

         else
            Surface.staticRow
                { leading = []
                , title = config.title
                , subtitle = config.subtitle
                , trailing = config.trailing
                }
        )


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
                    I18n.t language (TidApiKeysLastUsed (formatTimestamp language timestamp))

                Nothing ->
                    I18n.t language TidApiKeysNeverUsed
            )
        , Just
            (case key.expiresAt of
                Just timestamp ->
                    I18n.t language (TidApiKeysExpires (formatTimestamp language timestamp))

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
                    Just (revokeModal env key { pending = False, error = maybeError })

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


{-| The page body below `UiPage.pageContainer`. The caller owns the single
`Skeleton.busy` wrapper so the page view and `Page.bootstrapView` cannot nest
status regions.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Element.el
            [ Element.width Element.fill
            , UiCommon.testId "api-keys-description"
            ]
            (Typography.mutedBodyParagraph env.theme
                (I18n.t env.language TidApiKeysDescription)
            )
        , Surface.section env.theme
            { header = Just (Skeleton.button env.theme)
            , body =
                List.intersperse (Surface.hairline env.theme)
                    (List.map (\_ -> keyRowSkeleton env) (List.range 1 3))
            , footer = Nothing
            }
        ]


{-| A key row: a 17px title, a body 17px hint plus a 13px meta line, and the
scope badge with the 48px revoke action.
-}
keyRowSkeleton : Env -> Element msg
keyRowSkeleton env =
    keyRowFrame env
        { rootAttrs = [ UiCommon.skeletonRegion ]
        , title = Skeleton.elLine env.theme { size = 17, width = Element.fill }
        , subtitle =
            [ Skeleton.elLine env.theme { size = 17, width = Element.fill }
            , keyMetaSkeleton env
            ]
        , trailing =
            [ Skeleton.badge env.theme
            , Skeleton.barCustom env.theme
                { width = Element.px 80, height = 48 }
            ]
        }


{-| The en-US meta line wraps to two lines at Phone width. On wider screens it
stays one line. The meta copy is data/locale-derived, so longer variants remain
variable below the first-row anchor.
-}
keyMetaSkeleton : Env -> Element msg
keyMetaSkeleton env =
    if UiCommon.isSmall env.device then
        Element.column
            [ Element.width Element.fill
            , Element.spacing 0
            ]
            (List.repeat 2
                (Skeleton.paragraphLine env.theme
                    { size = 13, spacing = 3, width = Element.fill }
                )
            )

    else
        Skeleton.elLine env.theme { size = 13, width = Element.fill }
