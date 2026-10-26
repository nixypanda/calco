module Page.Settings.ApiKeys exposing
    ( CopyState(..)
    , CreateError(..)
    , CreateForm
    , CreateState(..)
    , Dialog(..)
    , ExpiryChoice(..)
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
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..), CreatableScope(..), CreateRequest)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Html
import Html.Attributes
import I18n
import Lib.Date as LocalDate
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Input as UiInput
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
    | Creating CreateForm
    | Created Data.ApiKey.CreatedApiKey CopyState
    | ConfirmRevoke ApiKey (Maybe String)
    | Revoking ApiKey


type CopyState
    = CopyIdle
    | CopyPending Int
    | CopySucceeded
    | CopyFailed


type alias CreateForm =
    { name : String
    , scope : CreatableScope
    , expiry : ExpiryChoice
    , expiryOpen : Bool
    , state : CreateState
    }


type ExpiryChoice
    = ExpireInDays Int
    | NeverExpires


type CreateState
    = Editing
    | Invalid CreateError
    | Submitting Int
    | Failed String


type CreateError
    = NameRequired
    | NameTooLong


type OutMsg
    = NoOp
    | RequestList
    | RequestCreate Int CreateRequest
    | RequestRevoke ApiKey
    | CopyText Int String
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestList )


emptyCreateForm : CreateForm
emptyCreateForm =
    { name = ""
    , scope = CreatableRead
    , expiry = ExpireInDays 90
    , expiryOpen = False
    , state = Editing
    }



-- UPDATE


