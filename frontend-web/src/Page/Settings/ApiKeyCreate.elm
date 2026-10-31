module Page.Settings.ApiKeyCreate exposing
    ( CopyState(..)
    , CreateError(..)
    , CreateForm
    , CreateState(..)
    , CreatedModel
    , ExpiryChoice(..)
    , FormModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , modalView
    , update
    , view
    )

import Api.Client as Client
import Data.ApiKey exposing (CreatableScope(..), CreateRequest, CreatedApiKey)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Region as Region
import Html
import Html.Attributes
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Common exposing (uiClass)
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Typography as Typography



-- MODEL


type Model
    = Form FormModel
    | Created CreatedModel


type alias FormModel =
    { nextRequestId : Int
    , form : CreateForm
    }


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
    | NameInvalid


type alias CreatedModel =
    { created : CreatedApiKey
    , copyState : CopyState
    , nextRequestId : Int
    }


type CopyState
    = CopyIdle
    | CopyPending Int
    | CopySucceeded
    | CopyFailed


type OutMsg
    = NoOp
    | RequestCreate Int CreateRequest
    | CopyText Int String
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Form { nextRequestId = 1, form = emptyForm }, NoOp )


emptyForm : CreateForm
emptyForm =
    { name = ""
    , scope = CreatableRead
    , expiry = ExpireInDays 90
    , expiryOpen = False
    , state = Editing
    }



-- UPDATE


