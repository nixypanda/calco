module Page.CustomFood.Assistant exposing
    ( ChatModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , PhotoMetadata
    , RequestState(..)
    , init
    , update
    , validatePhotoMetadata
    , view
    )

import Api.Client as Client
import Data.FoodAssistant
    exposing
        ( AssistantStatus
        , Conversation
        , ConversationRole(..)
        , ConversationTurn
        , FoodDraft
        , FoodDraftTurn
        )
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import File exposing (File)
import File.Select
import Task
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type Model
    = LoadingStatus
    | Disabled
    | StatusFailed String
    | Enabled ChatModel


type alias ChatModel =
    { expanded : Bool
    , transcript : List ConversationTurn
    , description : String
    , request : RequestState
    , draft : Maybe FoodDraft
    , warnings : List String
    , awaitingReplacementConfirmation : Bool
    , supportsImages : Bool
    , photos : List File
    , photoUrls : List (Maybe String)
    , photoError : Maybe String
    }


type alias PhotoMetadata =
    { mimeType : String
    , size : Int
    }


type RequestState
    = Ready
    | Sending
    | SendFailed String


type Msg
    = StatusLoaded (Result Client.ApiError AssistantStatus)
    | RetryStatusClicked
    | ToggleExpanded
    | DescriptionChanged String
    | ChoosePhotos
    | PhotosSelected File (List File)
    | PhotoPreviewLoaded Int String
    | RemovePhoto Int
    | SendClicked
    | DraftCompleted (Result Client.ApiError FoodDraftTurn)
    | RetryClicked
    | ApplyDraftClicked Bool
    | ConfirmReplacementClicked
    | CancelReplacementClicked


type OutMsg
    = NoOutMsg
    | RequestStatus
    | RequestDraft Conversation (List File)
    | ApplyDraft FoodDraft
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( LoadingStatus, RequestStatus )


emptyChat : ChatModel
emptyChat =
    { expanded = False
    , transcript = []
    , description = ""
    , request = Ready
    , draft = Nothing
    , warnings = []
    , awaitingReplacementConfirmation = False
    , supportsImages = False
    , photos = []
    , photoUrls = []
    , photoError = Nothing
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
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
                    statusFailure error

        RetryStatusClicked ->
            ( LoadingStatus, Cmd.none, RequestStatus )

        ToggleExpanded ->
            updateChat (\chat -> ( { chat | expanded = not chat.expanded }, NoOutMsg )) model

        DescriptionChanged description ->
            updateChat (\chat -> ( { chat | description = description }, NoOutMsg )) model

        ChoosePhotos ->
            case model of
                Enabled chat ->
                    if chat.supportsImages && List.length chat.photos < 4 then
                        ( model
                        , File.Select.files
                            [ "image/jpeg", "image/png", "image/webp" ]
                            PhotosSelected
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
                    , NoOutMsg
                    )
                )
                model

        SendClicked ->
            updateChat sendDescription model

        DraftCompleted result ->
            case result of
                Ok turn ->
                    updateChat (completeDraft turn) model

                Err error ->
                    draftFailure error model

        RetryClicked ->
            updateChat retryDraft model

        ApplyDraftClicked formHasManualInput ->
            updateChat (requestApply formHasManualInput) model

        ConfirmReplacementClicked ->
            updateChat confirmReplacement model

        CancelReplacementClicked ->
            updateChat
                (\chat -> ( { chat | awaitingReplacementConfirmation = False }, NoOutMsg ))
                model


updateChat : (ChatModel -> ( ChatModel, OutMsg )) -> Model -> ( Model, Cmd Msg, OutMsg )
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


statusFailure : Client.ApiError -> ( Model, Cmd Msg, OutMsg )
statusFailure error =
    ( StatusFailed (Client.displayError error)
    , Cmd.none
    , if Client.isUnauthorized error then
        SessionExpired

      else
        NoOutMsg
    )


draftFailure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
draftFailure error model =
    updateChat
        (\chat -> ( { chat | request = SendFailed (Client.displayError error) }, NoOutMsg ))
        model
        |> withSessionExpired error


withSessionExpired : Client.ApiError -> ( Model, Cmd Msg, OutMsg ) -> ( Model, Cmd Msg, OutMsg )
withSessionExpired error ( next, command, outMsg ) =
    if Client.isUnauthorized error then
        ( next, command, SessionExpired )

    else
        ( next, command, outMsg )