type Msg
    = ApiKeysLoaded (Result Client.ApiError (List ApiKey))
    | RetryClicked
    | CreateClicked
    | CreateNameChanged String
    | CreateScopeChanged CreatableScope
    | CreateExpiryChanged ExpiryChoice
    | CreateExpiryToggled
    | CreateSubmitted
    | CreateCompleted Int (Result Client.ApiError Data.ApiKey.CreatedApiKey)
    | CreateCancelled
    | CopyClicked
    | CopyCompleted Int Bool
    | CreatedDoneClicked
    | RevokeClicked ApiKey
    | RevokeCancelled
    | RevokeConfirmed ApiKey
    | RevokeCompleted ApiKey (Result Client.ApiError ())


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ApiKeysLoaded result ->
            case result of
                Ok keys ->
                    case model of
                        Loaded loaded ->
                            let
                                mergedKeys : List ApiKey
                                mergedKeys =
                                    case loaded.dialog of
                                        Created created _ ->
                                            mergeKeys [ created.apiKey ] keys

                                        _ ->
                                            keys
                            in
                            ( Loaded { loaded | keys = mergedKeys }, Cmd.none, NoOp )

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
                            ( Loaded { loaded | dialog = Creating emptyCreateForm }
                            , Cmd.none
                            , NoOp
                            )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateNameChanged name ->
            updateCreateForm
                (\form -> { form | name = name, state = Editing })
                model

        CreateScopeChanged scope ->
            updateCreateForm
                (\form -> { form | scope = scope, state = Editing })
                model

        CreateExpiryChanged expiry ->
            updateCreateForm
                (\form -> { form | expiry = expiry, expiryOpen = False, state = Editing })
                model

        CreateExpiryToggled ->
            updateCreateForm
                (\form -> { form | expiryOpen = not form.expiryOpen })
                model

        CreateSubmitted ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Creating form ->
                            if isSubmitting form.state then
                                ( model, Cmd.none, NoOp )

                            else
                                case validateCreateForm form of
                                    Ok request ->
                                        let
                                            requestId : Int
                                            requestId =
                                                loaded.nextRequestId
                                        in
                                        ( Loaded
                                            { loaded
                                                | dialog =
                                                    Creating
                                                        { form | state = Submitting requestId }
                                                , nextRequestId = requestId + 1
                                            }
                                        , Cmd.none
                                        , RequestCreate requestId request
                                        )

                                    Err error ->
                                        ( Loaded
                                            { loaded
                                                | dialog = Creating { form | state = Invalid error }
                                            }
                                        , Cmd.none
                                        , NoOp
                                        )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateCompleted requestId result ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Creating form ->
                            if form.state == Submitting requestId then
                                case result of
                                    Ok created ->
                                        ( Loaded
                                            { loaded
                                                | keys =
                                                    mergeKeys [ created.apiKey ] loaded.keys
                                                , dialog = Created created CopyIdle
                                            }
                                        , Cmd.none
                                        , NoOp
                                        )

                                    Err error ->
                                        Client.failure
                                            { noOp = NoOp
                                            , sessionExpired = SessionExpired
                                            , applyError =
                                                applyCreateFailure requestId
                                            }
                                            error
                                            model

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateCancelled ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Creating form ->
                            if isSubmitting form.state then
                                ( model, Cmd.none, NoOp )

                            else
                                ( Loaded { loaded | dialog = NoDialog }, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CopyClicked ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Created created copyState ->
                            case copyState of
                                CopyPending _ ->
                                    ( model, Cmd.none, NoOp )

                                _ ->
                                    let
                                        copyId : Int
                                        copyId =
                                            loaded.nextRequestId
                                    in
                                    ( Loaded
                                        { loaded
                                            | dialog = Created created (CopyPending copyId)
                                            , nextRequestId = copyId + 1
                                        }
                                    , Cmd.none
                                    , CopyText copyId created.token
                                    )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CopyCompleted copyId succeeded ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Created created (CopyPending pendingCopyId) ->
                            if pendingCopyId == copyId then
                                ( Loaded
                                    { loaded
                                        | dialog =
                                            Created created
                                                (if succeeded then
                                                    CopySucceeded

                                                 else
                                                    CopyFailed
                                                )
                                    }
                                , Cmd.none
                                , NoOp
                                )

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreatedDoneClicked ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Created _ (CopyPending _) ->
                            ( model, Cmd.none, NoOp )

                        Created _ _ ->
                            ( Loaded { loaded | dialog = NoDialog }, Cmd.none, NoOp )

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
                                ( Loaded { loaded | dialog = Revoking current }
                                , Cmd.none
                                , RequestRevoke current
                                )

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RevokeCompleted key result ->
            case model of
                Loaded loaded ->
                    case loaded.dialog of
                        Revoking current ->
                            if current.id == key.id then
                                case result of
                                    Ok _ ->
                                        ( Loaded
                                            { keys =
                                                List.filter
                                                    (\item -> item.id /= key.id)
                                                    loaded.keys
                                            , dialog = NoDialog
                                            , nextRequestId = loaded.nextRequestId
                                            }
                                        , Cmd.none
                                        , NoOp
                                        )

                                    Err error ->
                                        Client.failure
                                            { noOp = NoOp
                                            , sessionExpired = SessionExpired
                                            , applyError = applyRevokeFailure key
                                            }
                                            error
                                            model

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


updateCreateForm :
    (CreateForm -> CreateForm)
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
updateCreateForm transform model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                Creating form ->
                    if isSubmitting form.state then
                        ( model, Cmd.none, NoOp )

                    else
                        ( Loaded { loaded | dialog = Creating (transform form) }
                        , Cmd.none
                        , NoOp
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )


isSubmitting : CreateState -> Bool
isSubmitting state =
    case state of
        Submitting _ ->
            True

        _ ->
            False


{-| Put preferred keys first and drop any server copy with the same id. A
created row therefore survives a stale refresh, while a refresh that already
contains it cannot duplicate the row.
-}
mergeKeys : List ApiKey -> List ApiKey -> List ApiKey
mergeKeys preferred existing =
    List.foldr upsertKey existing preferred


upsertKey : ApiKey -> List ApiKey -> List ApiKey
upsertKey key keys =
    key :: List.filter (\item -> item.id /= key.id) keys


applyCreateFailure : Int -> String -> Model -> Model
applyCreateFailure requestId message model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                Creating form ->
                    if form.state == Submitting requestId then
                        Loaded { loaded | dialog = Creating { form | state = Failed message } }

                    else
                        model

                _ ->
                    model

        _ ->
            model


applyRevokeFailure : ApiKey -> String -> Model -> Model
applyRevokeFailure key message model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                Revoking _ ->
                    Loaded { loaded | dialog = ConfirmRevoke key (Just message) }

                _ ->
                    model

        _ ->
            model


validateCreateForm : CreateForm -> Result CreateError CreateRequest
validateCreateForm form =
    let
        name : String
        name =
            String.trim form.name
    in
    if String.isEmpty name then
        Err NameRequired

    else if String.length name > 64 then
        Err NameTooLong

    else
        Ok
            { name = name
            , scope = form.scope
            , expiresInDays = expiresInDays form.expiry
            }


expiresInDays : ExpiryChoice -> Maybe Int
expiresInDays expiry =
    case expiry of
        ExpireInDays days ->
            Just days

        NeverExpires ->
            Nothing



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        (case model of
            Loading ->
                [ apiKeysSkeleton env.theme ]

            LoadFailed error ->
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = Client.displayError error, onRetry = RetryClicked }
                ]

            Loaded loaded ->
                [ keysSection env loaded ]
        )


