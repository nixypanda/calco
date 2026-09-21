module Component.FoodAssistant exposing
    ( ChatModel
    , DraftPreviewData
    , DraftResult
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , PhotoMetadata
    , RequestState(..)
    , draftPreviewData
    , init
    , modalView
    , previewUrls
    , removeAt
    , update
    , updateFor
    , validatePhotoMetadata
    , view
    , viewFor
    )

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant
    exposing
        ( AssistantStatus
        , Conversation
        , ConversationRole(..)
        , ConversationTurn
        , FoodDraft
        , FoodDraftPurpose(..)
        , FoodDraftTurn(..)
        , SuggestedLog
        )
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import File exposing (File)
import File.Select
import Html
import Html.Attributes as HtmlAttributes
import Html.Events as HtmlEvents
import I18n
import Json.Decode as Decode
import Task
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients as Nutrients


type Model
    = LoadingStatus
    | Disabled
    | StatusFailed
    | Enabled ChatModel


type alias ChatModel =
    { transcript : List ConversationTurn
    , description : String
    , request : RequestState
    , draft : Maybe FoodDraft
    , suggestedLog : Maybe SuggestedLog
    , warnings : List String
    , askingForChanges : Bool
    , awaitingOverwriteConfirmation : Bool
    , awaitingNewSessionConfirmation : Bool
    , supportsImages : Bool
    , photos : List File
    , photoUrls : List (Maybe String)
    , photoError : Maybe String
    }


type alias PhotoMetadata =
    { mimeType : String
    , size : Int
    }


type alias DraftPreviewData =
    { details : List ( String, String )
    , nutrients : List ( String, String )
    , servings : List ( String, String )
    }


type alias DraftResult =
    { draft : FoodDraft
    , suggestedLog : SuggestedLog
    , warnings : List String
    }


type RequestState
    = Ready
    | Sending
    | InputFailed String
    | RequestFailed String


type Msg
    = StatusLoaded (Result Client.ApiError AssistantStatus)
    | RetryStatusClicked
    | DescriptionChanged String
    | TakePhotoSelected File
    | ChoosePhotos
    | PhotosSelected File (List File)
    | PhotoPreviewLoaded Int String
    | RemovePhoto Int
    | SendClicked
    | DraftCompleted (Result Client.ApiError FoodDraftTurn)
    | RetryClicked
    | NewSessionClicked
    | ConfirmNewSessionClicked
    | CancelNewSessionClicked
    | AskForChangesClicked
    | CancelChangesClicked
    | ApplyDraftClicked Bool
    | ConfirmOverwriteClicked
    | CancelOverwriteClicked


type OutMsg
    = NoOutMsg
    | RequestStatus
    | RequestDraft FoodDraftPurpose Conversation (List File)
    | RevokePhotoPreviewUrls (List String)
    | ApplyDraft FoodDraft
    | CompleteDraft DraftResult
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( LoadingStatus, RequestStatus )


previewUrls : Model -> List String
previewUrls model =
    case model of
        Enabled chat ->
            List.filterMap identity chat.photoUrls

        _ ->
            []


