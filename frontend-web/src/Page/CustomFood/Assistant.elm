module Page.CustomFood.Assistant exposing
    ( ChatModel
    , DraftPreviewData
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , RequestState(..)
    , draftPreviewData
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant
    exposing
        ( AssistantStatus
        , Conversation
        , ConversationRole(..)
        , ConversationTurn
        , FoodDraft
        , FoodDraftTurn(..)
        )
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients as Nutrients


type Model
    = LoadingStatus
    | Disabled
    | StatusFailed
    | Enabled ChatModel


type alias ChatModel =
    { expanded : Bool
    , transcript : List ConversationTurn
    , description : String
    , request : RequestState
    , draft : Maybe FoodDraft
    , warnings : List String
    , awaitingOverwriteConfirmation : Bool
    }


type alias DraftPreviewData =
    { details : List ( String, String )
    , nutrients : List ( String, String )
    , servings : List ( String, String )
    }


type RequestState
    = Ready
    | Sending
    | InputFailed String
    | RequestFailed String


type Msg
    = StatusLoaded (Result Client.ApiError AssistantStatus)
    | RetryStatusClicked
    | ToggleExpanded
    | DescriptionChanged String
    | SendClicked
    | DraftCompleted (Result Client.ApiError FoodDraftTurn)
    | RetryClicked
    | NewSessionClicked
    | ApplyDraftClicked Bool
    | ConfirmOverwriteClicked
    | CancelOverwriteClicked


type OutMsg
    = NoOutMsg
    | RequestStatus
    | RequestDraft Conversation
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
    , awaitingOverwriteConfirmation = False
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        StatusLoaded result ->
            case result of
                Ok status ->
                    if status.enabled then
                        ( Enabled emptyChat, Cmd.none, NoOutMsg )

                    else
                        ( Disabled, Cmd.none, NoOutMsg )

                Err error ->
                    ( StatusFailed
                    , Cmd.none
                    , sessionOutMsg error
                    )

        RetryStatusClicked ->
            ( LoadingStatus, Cmd.none, RequestStatus )

        ToggleExpanded ->
            updateChat
                (\chat ->
                    ( { chat | expanded = not chat.expanded }, NoOutMsg )
                )
                model

        DescriptionChanged description ->
            updateChat
                (\chat -> ( { chat | description = description }, NoOutMsg ))
                model

        SendClicked ->
            updateChat sendDescription model

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
            updateChat retryDraft model

        NewSessionClicked ->
            updateChat newSession model

        ApplyDraftClicked formHasManualInput ->
            updateChat (requestApply formHasManualInput) model

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


sendDescription : ChatModel -> ( ChatModel, OutMsg )
sendDescription chat =
    if chat.request == Sending then
        ( chat, NoOutMsg )

    else
        case FoodAssistant.userTurn chat.description of
            Err message ->
                ( { chat | request = InputFailed message }, NoOutMsg )

            Ok turn ->
                sendTranscript (chat.transcript ++ [ turn ]) chat


sendTranscript : List ConversationTurn -> ChatModel -> ( ChatModel, OutMsg )
sendTranscript transcript chat =
    case FoodAssistant.conversation transcript of
        Err message ->
            ( { chat | request = InputFailed message }, NoOutMsg )

        Ok boundedConversation ->
            ( { chat
                | transcript = transcript
                , description = ""
                , request = Sending
                , draft = Nothing
                , warnings = []
                , awaitingOverwriteConfirmation = False
              }
            , RequestDraft boundedConversation
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
                , warnings = readyDraft.warnings
                , awaitingOverwriteConfirmation = False
              }
            , NoOutMsg
            )


retryDraft : ChatModel -> ( ChatModel, OutMsg )
retryDraft chat =
    case ( chat.request, FoodAssistant.conversation chat.transcript ) of
        ( RequestFailed _, Ok boundedConversation ) ->
            ( { chat | request = Sending }, RequestDraft boundedConversation )

        _ ->
            ( chat, NoOutMsg )


newSession : ChatModel -> ( ChatModel, OutMsg )
newSession chat =
    ( { emptyChat | expanded = chat.expanded }, NoOutMsg )


requestApply : Bool -> ChatModel -> ( ChatModel, OutMsg )
requestApply formHasManualInput chat =
    case chat.draft of
        Nothing ->
            ( chat, NoOutMsg )

        Just draft ->
            if formHasManualInput then
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
                    "The assistant is busy. Try again in "
                        ++ String.fromInt seconds
                        ++ " seconds."

                Nothing ->
                    "The assistant is busy. Wait a moment, then retry."

        Client.Timeout ->
            "The assistant took too long to respond. Please retry."

        Client.NetworkError ->
            "The assistant could not be reached. Check your connection and retry."

        Client.BadStatus 401 _ _ ->
            "Your session has expired."

        _ ->
            "The assistant could not create a draft. Please retry."


view : Theme -> Device -> Bool -> Model -> Element Msg
view theme device formHasManualInput model =
    case model of
        LoadingStatus ->
            Ui.card theme
                [ Ui.loading theme "Checking whether food assistance is available..." ]

        Disabled ->
            Ui.card theme
                [ Typography.subsectionTitle theme "Create with AI"
                , Typography.mutedParagraph theme
                    "Food assistance is unavailable on this deployment."
                ]

        StatusFailed ->
            Ui.card theme
                [ Typography.subsectionTitle theme "Create with AI"
                , Ui.errorBanner theme
                    "Food-assistant availability could not be checked."
                , Ui.fullWidthGhostButton
                    device
                    theme
                    "Retry availability check"
                    RetryStatusClicked
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
            "Describe a food or dish. Review every estimate before creating it."
        , Typography.mutedParagraph theme
            (String.concat
                [ "Your descriptions and replies go to the configured AI provider. "
                , "CalCo does not store them."
                ]
            )
        ]
            ++ (if chat.expanded then
                    expandedContent theme device formHasManualInput chat

                else
                    []
               )