keysSection : Env -> LoadedModel -> Element Msg
keysSection env loaded =
    Surface.section env.theme
        { header =
            Just
                (Surface.sectionHeader
                    { title =
                        Typography.sectionTitle env.theme
                            (I18n.t env.language TidApiKeysListTitle)
                    , description =
                        Just
                            (Typography.mutedParagraph env.theme
                                (I18n.t env.language TidApiKeysDescription)
                            )
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
        , footer =
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
        }


keyRow : Env -> ApiKey -> Element Msg
keyRow env key =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.wrappedRow
            [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ Element.el
                [ Element.width Element.fill, Element.alignTop ]
                (Typography.wrappedListItemTitle env.theme key.name)
            , Element.el [ Element.alignTop ]
                (Chip.badge env.theme (scopeLabel env.language key.scope))
            ]
        , Typography.mutedCaptionParagraph env.theme
            (I18n.t env.language (TidApiKeysHint key.tokenHint))
        , Typography.mutedCaptionParagraph env.theme (keyMetadata env.language key)
        , Button.textButtonWithAttributes env.device
            env.theme
            [ Element.htmlAttribute
                (Html.Attributes.attribute
                    "aria-label"
                    (I18n.t env.language (TidApiKeysRevokeNamed key.name))
                )
            ]
            { tone = Button.DangerOutline
            , width = Button.ResponsiveWidth
            , label = I18n.t env.language TidApiKeysRevoke
            , onPress = RevokeClicked key
            , submitState = Nothing
            , submittingLabel = Nothing
            , trailing = Nothing
            }
        ]


keyMetadata : Language -> ApiKey -> String
keyMetadata language key =
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


creatableScopeDescription : Language -> CreatableScope -> String
creatableScopeDescription language scope =
    case scope of
        CreatableRead ->
            I18n.t language TidApiKeysScopeReadDescription

        CreatableReadWrite ->
            I18n.t language TidApiKeysScopeReadWriteDescription


modalView : Env -> Model -> Maybe (Element Msg)
modalView env model =
    case model of
        Loaded loaded ->
            case loaded.dialog of
                NoDialog ->
                    Nothing

                Creating form ->
                    Just (createModal env form)

                Created created copyState ->
                    Just (createdModal env created copyState)

                ConfirmRevoke key maybeError ->
                    Just
                        (revokeModal env
                            key
                            { pending = False, error = maybeError }
                        )

                Revoking key ->
                    Just (revokeModal env key { pending = True, error = Nothing })

        _ ->
            Nothing


createModal : Env -> CreateForm -> Element Msg
createModal env form =
    let
        submitting : Bool
        submitting =
            isSubmitting form.state
    in
    Feedback.modalOverlay env.theme
        { title = I18n.t env.language TidApiKeysCreateTitle
        , body =
            [ Typography.mutedParagraph env.theme
                (I18n.t env.language TidApiKeysCreateDescription)
            , nameField env submitting form.name
            , scopeField env submitting form.scope
            , UiInput.selectDropdownWithState env.device
                env.theme
                env.language
                { label = I18n.t env.language TidApiKeysExpiry
                , selected = form.expiry
                , options = expiryOptions env.language
                , onChange = CreateExpiryChanged
                , isOpen = form.expiryOpen
                , onToggle = CreateExpiryToggled
                , disabled = submitting
                }
            , createErrorBanner env form.state
            ]
        , actions =
            Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ modalButton env
                    { tone = Button.PrimaryOutline
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidCommonCancel
                    , onPress = CreateCancelled
                    , submitState =
                        Just
                            (if submitting then
                                Button.Disabled

                             else
                                Button.Idle
                            )
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                , modalButton env
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysCreate
                    , onPress = CreateSubmitted
                    , submitState = Just (Button.submittingOrIdle submitting)
                    , submittingLabel = Just (I18n.t env.language TidCommonCreating)
                    , trailing = Nothing
                    }
                ]
        , onBackgroundPress =
            if submitting then
                Nothing

            else
                Just CreateCancelled
        }