emptyChat : ChatModel
emptyChat =
    { transcript = []
    , description = ""
    , request = Ready
    , draft = Nothing
    , suggestedLog = Nothing
    , warnings = []
    , askingForChanges = False
    , awaitingOverwriteConfirmation = False
    , awaitingNewSessionConfirmation = False
    , supportsImages = False
    , photos = []
    , photoUrls = []
    , photoError = Nothing
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update =
    updateFor CustomFood


updateFor : FoodDraftPurpose -> Msg -> Model -> ( Model, Cmd Msg, OutMsg )
updateFor purpose msg model =
    case msg of
        StatusLoaded result ->
            case result of
                Ok status ->
                    if status.enabled then
                        ( Enabled { emptyChat | supportsImages = status.supportsImages }
                        , Cmd.none
                        , NoOutMsg
                        )

                    else
                        ( Disabled, Cmd.none, NoOutMsg )

                Err error ->
                    ( StatusFailed
                    , Cmd.none
                    , sessionOutMsg error
                    )

        RetryStatusClicked ->
            ( LoadingStatus, Cmd.none, RequestStatus )

        DescriptionChanged description ->
            updateChat
                (\chat -> ( { chat | description = description }, NoOutMsg ))
                model

        TakePhotoSelected photo ->
            addSelectedPhotos [ photo ] model

        ChoosePhotos ->
            case model of
                Enabled chat ->
                    if canAddPhotos chat then
                        ( model
                        , File.Select.files [ "image/*" ] PhotosSelected
                        , NoOutMsg
                        )

                    else
                        ( model, Cmd.none, NoOutMsg )

                _ ->
                    ( model, Cmd.none, NoOutMsg )

        PhotosSelected first rest ->
            addSelectedPhotos (first :: rest) model

        PhotoPreviewLoaded index url ->
            updateChat
                (\chat ->
                    ( { chat | photoUrls = setAt index (Just url) chat.photoUrls }
                    , NoOutMsg
                    )
                )
                model

        RemovePhoto index ->
            updateChat
                (\chat ->
                    ( { chat
                        | photos = removeAt index chat.photos
                        , photoUrls = removeAt index chat.photoUrls
                        , photoError = Nothing
                      }
                    , valueAt index chat.photoUrls
                        |> Maybe.andThen identity
                        |> Maybe.map (List.singleton >> RevokePhotoPreviewUrls)
                        |> Maybe.withDefault NoOutMsg
                    )
                )
                model

        SendClicked ->
            updateChat (sendDescription purpose) model

        DraftCompleted result ->
            case result of
                Ok turn ->
                    updateChat (completeDraft turn) model

                Err error ->
                    updateChat
                        (\chat ->
                            ( { chat | request = RequestFailed (draftErrorMessage error) }
                            , sessionOutMsg error
                            )
                        )
                        model

        RetryClicked ->
            updateChat (retryDraft purpose) model

        NewSessionClicked ->
            updateChat requestNewSession model

        ConfirmNewSessionClicked ->
            updateChat confirmNewSession model

        CancelNewSessionClicked ->
            updateChat
                (\chat ->
                    ( { chat | awaitingNewSessionConfirmation = False }
                    , NoOutMsg
                    )
                )
                model

        AskForChangesClicked ->
            updateChat askForChanges model

        CancelChangesClicked ->
            updateChat
                (\chat -> ( { chat | askingForChanges = False }, NoOutMsg ))
                model

        ApplyDraftClicked formHasManualInput ->
            updateChat (requestApply purpose formHasManualInput) model

        ConfirmOverwriteClicked ->
            updateChat confirmOverwrite model

        CancelOverwriteClicked ->
            updateChat
                (\chat ->
                    ( { chat | awaitingOverwriteConfirmation = False }
                    , NoOutMsg
                    )
                )
                model


updateChat :
    (ChatModel -> ( ChatModel, OutMsg ))
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
updateChat transform model =
    case model of
        Enabled chat ->
            let
                ( next, outMsg ) =
                    transform chat
            in
            ( Enabled next, Cmd.none, outMsg )

        _ ->
            ( model, Cmd.none, NoOutMsg )


sendDescription : FoodDraftPurpose -> ChatModel -> ( ChatModel, OutMsg )
sendDescription purpose chat =
    if chat.request == Sending then
        ( chat, NoOutMsg )

    else
        case FoodAssistant.userTurn chat.description of
            Err message ->
                ( { chat | request = InputFailed message }, NoOutMsg )

            Ok turn ->
                sendTranscript purpose (chat.transcript ++ [ turn ]) chat


sendTranscript : FoodDraftPurpose -> List ConversationTurn -> ChatModel -> ( ChatModel, OutMsg )
sendTranscript purpose transcript chat =
    case FoodAssistant.conversation transcript of
        Err message ->
            ( { chat | request = InputFailed message }, NoOutMsg )

        Ok boundedConversation ->
            ( { chat
                | transcript = transcript
                , description = ""
                , request = Sending
                , draft = Nothing
                , suggestedLog = Nothing
                , warnings = []
                , awaitingOverwriteConfirmation = False
                , awaitingNewSessionConfirmation = False
              }
            , RequestDraft purpose boundedConversation chat.photos
            )


completeDraft : FoodDraftTurn -> ChatModel -> ( ChatModel, OutMsg )
completeDraft turn chat =
    let
        transcript : List ConversationTurn
        transcript =
            case FoodAssistant.assistantTurn (FoodAssistant.assistantMessage turn) of
                Ok assistantResponse ->
                    chat.transcript ++ [ assistantResponse ]

                Err _ ->
                    chat.transcript
    in
    case turn of
        NeedsClarification _ ->
            ( { chat
                | transcript = transcript
                , request = Ready
                , draft = Nothing
                , suggestedLog = Nothing
                , warnings = []
                , awaitingOverwriteConfirmation = False
              }
            , NoOutMsg
            )

        DraftReady readyDraft ->
            ( { chat
                | transcript = transcript
                , request = Ready
                , draft = Just readyDraft.draft
                , suggestedLog = readyDraft.suggestedLog
                , warnings = readyDraft.warnings
                , askingForChanges = False
                , awaitingOverwriteConfirmation = False
                , photos = []
                , photoUrls = []
                , photoError = Nothing
              }
            , revokePreviewUrls chat
            )


retryDraft : FoodDraftPurpose -> ChatModel -> ( ChatModel, OutMsg )
retryDraft purpose chat =
    case ( chat.request, FoodAssistant.conversation chat.transcript ) of
        ( RequestFailed _, Ok boundedConversation ) ->
            ( { chat
                | request = Sending
                , awaitingNewSessionConfirmation = False
              }
            , RequestDraft purpose boundedConversation chat.photos
            )

        _ ->
            ( chat, NoOutMsg )


requestNewSession : ChatModel -> ( ChatModel, OutMsg )
requestNewSession chat =
    if chat.request == Sending || not (hasSession chat) then
        ( chat, NoOutMsg )

    else
        ( { chat | awaitingNewSessionConfirmation = True }, NoOutMsg )


newSession : ChatModel -> ( ChatModel, OutMsg )
newSession chat =
    ( { emptyChat
        | supportsImages = chat.supportsImages
      }
    , revokePreviewUrls chat
    )


confirmNewSession : ChatModel -> ( ChatModel, OutMsg )
confirmNewSession chat =
    if chat.awaitingNewSessionConfirmation && chat.request /= Sending then
        newSession chat

    else
        ( chat, NoOutMsg )


askForChanges : ChatModel -> ( ChatModel, OutMsg )
askForChanges chat =
    case chat.draft of
        Just _ ->
            ( { chat | askingForChanges = True }, NoOutMsg )

        Nothing ->
            ( chat, NoOutMsg )


hasSession : ChatModel -> Bool
hasSession chat =
    not (List.isEmpty chat.transcript)
        || chat.draft
        /= Nothing
        || not (List.isEmpty chat.photos)


requestApply : FoodDraftPurpose -> Bool -> ChatModel -> ( ChatModel, OutMsg )
requestApply purpose formHasManualInput chat =
    case chat.draft of
        Nothing ->
            ( chat, NoOutMsg )

        Just draft ->
            if purpose == AdHocLog then
                case chat.suggestedLog of
                    Just suggestedLog ->
                        ( chat
                        , CompleteDraft
                            { draft = draft
                            , suggestedLog = suggestedLog
                            , warnings = chat.warnings
                            }
                        )

                    Nothing ->
                        ( chat, NoOutMsg )

            else if formHasManualInput then
                ( { chat | awaitingOverwriteConfirmation = True }, NoOutMsg )

            else
                ( chat, ApplyDraft draft )


confirmOverwrite : ChatModel -> ( ChatModel, OutMsg )
confirmOverwrite chat =
    case ( chat.awaitingOverwriteConfirmation, chat.draft ) of
        ( True, Just draft ) ->
            ( { chat | awaitingOverwriteConfirmation = False }, ApplyDraft draft )

        _ ->
            ( { chat | awaitingOverwriteConfirmation = False }, NoOutMsg )


sessionOutMsg : Client.ApiError -> OutMsg
sessionOutMsg error =
    if Client.isUnauthorized error then
        SessionExpired

    else
        NoOutMsg


draftErrorMessage : Client.ApiError -> String
draftErrorMessage error =
    case error of
        Client.RateLimited maybeSeconds ->
            case maybeSeconds of
                Just seconds ->
                    I18n.en (TidAssistantRateLimitedRetry (String.fromInt seconds))

                Nothing ->
                    I18n.en TidAssistantBusy

        Client.Timeout ->
            I18n.en TidAssistantTimeout

        Client.NetworkError ->
            I18n.en TidAssistantNetworkError

        Client.BadStatus 401 _ _ ->
            I18n.en TidAssistantSessionExpired

        Client.BadStatus _ _ message ->
            message

        _ ->
            I18n.en TidAssistantDraftFailed


addSelectedPhotos : List File -> Model -> ( Model, Cmd Msg, OutMsg )
addSelectedPhotos files model =
    case model of
        Enabled chat ->
            if not (canAddPhotos chat) then
                ( model, Cmd.none, NoOutMsg )

            else
                case
                    validatePhotoMetadata
                        (List.map photoMetadata chat.photos)
                        (List.map photoMetadata files)
                of
                    Err message ->
                        ( Enabled { chat | photoError = Just message }
                        , Cmd.none
                        , NoOutMsg
                        )

                    Ok () ->
                        let
                            firstIndex : Int
                            firstIndex =
                                List.length chat.photos

                            previewCommands : List (Cmd Msg)
                            previewCommands =
                                files
                                    |> List.indexedMap
                                        (\index photo ->
                                            File.toUrl photo
                                                |> Task.perform
                                                    (PhotoPreviewLoaded (firstIndex + index))
                                        )
                        in
                        ( Enabled
                            { chat
                                | photos = chat.photos ++ files
                                , photoUrls =
                                    chat.photoUrls
                                        ++ List.repeat (List.length files) Nothing
                                , photoError = Nothing
                            }
                        , Cmd.batch previewCommands
                        , NoOutMsg
                        )

        _ ->
            ( model, Cmd.none, NoOutMsg )


canAddPhotos : ChatModel -> Bool
canAddPhotos chat =
    chat.supportsImages
        && chat.request
        /= Sending
        && List.length chat.photos
        < maxPhotoCount


photoMetadata : File -> PhotoMetadata
photoMetadata photo =
    { mimeType = File.mime photo
    , size = File.size photo
    }


validatePhotoMetadata : List PhotoMetadata -> List PhotoMetadata -> Result String ()
validatePhotoMetadata existingPhotos selectedPhotos =
    let
        photos : List PhotoMetadata
        photos =
            existingPhotos ++ selectedPhotos
    in
    if List.length photos > maxPhotoCount then
        Err (I18n.en TidAssistantPhotoLimit)

    else if List.any (not << supportedPhotoMime << .mimeType) photos then
        Err (I18n.en TidAssistantPhotoTypes)

    else if List.any (\photo -> photo.size > maxPhotoBytes) photos then
        Err (I18n.en TidAssistantPhotoTooLarge)

    else if List.sum (List.map .size photos) > maxTotalPhotoBytes then
        Err (I18n.en TidAssistantPhotosTotalTooLarge)

    else
        Ok ()


supportedPhotoMime : String -> Bool
supportedPhotoMime mimeType =
    List.member mimeType [ "image/jpeg", "image/png", "image/webp" ]


maxPhotoCount : Int
maxPhotoCount =
    4


maxPhotoBytes : Int
maxPhotoBytes =
    15 * 1024 * 1024


maxTotalPhotoBytes : Int
maxTotalPhotoBytes =
    40 * 1024 * 1024


revokePreviewUrls : ChatModel -> OutMsg
revokePreviewUrls chat =
    case List.filterMap identity chat.photoUrls of
        [] ->
            NoOutMsg

        urls ->
            RevokePhotoPreviewUrls urls


removeAt : Int -> List a -> List a
removeAt index values =
    values
        |> List.indexedMap Tuple.pair
        |> List.filter (\( current, _ ) -> current /= index)
        |> List.map Tuple.second


setAt : Int -> a -> List a -> List a
setAt index value values =
    values
        |> List.indexedMap
            (\current original ->
                if current == index then
                    value

                else
                    original
            )


valueAt : Int -> List a -> Maybe a
valueAt index values =
    values
        |> List.drop index
        |> List.head


view : Theme -> Language -> Device -> Bool -> Model -> Element Msg
view =
    viewFor CustomFood


viewFor : FoodDraftPurpose -> Theme -> Language -> Device -> Bool -> Model -> Element Msg
viewFor purpose theme language device formHasManualInput model =
    case model of
        LoadingStatus ->
            Surface.card theme
                [ Skeleton.barCustom theme
                    { width = Element.fillPortion 1, height = 16 }
                , Skeleton.bar theme
                , Skeleton.bar theme
                , Skeleton.input theme
                , Skeleton.button theme
                ]

        Disabled ->
            Surface.section theme
                { header =
                    Just (Typography.subsectionTitle theme (I18n.t language TidTitleCreateWithAi))
                , body =
                    [ Typography.mutedParagraph theme
                        (I18n.t language TidAssistantUnavailable)
                    ]
                , footer = Nothing
                }

        StatusFailed ->
            Surface.section theme
                { header =
                    Just (Typography.subsectionTitle theme (I18n.t language TidTitleCreateWithAi))
                , body =
                    [ Feedback.errorBanner theme
                        (I18n.t language TidAssistantStatusCheckFailed)
                    ]
                , footer =
                    Just
                        (Button.textButton device
                            theme
                            { tone = Button.Ghost
                            , width = Button.FullWidth
                            , label = I18n.t language TidAssistantRetryStatusCheck
                            , onPress = RetryStatusClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        )
                }

        Enabled chat ->
            enabledView purpose theme language device formHasManualInput chat


enabledView : FoodDraftPurpose -> Theme -> Language -> Device -> Bool -> ChatModel -> Element Msg
enabledView purpose theme language device formHasManualInput chat =
    Surface.card theme (expandedContent purpose theme language device formHasManualInput chat)


expandedContent :
    FoodDraftPurpose
    -> Theme
    -> Language
    -> Device
    -> Bool
    -> ChatModel
    -> List (Element Msg)
expandedContent purpose theme language device formHasManualInput chat =
    case chat.draft of
        Just _ ->
            [ draftPreviewView purpose theme language device formHasManualInput chat
            , warningView theme language chat.warnings
            , requestErrorView theme language device chat.request
            ]
                ++ (if chat.askingForChanges then
                        [ conversationView theme language device chat
                        , descriptionInput theme language chat
                        , photoPicker theme language device chat
                        , sendButton purpose theme language device chat.request
                        ]

                    else
                        []
                   )

        Nothing ->
            [ conversationView theme language device chat
            , warningView theme language chat.warnings
            , requestErrorView theme language device chat.request
            , descriptionInput theme language chat
            , photoPicker theme language device chat
            , sendButton purpose theme language device chat.request
            ]


conversationView : Theme -> Language -> Device -> ChatModel -> Element Msg
conversationView theme language device chat =
    if not (hasSession chat) then
        Element.none

    else
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ Element.row [ Element.width Element.fill ]
                [ Element.el [ Font.bold ] (Element.text (I18n.t language TidAssistantConversation))
                , if chat.request == Sending || chat.draft /= Nothing then
                    Element.none

                  else
                    Element.el [ Element.alignRight ]
                        (Button.textButton device
                            theme
                            { tone = Button.Primary
                            , width = Button.ContentWidth
                            , label = I18n.t language TidAssistantNewSession
                            , onPress = NewSessionClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        )
                ]
            , Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                (List.map (turnView theme language) chat.transcript)
            ]


modalView : Theme -> Language -> Device -> Model -> Maybe (Element Msg)
modalView theme language device model =
    case model of
        Enabled chat ->
            if chat.awaitingNewSessionConfirmation && chat.request /= Sending then
                Just
                    (Feedback.modalOverlay theme
                        { title = I18n.t language TidAssistantStartNewSessionTitle
                        , body =
                            [ Typography.mutedParagraph theme
                                (I18n.t language TidAssistantStartNewSessionBody)
                            ]
                        , actions =
                            Button.bottomActionButtons device
                                theme
                                [ { label = I18n.t language TidCommonCancel
                                  , onPress = CancelNewSessionClicked
                                  , tone = Button.Primary
                                  }
                                , { label = I18n.t language TidAssistantStartNewSession
                                  , onPress = ConfirmNewSessionClicked
                                  , tone = Button.Danger
                                  }
                                ]
                        , onBackgroundPress = Just CancelNewSessionClicked
                        }
                    )

            else
                Nothing

        _ ->
            Nothing


turnView : Theme -> Language -> ConversationTurn -> Element Msg
turnView theme language turn =
    Element.column
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        , Border.rounded DesignTokens.radiusControl
        , Background.color theme.inputFill
        , Element.spacing DesignTokens.space4
        ]
        [ Element.el [ Font.bold ]
            (Element.text
                (case FoodAssistant.turnRole turn of
                    User ->
                        I18n.t language TidAssistantRoleUser

                    Assistant ->
                        I18n.t language TidAssistantRoleAssistant
                )
            )
        , Element.paragraph [ Element.width Element.fill ]
            [ Element.text (FoodAssistant.turnText turn) ]
        ]


descriptionInput : Theme -> Language -> ChatModel -> Element Msg
descriptionInput theme language chat =
    Input.multiline
        [ Element.width Element.fill
        , Element.height (Element.px 120)
        , Border.rounded DesignTokens.radiusControl
        , Background.color theme.cardBg
        , Element.padding DesignTokens.space12
        ]
        { onChange = DescriptionChanged
        , text = chat.description
        , placeholder =
            Just
                (Input.placeholder []
                    (Element.text
                        (if chat.draft == Nothing then
                            I18n.t language TidAssistantDescriptionPlaceholder

                         else
                            I18n.t language TidAssistantChangesPlaceholder
                        )
                    )
                )
        , label =
            Input.labelAbove []
                (UiInput.fieldLabel theme
                    (if chat.draft == Nothing then
                        I18n.t language TidAssistantDescriptionLabel

                     else
                        I18n.t language TidAssistantChangesLabel
                    )
                )
        , spellcheck = True
        }


photoPicker : Theme -> Language -> Device -> ChatModel -> Element Msg
photoPicker theme language device chat =
    if not chat.supportsImages then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            ([ Element.el [ Font.bold ] (Element.text (I18n.t language TidAssistantPhotosOptional))
             , photoActionView theme language device chat
             ]
                ++ photoErrorView theme chat.photoError
                ++ List.indexedMap
                    (\index photo ->
                        photoPreview
                            theme
                            language
                            device
                            index
                            photo
                            (valueAt index chat.photoUrls
                                |> Maybe.andThen identity
                            )
                    )
                    chat.photos
            )


photoActionView : Theme -> Language -> Device -> ChatModel -> Element Msg
photoActionView theme language device chat =
    if List.length chat.photos >= maxPhotoCount then
        Typography.mutedParagraph theme (I18n.t language TidAssistantPhotosMax)

    else
        Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ Element.el [ Element.width Element.fill ] (cameraInput language chat)
                , Element.el [ Element.width Element.fill ]
                    (choosePhotosButton theme language device chat)
                ]
            ]