expandedContent : Theme -> Device -> Bool -> ChatModel -> List (Element Msg)
expandedContent theme device formHasManualInput chat =
    [ transcriptView theme chat.transcript
    , draftPreviewView theme chat.draft
    , warningView theme chat.warnings
    , requestErrorView theme device chat.request
    , descriptionInput theme chat
    , sendButton theme device chat.request
    , Ui.fullWidthGhostButton device theme "New session" NewSessionClicked
    ]
        ++ draftActionView theme device formHasManualInput chat


transcriptView : Theme -> List ConversationTurn -> Element Msg
transcriptView theme transcript =
    if List.isEmpty transcript then
        Typography.mutedParagraph theme
            "Start with the food, portion, ingredients, and known nutrition."

    else
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
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
                (case FoodAssistant.turnRole turn of
                    User ->
                        "You"

                    Assistant ->
                        "CalCo assistant"
                )
            )
        , Element.paragraph [ Element.width Element.fill ]
            [ Element.text (FoodAssistant.turnText turn) ]
        ]


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
                    (Element.text "For example: one bowl of dal, about 300 g")
                )
        , label = Input.labelAbove [] (Ui.fieldLabel theme "Food description or answer")
        , spellcheck = True
        }


sendButton : Theme -> Device -> RequestState -> Element Msg
sendButton theme device request =
    Ui.secondarySubmitButton device
        theme
        { state =
            if request == Sending then
                Ui.Submitting

            else
                Ui.Idle
        , idleLabel = "Send to assistant"
        , submittingLabel = "Getting estimate..."
        , onPress = SendClicked
        }


requestErrorView : Theme -> Device -> RequestState -> Element Msg
requestErrorView theme device request =
    case request of
        RequestFailed message ->
            Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ Ui.errorBanner theme message
                , Ui.fullWidthGhostButton
                    device
                    theme
                    "Retry last request"
                    RetryClicked
                ]

        InputFailed message ->
            Ui.errorBanner theme message

        _ ->
            Element.none


warningView : Theme -> List String -> Element Msg
warningView theme warnings =
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
                        [ Element.text ("Review estimate: " ++ warning) ]
                )
                warnings
            )


draftPreviewView : Theme -> Maybe FoodDraft -> Element Msg
draftPreviewView theme maybeDraft =
    case maybeDraft of
        Nothing ->
            Element.none

        Just draft ->
            let
                preview : DraftPreviewData
                preview =
                    draftPreviewData draft
            in
            Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space12
                , Element.padding DesignTokens.space12
                , Border.width 1
                , Border.color theme.divider
                , Border.rounded DesignTokens.radiusControl
                ]
                [ Typography.subsectionTitle theme "Draft preview"
                , previewRows theme preview.details
                , previewSection theme "Nutrition per 100 g" preview.nutrients
                , previewSection theme "Servings" preview.servings
                ]


previewSection : Theme -> String -> List ( String, String ) -> Element Msg
previewSection theme title rows =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.el [ Font.bold ] (Element.text title)
        , if List.isEmpty rows then
            Typography.mutedParagraph theme "None suggested."

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


draftPreviewData : FoodDraft -> DraftPreviewData
draftPreviewData draft =
    { details =
        [ ( "Name", draft.name )
        , ( "Brand", Maybe.withDefault "Not specified" draft.brand )
        , ( "Categories", defaultText "None suggested" (String.join ", " draft.categories) )
        , ( "Serving size"
          , Maybe.map (\value -> value ++ " g") draft.servingSizeG
                |> Maybe.withDefault "Not specified"
          )
        , ( "Default quantity"
          , case ( draft.defaultQuantity, draft.defaultUnit ) of
                ( Just quantity, Just unit ) ->
                    quantity ++ " " ++ unit

                _ ->
                    "Not specified"
          )
        ]
    , nutrients =
        List.map
            (\nutrient ->
                ( Nutrients.nutrientLabel nutrient.code
                , nutrient.amountPer100g ++ " " ++ nutrientUnit nutrient.code
                )
            )
            draft.nutrients
    , servings =
        List.map
            (\serving ->
                ( serving.label
                , serving.quantity
                    ++ " "
                    ++ serving.unit
                    ++ " = "
                    ++ serving.grams
                    ++ " g"
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


draftActionView : Theme -> Device -> Bool -> ChatModel -> List (Element Msg)
draftActionView theme device formHasManualInput chat =
    case chat.draft of
        Nothing ->
            []

        Just _ ->
            if chat.awaitingOverwriteConfirmation then
                [ Ui.errorBanner theme
                    "Applying this draft will replace the values already in the form."
                , Ui.secondarySubmitButton device
                    theme
                    { state = Ui.Idle
                    , idleLabel = "Replace form values"
                    , submittingLabel = "Replacing..."
                    , onPress = ConfirmOverwriteClicked
                    }
                , Ui.fullWidthGhostButton
                    device
                    theme
                    "Cancel"
                    CancelOverwriteClicked
                ]

            else
                [ Ui.secondarySubmitButton device
                    theme
                    { state = Ui.Idle
                    , idleLabel =
                        if formHasManualInput then
                            "Apply draft to form..."

                        else
                            "Apply draft to form"
                    , submittingLabel = "Applying..."
                    , onPress = ApplyDraftClicked formHasManualInput
                    }
                ]