nameField : Env -> Bool -> String -> Element Msg
nameField env disabled value =
    let
        config : UiInput.InputConfig Msg
        config =
            { label = I18n.t env.language TidApiKeysName
            , value = value
            , onChange = CreateNameChanged
            }
    in
    if disabled then
        UiInput.disabledInput env.theme config

    else
        UiInput.input env.theme config


scopeField : Env -> Bool -> CreatableScope -> Element Msg
scopeField env disabled selected =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
        [ UiInput.fieldLabel env.theme (I18n.t env.language TidApiKeysScope)
        , Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ Element.el [ Element.width Element.fill ]
                (UiInput.optionRowWithState env.theme
                    { label = I18n.t env.language TidApiKeysScopeRead
                    , trailing = Nothing
                    , selected = selected == CreatableRead
                    , onPress = CreateScopeChanged CreatableRead
                    , disabled = disabled
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (UiInput.optionRowWithState env.theme
                    { label = I18n.t env.language TidApiKeysScopeReadWrite
                    , trailing = Nothing
                    , selected = selected == CreatableReadWrite
                    , onPress = CreateScopeChanged CreatableReadWrite
                    , disabled = disabled
                    }
                )
            ]
        , Typography.mutedCaption env.theme (creatableScopeDescription env.language selected)
        ]


expiryOptions : Language -> List ( ExpiryChoice, String )
expiryOptions language =
    [ ( ExpireInDays 30, I18n.t language TidApiKeysExpiry30Days )
    , ( ExpireInDays 90, I18n.t language TidApiKeysExpiry90Days )
    , ( ExpireInDays 365, I18n.t language TidApiKeysExpiry365Days )
    , ( NeverExpires, I18n.t language TidApiKeysExpiryNever )
    ]


createErrorBanner : Env -> CreateState -> Element Msg
createErrorBanner env state =
    case state of
        Invalid error ->
            Feedback.errorBanner env.theme (createErrorMessage env.language error)

        Failed message ->
            Feedback.errorBanner env.theme message

        Editing ->
            Element.none

        Submitting _ ->
            Element.none


createErrorMessage : Language -> CreateError -> String
createErrorMessage language error =
    case error of
        NameRequired ->
            I18n.t language TidApiKeysNameRequired

        NameTooLong ->
            I18n.t language TidApiKeysNameTooLong


createdModal : Env -> Data.ApiKey.CreatedApiKey -> CopyState -> Element Msg
createdModal env created copyState =
    let
        copyInFlight : Bool
        copyInFlight =
            isCopyPending copyState
    in
    Feedback.modalOverlay env.theme
        { title = I18n.t env.language TidApiKeysCreatedTitle
        , body =
            [ Feedback.warningBanner env.theme
                (I18n.t env.language TidApiKeysCreatedWarning)
            , secretBox env created.token
            , copyFeedback env copyState
            , Typography.mutedParagraph env.theme
                (I18n.t env.language TidApiKeysUsage)
            , codeBox env (I18n.t env.language TidApiKeysUsageExample)
            ]
        , actions =
            Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ modalButtonWithAttributes env
                    [ Element.htmlAttribute
                        (Html.Attributes.attribute
                            "aria-label"
                            (I18n.t env.language TidApiKeysCopyAria)
                        )
                    , Element.htmlAttribute
                        (Html.Attributes.title (I18n.t env.language TidApiKeysCopyAria))
                    ]
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysCopy
                    , onPress = CopyClicked
                    , submitState =
                        Just
                            (if copyInFlight then
                                Button.Disabled

                             else
                                Button.Idle
                            )
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                , modalButton env
                    { tone = Button.PrimaryOutline
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysDone
                    , onPress = CreatedDoneClicked
                    , submitState =
                        Just
                            (if copyInFlight then
                                Button.Disabled

                             else
                                Button.Idle
                            )
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                ]
        , onBackgroundPress = Nothing
        }


isCopyPending : CopyState -> Bool
isCopyPending state =
    case state of
        CopyPending _ ->
            True

        _ ->
            False


copyFeedback : Env -> CopyState -> Element Msg
copyFeedback env state =
    case state of
        CopySucceeded ->
            Element.el
                [ Font.color env.theme.statusGreen
                , Element.htmlAttribute (Html.Attributes.attribute "role" "status")
                ]
                (Element.text (I18n.t env.language TidApiKeysCopied))

        CopyFailed ->
            Element.el
                [ Element.width Element.fill
                , Element.htmlAttribute (Html.Attributes.attribute "role" "alert")
                ]
                (Feedback.errorBanner env.theme (I18n.t env.language TidApiKeysCopyFailed))

        CopyIdle ->
            Element.none

        CopyPending _ ->
            Element.el
                [ Element.htmlAttribute (Html.Attributes.attribute "role" "status") ]
                (Typography.mutedCaption env.theme (I18n.t env.language TidApiKeysCopying))


secretBox : Env -> String -> Element Msg
secretBox env token =
    Element.el
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        , Background.color env.theme.inputFill
        , Border.rounded DesignTokens.radiusControl
        ]
        (Element.html
            (Html.textarea
                [ Html.Attributes.readonly True
                , Html.Attributes.rows 2
                , Html.Attributes.class "ui-secret-token"
                , Html.Attributes.attribute "spellcheck" "false"
                , Html.Attributes.attribute
                    "aria-label"
                    (I18n.t env.language TidApiKeysSecretLabel)
                ]
                [ Html.text token ]
            )
        )