choosePhotosButton : Theme -> Language -> Device -> ChatModel -> Element Msg
choosePhotosButton theme language device chat =
    let
        label : String
        label =
            if List.isEmpty chat.photos then
                I18n.t language TidAssistantChoosePhotos

            else
                I18n.t language TidAssistantChooseMorePhotos
    in
    Button.textButton device
        theme
        { tone = Button.PrimaryOutline
        , width = Button.FullWidth
        , label = label
        , onPress = ChoosePhotos
        , submitState =
            Just
                (if chat.request == Sending then
                    Button.Disabled

                 else
                    Button.Idle
                )
        , submittingLabel = Just label
        , trailing = Nothing
        }


cameraInput : Language -> ChatModel -> Element Msg
cameraInput language chat =
    Element.html <|
        Html.label
            [ HtmlAttributes.classList
                [ ( "photo-capture-label", True )
                , ( "photo-capture-label--disabled", not (canAddPhotos chat) )
                ]
            ]
            [ Html.span [] [ Html.text (I18n.t language TidAssistantTakePhoto) ]
            , Html.input
                [ HtmlAttributes.type_ "file"
                , HtmlAttributes.accept "image/*"
                , HtmlAttributes.attribute "capture" "environment"
                , HtmlAttributes.attribute "aria-label"
                    (I18n.t language TidAssistantTakePhotoAria)
                , HtmlAttributes.disabled (not (canAddPhotos chat))
                , HtmlEvents.on "change" cameraFileDecoder
                , HtmlAttributes.value ""
                ]
                []
            ]