type Msg
    = NameChanged String
    | ScopeChanged CreatableScope
    | ExpiryChanged ExpiryChoice
    | ExpiryToggled
    | Submitted
    | CreateCompleted Int (Result Client.ApiError CreatedApiKey)
    | CopyClicked
    | CopyCompleted Int Bool
    | DoneClicked


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NameChanged name ->
            updateForm (\form -> { form | name = name, state = Editing }) model

        ScopeChanged scope ->
            updateForm (\form -> { form | scope = scope, state = Editing }) model

        ExpiryChanged expiry ->
            updateForm (\form -> { form | expiry = expiry, expiryOpen = False, state = Editing })
                model

        ExpiryToggled ->
            updateForm (\form -> { form | expiryOpen = not form.expiryOpen }) model

        Submitted ->
            case model of
                Form formModel ->
                    let
                        form : CreateForm
                        form =
                            formModel.form
                    in
                    case form.state of
                        Submitting _ ->
                            ( model, Cmd.none, NoOp )

                        _ ->
                            case validateForm form of
                                Ok request ->
                                    let
                                        requestId : Int
                                        requestId =
                                            formModel.nextRequestId
                                    in
                                    ( Form
                                        { nextRequestId = requestId + 1
                                        , form =
                                            { form
                                                | name = request.name
                                                , state = Submitting requestId
                                            }
                                        }
                                    , Cmd.none
                                    , RequestCreate requestId request
                                    )

                                Err error ->
                                    ( Form { formModel | form = { form | state = Invalid error } }
                                    , Cmd.none
                                    , NoOp
                                    )

                Created _ ->
                    ( model, Cmd.none, NoOp )

        CreateCompleted requestId result ->
            case model of
                Form formModel ->
                    case formModel.form.state of
                        Submitting pendingRequestId ->
                            if pendingRequestId /= requestId then
                                ( model, Cmd.none, NoOp )

                            else
                                case result of
                                    Ok created ->
                                        ( Created
                                            { created = created
                                            , copyState = CopyIdle
                                            , nextRequestId = formModel.nextRequestId
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

                        _ ->
                            ( model, Cmd.none, NoOp )

                Created _ ->
                    ( model, Cmd.none, NoOp )

        CopyClicked ->
            case model of
                Created createdModel ->
                    case createdModel.copyState of
                        CopyPending _ ->
                            ( model, Cmd.none, NoOp )

                        _ ->
                            let
                                copyId : Int
                                copyId =
                                    createdModel.nextRequestId
                            in
                            ( Created
                                { createdModel
                                    | copyState = CopyPending copyId
                                    , nextRequestId = copyId + 1
                                }
                            , Cmd.none
                            , CopyText copyId createdModel.created.token
                            )

                Form _ ->
                    ( model, Cmd.none, NoOp )

        CopyCompleted copyId succeeded ->
            case model of
                Created createdModel ->
                    case createdModel.copyState of
                        CopyPending pendingCopyId ->
                            if pendingCopyId == copyId then
                                ( Created
                                    { createdModel
                                        | copyState =
                                            if succeeded then
                                                CopySucceeded

                                            else
                                                CopyFailed
                                    }
                                , Cmd.none
                                , NoOp
                                )

                            else
                                ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, NoOp )

                Form _ ->
                    ( model, Cmd.none, NoOp )

        DoneClicked ->
            case model of
                Created createdModel ->
                    case createdModel.copyState of
                        CopyPending _ ->
                            ( model, Cmd.none, NoOp )

                        _ ->
                            ( model, Cmd.none, Navigate SettingsApiKeys )

                Form _ ->
                    ( model, Cmd.none, NoOp )


updateForm :
    (CreateForm -> CreateForm)
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
updateForm transform model =
    case model of
        Form formModel ->
            if isSubmitting formModel.form.state then
                ( model, Cmd.none, NoOp )

            else
                ( Form { formModel | form = transform formModel.form }
                , Cmd.none
                , NoOp
                )

        Created _ ->
            ( model, Cmd.none, NoOp )


isSubmitting : CreateState -> Bool
isSubmitting state =
    case state of
        Submitting _ ->
            True

        _ ->
            False


applyCreateFailure : Int -> String -> Model -> Model
applyCreateFailure requestId message model =
    case model of
        Form formModel ->
            let
                form : CreateForm
                form =
                    formModel.form
            in
            case form.state of
                Submitting pendingRequestId ->
                    if pendingRequestId == requestId then
                        Form { formModel | form = { form | state = Failed message } }

                    else
                        model

                _ ->
                    model

        Created _ ->
            model


validateForm : CreateForm -> Result CreateError CreateRequest
validateForm form =
    let
        name : String
        name =
            trimName form.name

        characters : List Char
        characters =
            String.toList name
    in
    if String.isEmpty name then
        Err NameRequired

    else if nameLength name > 64 then
        Err NameTooLong

    else if List.any isForbiddenNameChar characters then
        Err NameInvalid

    else if not (List.any isVisibleNameChar characters) then
        Err NameInvalid

    else
        Ok { name = name, scope = form.scope, expiresInDays = expiresInDays form.expiry }


nameLength : String -> Int
nameLength name =
    String.foldl (\_ count -> count + 1) 0 name


{-| Matches `ApiKeyName::new` in `backend/src/auth/domain.rs`, which trims with
Rust `str::trim`. JavaScript `String.trim` is not equivalent: it strips U+FEFF
but leaves U+0085, while Rust `char::is_whitespace` does the reverse. Trim by
code point through the same predicate the rest of validation uses.
-}
trimName : String -> String
trimName name =
    name
        |> String.toList
        |> dropLeadingWhitespace
        |> List.reverse
        |> dropLeadingWhitespace
        |> List.reverse
        |> String.fromList


dropLeadingWhitespace : List Char -> List Char
dropLeadingWhitespace chars =
    case chars of
        first :: rest ->
            if isWhitespaceNameCode (Char.toCode first) then
                dropLeadingWhitespace rest

            else
                chars

        [] ->
            []


isForbiddenNameChar : Char -> Bool
isForbiddenNameChar char =
    let
        code : Int
        code =
            Char.toCode char
    in
    isControlNameCode code
        || List.member code forbiddenNameCodes
        || (code >= 0x202A && code <= 0x202E)
        || (code >= 0x2060 && code <= 0x206F)
        || (code >= 0xFFF9 && code <= 0xFFFB)


forbiddenNameCodes : List Int
forbiddenNameCodes =
    [ 0xAD
    , 0x061C
    , 0x180E
    , 0x200B
    , 0x200E
    , 0x200F
    , 0x2028
    , 0x2029
    , 0xFEFF
    ]


isVisibleNameChar : Char -> Bool
isVisibleNameChar char =
    let
        code : Int
        code =
            Char.toCode char
    in
    not (isWhitespaceNameCode code)
        && not (isControlNameCode code)
        && not (List.member code [ 0x200C, 0x200D ])


isWhitespaceNameCode : Int -> Bool
isWhitespaceNameCode code =
    (code >= 0x09 && code <= 0x0D)
        || List.member code
            [ 0x20
            , 0x85
            , 0xA0
            , 0x1680
            , 0x2028
            , 0x2029
            , 0x202F
            , 0x205F
            , 0x3000
            ]
        || (code >= 0x2000 && code <= 0x200A)


isControlNameCode : Int -> Bool
isControlNameCode code =
    code <= 0x1F || (code >= 0x7F && code <= 0x9F)


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
    case model of
        Form formModel ->
            formView env formModel.form

        Created _ ->
            Element.none


modalView : Env -> Model -> Maybe (Element Msg)
modalView env model =
    case model of
        Form formModel ->
            if isSubmitting formModel.form.state then
                Just (submittingModal env)

            else
                Nothing

        Created createdModel ->
            Just (createdModal env createdModel)


submittingModal : Env -> Element Msg
submittingModal env =
    Feedback.blockingOverlay env.theme
        { title = I18n.t env.language TidApiKeysCreateTitle
        , body =
            [ Typography.mutedBodyParagraph env.theme (I18n.t env.language TidCommonCreating)
            ]
        }


formView : Env -> CreateForm -> Element Msg
formView env form =
    let
        submitting : Bool
        submitting =
            isSubmitting form.state
    in
    UiPage.pageContainer
        (errorView env form.state
            ++ [ Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidApiKeysCreateDescription)
               , Surface.formSection env.theme
                    (I18n.t env.language TidApiKeysDetails)
                    [ nameField env submitting form.name
                    , scopeField env submitting form.scope
                    , UiInput.selectDropdownWithState env.device
                        env.theme
                        env.language
                        { label = I18n.t env.language TidApiKeysExpiry
                        , selected = form.expiry
                        , options = expiryOptions env.language
                        , onChange = ExpiryChanged
                        , isOpen = form.expiryOpen
                        , onToggle = ExpiryToggled
                        , disabled = submitting
                        }
                    ]
               , Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysCreate
                    , onPress = Submitted
                    , submitState = Just (Button.submittingOrIdle submitting)
                    , submittingLabel = Just (I18n.t env.language TidCommonCreating)
                    , trailing = Nothing
                    }
               ]
        )