sendDescription : ChatModel -> ( ChatModel, OutMsg )
sendDescription chat =
    let
        text : String
        text =
            String.trim chat.description
    in
    if String.isEmpty text || chat.request == Sending then
        ( chat, NoOutMsg )

    else
        let
            transcript : List ConversationTurn
            transcript =
                chat.transcript ++ [ { role = User, text = text } ]
        in
        ( { chat
            | transcript = transcript
            , description = ""
            , request = Sending
            , draft = Nothing
            , warnings = []
            , awaitingReplacementConfirmation = False
            , photoError = Nothing
          }
        , RequestDraft { turns = transcript } chat.photos
        )


completeDraft : FoodDraftTurn -> ChatModel -> ( ChatModel, OutMsg )
completeDraft turn chat =
    ( { chat
        | transcript = chat.transcript ++ [ { role = Assistant, text = turn.assistantMessage } ]
        , request = Ready
        , draft = turn.draft
        , warnings = turn.warnings
        , awaitingReplacementConfirmation = False
        , photos =
            case turn.status of
                Data.FoodAssistant.DraftReady ->
                    []

                Data.FoodAssistant.NeedsClarification ->
                    chat.photos
        , photoUrls =
            case turn.status of
                Data.FoodAssistant.DraftReady ->
                    []

                Data.FoodAssistant.NeedsClarification ->
                    chat.photoUrls
        , photoError =
            case turn.status of
                Data.FoodAssistant.DraftReady ->
                    Nothing

                Data.FoodAssistant.NeedsClarification ->
                    chat.photoError
      }
    , NoOutMsg
    )


retryDraft : ChatModel -> ( ChatModel, OutMsg )
retryDraft chat =
    case chat.request of
        SendFailed _ ->
            ( { chat | request = Sending }, RequestDraft { turns = chat.transcript } chat.photos )

        _ ->
            ( chat, NoOutMsg )


requestApply : Bool -> ChatModel -> ( ChatModel, OutMsg )
requestApply formHasManualInput chat =
    case chat.draft of
        Nothing ->
            ( chat, NoOutMsg )

        Just draft ->
            if formHasManualInput then
                ( { chat | awaitingReplacementConfirmation = True }, NoOutMsg )

            else
                ( chat, ApplyDraft draft )


confirmReplacement : ChatModel -> ( ChatModel, OutMsg )
confirmReplacement chat =
    if chat.awaitingReplacementConfirmation then
        case chat.draft of
            Just draft ->
                ( { chat | awaitingReplacementConfirmation = False }, ApplyDraft draft )

            Nothing ->
                ( { chat | awaitingReplacementConfirmation = False }, NoOutMsg )

    else
        ( chat, NoOutMsg )


view : Theme -> Device -> Bool -> Model -> Element Msg
view theme device formHasManualInput model =
    case model of
        LoadingStatus ->
            Ui.card theme [ Ui.loading theme "Checking whether food assistance is available..." ]

        Disabled ->
            Ui.card theme
                [ Typography.subsectionTitle theme "Create with AI"
                , Typography.mutedParagraph theme
                    "Food assistance is unavailable on this deployment."
                ]

        StatusFailed message ->
            Ui.card theme
                [ Typography.subsectionTitle theme "Create with AI"
                , Ui.errorBanner theme message
                , Ui.fullWidthGhostButton device theme "Retry availability check" RetryStatusClicked
                ]

        Enabled chat ->
            enabledView theme device formHasManualInput chat


enabledView : Theme -> Device -> Bool -> ChatModel -> Element Msg
enabledView theme device formHasManualInput chat =
    Ui.card theme <|
        [ Element.row [ Element.width Element.fill ]
            [ Typography.subsectionTitle theme "Create with AI"
            , Element.el [ Element.alignRight ]
                (Ui.fullWidthGhostButton
                    device
                    theme
                    (if chat.expanded then
                        "Hide"

                     else
                        "Start"
                    )
                    ToggleExpanded
                )
            ]
        , Typography.mutedParagraph theme
            "Describe a food or dish. Estimates must be reviewed before you create it."
        ]
            ++ (if chat.expanded then
                    expandedContent theme device formHasManualInput chat

                else
                    []
               )