cameraFileDecoder : Decode.Decoder Msg
cameraFileDecoder =
    Decode.at [ "target", "files", "0" ] File.decoder
        |> Decode.map TakePhotoSelected


photoErrorView : Theme -> Maybe String -> List (Element Msg)
photoErrorView theme maybeError =
    case maybeError of
        Just message ->
            [ Feedback.errorBanner theme message ]

        Nothing ->
            []


photoPreview : Theme -> Language -> Device -> Int -> File -> Maybe String -> Element Msg
photoPreview theme language device index photo maybeUrl =
    Element.row
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        ]
        [ case maybeUrl of
            Just url ->
                Element.image
                    [ Element.width (Element.px 72)
                    , Element.height (Element.px 72)
                    , Border.rounded DesignTokens.radiusControl
                    ]
                    { src = url, description = File.name photo }

            Nothing ->
                Element.el
                    [ Element.width (Element.px 72)
                    , Element.height (Element.px 72)
                    ]
                    (Element.text (I18n.t language TidAssistantLoadingPreview))
        , Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space4
            ]
            [ Element.paragraph [ Element.width Element.fill ]
                [ Element.text (File.name photo) ]
            , Typography.mutedParagraph theme (formatPhotoSize (File.size photo))
            , Button.textButton device
                theme
                { tone = Button.DangerOutline
                , width = Button.ContentWidth
                , label = I18n.t language TidAssistantRemovePhoto
                , onPress = RemovePhoto index
                , submitState = Nothing
                , submittingLabel = Nothing
                , trailing = Nothing
                }
            ]
        ]