nameField : Env -> Bool -> String -> Element Msg
nameField env disabled value =
    let
        config : UiInput.InputConfig Msg
        config =
            { label = I18n.t env.language TidApiKeysName
            , value = value
            , onChange = NameChanged
            }
    in
    if disabled then
        UiInput.disabledInput env.theme config

    else
        UiInput.input env.theme config


scopeField : Env -> Bool -> CreatableScope -> Element Msg
scopeField env disabled selected =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ UiInput.fieldLabel env.theme (I18n.t env.language TidApiKeysScope)
        , scopeOption env disabled selected CreatableRead
        , scopeOption env disabled selected CreatableReadWrite
        ]


scopeOption : Env -> Bool -> CreatableScope -> CreatableScope -> Element Msg
scopeOption env disabled selected scope =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
        [ UiInput.optionRowWithState env.theme
            { label = creatableScopeLabel env.language scope
            , trailing = Nothing
            , selected = selected == scope
            , onPress = ScopeChanged scope
            , disabled = disabled
            }
        , Typography.mutedCaption env.theme (creatableScopeDescription env.language scope)
        ]


creatableScopeLabel : Language -> CreatableScope -> String
creatableScopeLabel language scope =
    case scope of
        CreatableRead ->
            I18n.t language TidApiKeysScopeRead

        CreatableReadWrite ->
            I18n.t language TidApiKeysScopeReadWrite