codeBox : Env -> String -> Element Msg
codeBox env code =
    Element.el
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        , Background.color env.theme.inputFill
        , Border.rounded DesignTokens.radiusControl
        ]
        (Element.paragraph
            [ Element.width Element.fill
            , Font.family [ Font.monospace ]
            , Font.size 13
            , Font.color env.theme.textPrimary
            , Element.htmlAttribute (Html.Attributes.style "overflow-wrap" "anywhere")
            ]
            [ Element.text code ]
        )


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


modalButton : Env -> Button.ButtonConfig Msg -> Element Msg
modalButton env config =
    Element.el [ Element.width Element.fill ]
        (Button.textButton env.device env.theme config)


modalButtonWithAttributes :
    Env
    -> List (Element.Attribute Msg)
    -> Button.ButtonConfig Msg
    -> Element Msg
modalButtonWithAttributes env attributes config =
    Element.el [ Element.width Element.fill ]
        (Button.textButtonWithAttributes env.device env.theme attributes config)


apiKeysSkeleton : Theme -> Element msg
apiKeysSkeleton theme =
    Surface.section theme
        { header =
            Just (Skeleton.barCustom theme { width = Element.px 180, height = 24 })
        , body =
            [ Skeleton.bar theme
            , Skeleton.listRow theme
            , Skeleton.listRow theme
            , Skeleton.button theme
            ]
        , footer = Nothing
        }