expandedContent : Theme -> Device -> Bool -> ChatModel -> List (Element Msg)
expandedContent theme device formHasManualInput chat =
    [ transcriptView theme chat.transcript
    , warningView theme chat.warnings
    , requestErrorView theme chat.request
    , descriptionInput theme chat
    , photoPicker theme device chat
    , sendButton theme device chat.request
    ]
        ++ draftActionView theme device formHasManualInput chat


transcriptView : Theme -> List ConversationTurn -> Element Msg
transcriptView theme transcript =
    if List.isEmpty transcript then
        Typography.mutedParagraph theme
            (String.concat
                [ "Start with the food name, portion, ingredients, and anything "
                , "you know about the nutrition."
                ]
            )

    else
        Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            (List.map (turnView theme) transcript)


turnView : Theme -> ConversationTurn -> Element Msg
turnView theme turn =
    Element.column
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        , Border.rounded DesignTokens.radiusControl
        , Background.color theme.inputFill
        , Element.spacing DesignTokens.space4
        ]
        [ Element.el [ Font.bold ]
            (Element.text
                (case turn.role of
                    User ->
                        "You"

                    Assistant ->
                        "CalCo assistant"
                )
            )
        , Element.paragraph [ Element.width Element.fill ] [ Element.text turn.text ]
        ]


warningView : Theme -> List String -> Element Msg
warningView theme warnings =
    if List.isEmpty warnings then
        Element.none

    else
        Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
            (List.map
                (\warning ->
                    Element.paragraph
                        [ Element.width Element.fill
                        , Element.padding DesignTokens.space12
                        , Border.rounded DesignTokens.radiusControl
                        , Background.color theme.brandBlueSoft
                        , Font.color theme.textPrimary
                        ]
                        [ Element.text ("Review estimate: " ++ warning) ]
                )
                warnings
            )


requestErrorView : Theme -> RequestState -> Element Msg
requestErrorView theme request =
    case request of
        SendFailed message ->
            Ui.errorBanner theme ("Food assistance could not respond. You can retry: " ++ message)

        _ ->
            Element.none


descriptionInput : Theme -> ChatModel -> Element Msg
descriptionInput theme chat =
    Input.multiline
        [ Element.width Element.fill
        , Element.height (Element.px 120)
        , Border.rounded DesignTokens.radiusControl
        , Background.color theme.inputFill
        , Element.padding 10
        ]
        { onChange = DescriptionChanged
        , text = chat.description
        , placeholder =
            Just
                (Input.placeholder []
                    (Element.text "For example: one bowl chicken biryani, about 350 g")
                )
        , label = Input.labelAbove [] (Ui.fieldLabel theme "Food description or answer")
        , spellcheck = True
        }


sendButton : Theme -> Device -> RequestState -> Element Msg
sendButton theme device request =
    Ui.secondarySubmitButton device
        theme
        { state =
            case request of
                Sending ->
                    Ui.Submitting

                _ ->
                    Ui.Idle
        , idleLabel = "Send to assistant"
        , submittingLabel = "Getting estimate..."
        , onPress = SendClicked
        }


photoPicker : Theme -> Device -> ChatModel -> Element Msg
photoPicker theme device chat =
    if not chat.supportsImages then
        Typography.mutedParagraph theme "Photos are not supported by the configured food assistant."

    else
        Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            (Typography.mutedParagraph
                theme
                (String.concat
                    [ "Optional photos can improve an estimate. Photos are sent only with this "
                    , "assistant request and are not saved."
                    ]
                )
                :: photoChooseButton theme device chat
                ++ photoErrorView theme chat.photoError
                ++ List.indexedMap
                    (\index photo ->
                        photoPreview
                            theme
                            device
                            index
                            photo
                            (Maybe.withDefault Nothing (valueAt index chat.photoUrls))
                    )
                    chat.photos
            )


photoChooseButton : Theme -> Device -> ChatModel -> List (Element Msg)
photoChooseButton theme device chat =
    if List.length chat.photos < 4 then
        [ Ui.fullWidthGhostButton
            device
            theme
            (if List.isEmpty chat.photos then
                "Add food photos (up to 4)"

             else
                "Add another photo"
            )
            ChoosePhotos
        ]

    else
        []


photoErrorView : Theme -> Maybe String -> List (Element Msg)
photoErrorView theme photoError =
    case photoError of
        Just message ->
            [ Ui.errorBanner theme message ]

        Nothing ->
            []