creatableScopeDescription : Language -> CreatableScope -> String
creatableScopeDescription language scope =
    case scope of
        CreatableRead ->
            I18n.t language TidApiKeysScopeReadDescription

        CreatableReadWrite ->
            I18n.t language TidApiKeysScopeReadWriteDescription


expiryOptions : Language -> List ( ExpiryChoice, String )
expiryOptions language =
    [ ( ExpireInDays 30, I18n.t language TidApiKeysExpiry30Days )
    , ( ExpireInDays 90, I18n.t language TidApiKeysExpiry90Days )
    , ( ExpireInDays 365, I18n.t language TidApiKeysExpiry365Days )
    , ( NeverExpires, I18n.t language TidApiKeysExpiryNever )
    ]


errorView : Env -> CreateState -> List (Element Msg)
errorView env state =
    case state of
        Invalid error ->
            [ errorAlert env (errorMessage env.language error) ]

        Failed message ->
            [ errorAlert env message ]

        Editing ->
            []

        Submitting _ ->
            []


errorAlert : Env -> String -> Element Msg
errorAlert env message =
    Element.el
        [ Element.width Element.fill
        , Element.htmlAttribute (Html.Attributes.attribute "role" "alert")
        ]
        (Feedback.errorBanner env.theme message)


errorMessage : Language -> CreateError -> String
errorMessage language error =
    case error of
        NameRequired ->
            I18n.t language TidApiKeysNameRequired

        NameTooLong ->
            I18n.t language TidApiKeysNameTooLong

        NameInvalid ->
            I18n.t language TidApiKeysNameInvalid


createdModal : Env -> CreatedModel -> Element Msg
createdModal env createdModel =
    let
        copyInFlight : Bool
        copyInFlight =
            isCopyPending createdModel.copyState
    in
    Feedback.modalOverlay env.theme
        { title = I18n.t env.language TidApiKeysCreatedTitle
        , body =
            [ Feedback.warningBanner env.theme (I18n.t env.language TidApiKeysCreatedWarning)
            , secretBox env createdModel.created.token
            , copyFeedback env createdModel.copyState
            , Typography.mutedBodyParagraph env.theme (I18n.t env.language TidApiKeysUsage)
            , codeBox env (I18n.t env.language TidApiKeysUsageExample)
            ]
        , actions =
            Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ actionButton env
                    [ Region.description (I18n.t env.language TidApiKeysCopyAria)
                    , Element.htmlAttribute
                        (Html.Attributes.title
                            (I18n.t env.language TidApiKeysCopyAria)
                        )
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
                , actionButton env
                    []
                    { tone = Button.PrimaryOutline
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidApiKeysDone
                    , onPress = DoneClicked
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
            Element.el [ Element.htmlAttribute (Html.Attributes.attribute "role" "status") ]
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
                , Html.Attributes.autofocus True
                , Html.Attributes.class "ui-secret-token"
                , Html.Attributes.attribute "spellcheck" "false"
                , Html.Attributes.attribute "aria-label" (I18n.t env.language TidApiKeysSecretLabel)
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
            , uiClass "ui-text-wrap"
            ]
            [ Element.text code ]
        )


actionButton :
    Env
    -> List (Element.Attribute Msg)
    -> Button.ButtonConfig Msg
    -> Element Msg
actionButton env attributes config =
    Element.el [ Element.width Element.fill ]
        (Button.textButtonWithAttributes env.device env.theme attributes config)