formatPhotoSize : Int -> String
formatPhotoSize bytes =
    if bytes >= 1024 * 1024 then
        String.fromFloat (toFloat bytes / toFloat (1024 * 1024)) ++ " MiB"

    else
        String.fromInt ((bytes + 1023) // 1024) ++ " KiB"


sendButton : FoodDraftPurpose -> Theme -> Language -> Device -> RequestState -> Element Msg
sendButton purpose theme language device request =
    Button.textButton device
        theme
        { tone = Button.Primary
        , width = Button.FullWidth
        , label =
            case purpose of
                CustomFood ->
                    I18n.t language TidAssistantSend

                AdHocLog ->
                    I18n.t language TidAssistantEstimateFood
        , onPress = SendClicked
        , submitState =
            Just
                (if request == Sending then
                    Button.Submitting

                 else
                    Button.Idle
                )
        , submittingLabel = Just (I18n.t language TidAssistantGeneratingDraft)
        , trailing = Nothing
        }


requestErrorView : Theme -> Language -> Device -> RequestState -> Element Msg
requestErrorView theme language device request =
    case request of
        RequestFailed message ->
            Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ Feedback.errorBanner theme message
                , Button.textButton device
                    theme
                    { tone = Button.Ghost
                    , width = Button.FullWidth
                    , label = I18n.t language TidAssistantRetryLastRequest
                    , onPress = RetryClicked
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                ]

        InputFailed message ->
            Feedback.errorBanner theme message

        _ ->
            Element.none


warningView : Theme -> Language -> List String -> Element Msg
warningView theme language warnings =
    if List.isEmpty warnings then
        Element.none

    else
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
            (List.map
                (\warning ->
                    Element.paragraph
                        [ Element.width Element.fill
                        , Element.padding DesignTokens.space12
                        , Border.rounded DesignTokens.radiusControl
                        , Background.color theme.brandBlueSoft
                        ]
                        [ Element.text
                            (I18n.t language (TidAssistantReviewEstimatePrefix warning))
                        ]
                )
                warnings
            )


draftPreviewView :
    FoodDraftPurpose
    -> Theme
    -> Language
    -> Device
    -> Bool
    -> ChatModel
    -> Element Msg
draftPreviewView purpose theme language device formHasManualInput chat =
    case chat.draft of
        Nothing ->
            Element.none

        Just draft ->
            let
                preview : DraftPreviewData
                preview =
                    draftPreviewData language draft
            in
            Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space12
                , Element.padding DesignTokens.space12
                , Border.width 1
                , Border.color theme.divider
                , Border.rounded DesignTokens.radiusControl
                ]
                [ Element.row [ Element.width Element.fill ]
                    [ Typography.subsectionTitle theme (I18n.t language TidAssistantDraftPreview)
                    , if chat.request == Sending then
                        Element.none

                      else
                        Element.el [ Element.alignRight ]
                            (Button.textButton device
                                theme
                                { tone = Button.DangerOutline
                                , width = Button.ContentWidth
                                , label = I18n.t language TidAssistantNewSession
                                , onPress = NewSessionClicked
                                , submitState = Nothing
                                , submittingLabel = Nothing
                                , trailing = Nothing
                                }
                            )
                    ]
                , previewRows theme preview.details
                , previewSection
                    theme
                    language
                    (I18n.t language TidAssistantNutritionPer100g)
                    preview.nutrients
                , previewSection
                    theme
                    language
                    (I18n.t language TidFoodEditorServings)
                    preview.servings
                , draftActionView purpose theme language device formHasManualInput chat
                ]


