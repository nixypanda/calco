module Page.CustomFood.Assistant exposing
    ( ChatModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , RequestState(..)
    , init
    , update
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
    | SendClicked
    | DraftCompleted (Result Client.ApiError FoodDraftTurn)
    | RetryClicked
    | ApplyDraftClicked Bool
    | ConfirmReplacementClicked
    | CancelReplacementClicked


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
    , awaitingReplacementConfirmation = False
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
                    statusFailure error

        RetryStatusClicked ->
            ( LoadingStatus, Cmd.none, RequestStatus )

        ToggleExpanded ->
            updateChat (\chat -> ( { chat | expanded = not chat.expanded }, NoOutMsg )) model

        DescriptionChanged description ->
            updateChat (\chat -> ( { chat | description = description }, NoOutMsg )) model

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
          }
        , RequestDraft { turns = transcript }
        )


completeDraft : FoodDraftTurn -> ChatModel -> ( ChatModel, OutMsg )
completeDraft turn chat =
    ( { chat
        | transcript = chat.transcript ++ [ { role = Assistant, text = turn.assistantMessage } ]
        , request = Ready
        , draft = turn.draft
        , warnings = turn.warnings
        , awaitingReplacementConfirmation = False
      }
    , NoOutMsg
    )


retryDraft : ChatModel -> ( ChatModel, OutMsg )
retryDraft chat =
    case chat.request of
        SendFailed _ ->
            ( { chat | request = Sending }, RequestDraft { turns = chat.transcript } )

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