photoPreview : Theme -> Device -> Int -> File -> Maybe String -> Element Msg
photoPreview theme device index photo previewUrl =
    Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ photoPreviewImage photo previewUrl
        , Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
            [ Element.text (File.name photo)
            , Typography.mutedParagraph theme (String.fromInt (File.size photo) ++ " bytes")
            , Ui.fullWidthGhostButton device theme "Remove photo" (RemovePhoto index)
            ]
        ]


photoPreviewImage : File -> Maybe String -> Element Msg
photoPreviewImage photo previewUrl =
    case previewUrl of
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
                , Border.rounded DesignTokens.radiusControl
                ]
                (Element.text "Loading preview…")


addSelectedPhotos : List File -> Model -> ( Model, Cmd Msg, OutMsg )
addSelectedPhotos files model =
    case model of
        Enabled chat ->
            let
                initialPhotoCount : Int
                initialPhotoCount =
                    List.length chat.photos

                ( next, outMsg ) =
                    addPhotos files chat

                addedPhotos : List File
                addedPhotos =
                    List.drop initialPhotoCount next.photos

                previewCommands : List (Cmd Msg)
                previewCommands =
                    addedPhotos
                        |> List.indexedMap
                            (\index photo ->
                                File.toUrl photo
                                    |> Task.perform
                                        (PhotoPreviewLoaded (initialPhotoCount + index))
                            )
            in
            ( Enabled next, Cmd.batch previewCommands, outMsg )

        _ ->
            ( model, Cmd.none, NoOutMsg )


addPhotos : List File -> ChatModel -> ( ChatModel, OutMsg )
addPhotos files chat =
    let
        remaining : Int
        remaining =
            4 - List.length chat.photos

        accepted : List File
        accepted =
            List.take remaining files
    in
    case
        validatePhotoMetadata
            (List.map photoMetadata chat.photos)
            (List.map photoMetadata accepted)
    of
        Err error ->
            ( { chat | photoError = Just error }, NoOutMsg )

        Ok () ->
            ( { chat
                | photos = chat.photos ++ accepted
                , photoUrls = chat.photoUrls ++ List.repeat (List.length accepted) Nothing
                , photoError =
                    if List.length files > remaining then
                        Just "Only four photos can be attached. Extra selections were not added."

                    else
                        Nothing
              }
            , NoOutMsg
            )


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
    if List.any (\photo -> not (supportedPhotoMime photo.mimeType)) photos then
        Err "Photos must be JPEG, PNG, or WebP."

    else if List.any (\photo -> photo.size > maxPhotoBytes) photos then
        Err "Each photo must be 5 MiB or smaller."

    else if List.sum (List.map .size photos) > maxTotalPhotoBytes then
        Err "Photos together must be 12 MiB or smaller."

    else
        Ok ()


supportedPhotoMime : String -> Bool
supportedPhotoMime mimeType =
    List.member mimeType [ "image/jpeg", "image/png", "image/webp" ]


maxPhotoBytes : Int
maxPhotoBytes =
    5 * 1024 * 1024


maxTotalPhotoBytes : Int
maxTotalPhotoBytes =
    12 * 1024 * 1024


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


draftActionView : Theme -> Device -> Bool -> ChatModel -> List (Element Msg)
draftActionView theme device formHasManualInput chat =
    case chat.draft of
        Nothing ->
            case chat.request of
                SendFailed _ ->
                    [ Ui.fullWidthGhostButton device theme "Retry assistant" RetryClicked ]

                _ ->
                    []

        Just _ ->
            if chat.awaitingReplacementConfirmation then
                [ Ui.errorBanner theme
                    "Applying this draft replaces the values currently in the form."
                , Ui.fullWidthDangerButton
                    device
                    theme
                    "Replace form with draft"
                    ConfirmReplacementClicked
                , Ui.fullWidthGhostButton device theme "Keep current form" CancelReplacementClicked
                ]

            else
                [ Typography.mutedParagraph theme
                    (if formHasManualInput then
                        String.concat
                            [ "Your form already contains values. Applying the draft will ask you "
                            , "to confirm replacement."
                            ]

                     else
                        "Apply the draft, then review every field before creating the food."
                    )
                , Ui.fullWidthGhostButton
                    device
                    theme
                    "Apply draft to form"
                    (ApplyDraftClicked formHasManualInput)
                ]