previewSection : Theme -> Language -> String -> List ( String, String ) -> Element Msg
previewSection theme language title rows =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.el [ Font.bold ] (Element.text title)
        , if List.isEmpty rows then
            Typography.mutedParagraph theme (I18n.t language TidAssistantNoNutrientsSuggested)

          else
            previewRows theme rows
        ]


previewRows : Theme -> List ( String, String ) -> Element Msg
previewRows theme rows =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        (List.map (previewRow theme) rows)


previewRow : Theme -> ( String, String ) -> Element Msg
previewRow theme ( label, value ) =
    Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Element.el [ Font.color theme.textMuted ] (Element.text label)
        , Element.paragraph [ Element.width Element.fill, Font.alignRight ]
            [ Element.text value ]
        ]


draftPreviewData : Language -> FoodDraft -> DraftPreviewData
draftPreviewData language draft =
    { details =
        [ ( I18n.t language TidFoodEditorName, draft.name )
        , ( I18n.t language TidFoodEditorBrand
          , Maybe.withDefault (I18n.t language TidCommonNotSpecified) draft.brand
          )
        , ( I18n.t language TidFoodEditorCategories
          , defaultText (I18n.t language TidCommonNoneSuggested) (String.join ", " draft.categories)
          )
        , ( I18n.t language TidAssistantDefaultQuantity
          , case ( draft.defaultQuantity, draft.defaultUnit ) of
                ( Just quantity, Just unit ) ->
                    quantity ++ " " ++ unit

                _ ->
                    I18n.t language TidCommonNotSpecified
          )
        ]
    , nutrients =
        List.map
            (\nutrient ->
                ( Nutrients.nutrientLabel language nutrient.code
                , nutrient.amountPer100g ++ " " ++ nutrientUnit nutrient.code
                )
            )
            draft.nutrients
    , servings =
        List.map
            (\serving ->
                ( serving.unit
                , I18n.t language
                    (TidAssistantServingConversion
                        serving.unit
                        serving.gramsPerUnit
                    )
                )
            )
            draft.servings
    }


nutrientUnit : String -> String
nutrientUnit code =
    if String.endsWith "_KCAL" code then
        "kcal"

    else if String.endsWith "_MG" code then
        "mg"

    else if String.endsWith "_UG" code then
        "µg"

    else if String.endsWith "_G" code then
        "g"

    else
        ""


defaultText : String -> String -> String
defaultText fallback value =
    if String.isEmpty value then
        fallback

    else
        value


draftActionView :
    FoodDraftPurpose
    -> Theme
    -> Language
    -> Device
    -> Bool
    -> ChatModel
    -> Element Msg
draftActionView purpose theme language device formHasManualInput chat =
    case chat.draft of
        Nothing ->
            Element.none

        Just _ ->
            if chat.awaitingOverwriteConfirmation then
                confirmationSurface theme
                    [ Element.paragraph [ Element.width Element.fill ]
                        [ Element.text (I18n.t language TidAssistantApplyReplacesForm) ]
                    , compactActionRow device
                        [ Button.textButton device
                            theme
                            { tone = Button.Ghost
                            , width = Button.ResponsiveWidth
                            , label = I18n.t language TidCommonCancel
                            , onPress = CancelOverwriteClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        , Button.textButton device
                            theme
                            { tone = Button.Danger
                            , width = Button.ResponsiveWidth
                            , label = I18n.t language TidAssistantReplaceFormValues
                            , onPress = ConfirmOverwriteClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        ]
                    ]

            else
                Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space8
                    ]
                    [ Element.el [ Element.width Element.fill ]
                        (Button.textButton device
                            theme
                            { tone = Button.PrimaryOutline
                            , width = Button.FullWidth
                            , label =
                                if chat.askingForChanges then
                                    I18n.t language TidAssistantCancelChanges

                                else
                                    I18n.t language TidAssistantAskForChanges
                            , onPress =
                                if chat.askingForChanges then
                                    CancelChangesClicked

                                else
                                    AskForChangesClicked
                            , submitState = Just Button.Idle
                            , submittingLabel = Just (I18n.t language TidAssistantAskForChanges)
                            , trailing = Nothing
                            }
                        )
                    , Element.el [ Element.width Element.fill ]
                        (Button.textButton device
                            theme
                            { tone = Button.Primary
                            , width = Button.FullWidth
                            , label =
                                case purpose of
                                    CustomFood ->
                                        I18n.t language TidAssistantApplyToForm

                                    AdHocLog ->
                                        I18n.t language TidAssistantReviewEstimate
                            , onPress = ApplyDraftClicked formHasManualInput
                            , submitState = Just Button.Idle
                            , submittingLabel = Just (I18n.t language TidAssistantApplying)
                            , trailing = Nothing
                            }
                        )
                    ]


confirmationSurface : Theme -> List (Element msg) -> Element msg
confirmationSurface theme children =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space12
        , Element.padding DesignTokens.space12
        , Background.color theme.dangerBg
        , Font.color theme.dangerFg
        , Border.rounded DesignTokens.radiusControl
        ]
        children


compactActionRow : Device -> List (Element msg) -> Element msg
compactActionRow device actions =
    if UiCommon.isSmall device then
        Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            actions

    else
        Element.row
            [ Element.alignRight
            , Element.spacing DesignTokens.space8
            ]
            actions
