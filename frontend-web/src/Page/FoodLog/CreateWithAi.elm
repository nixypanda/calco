module Page.FoodLog.CreateWithAi exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , modalView
    , photoPreviewUrls
    , update
    , view
    )

import Api.Client as Client
import Api.Foods exposing (CategorySuggestionRequest, CreateFoodRequest, NutrientItem, UnitItem)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Editor
import Data.FoodAssistant as FoodAssistant exposing (Conversation, FoodDraftPurpose(..))
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot)
import Element exposing (Device, Element)
import File exposing (File)
import Lib.Ticket exposing (Ticket)
import Page.FoodLog.CreateAdHoc as Review
import Ui.Button as Button
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type alias Model =
    { assistant : Assistant.Model
    , review : Maybe Review.Model
    , estimate : Maybe Assistant.DraftResult
    , draft : Maybe FoodAssistant.FoodDraft
    , warnings : List String
    , showAdditionalNutrients : Bool
    , units : List UnitItem
    , nutrients : List NutrientItem
    , dateParam : Maybe String
    , mealSlot : Maybe MealSlot
    , error : Maybe String
    }


init : Maybe String -> Maybe MealSlot -> ( Model, OutMsg )
init dateParam mealSlot =
    ( { assistant = Tuple.first Assistant.init
      , review = Nothing
      , estimate = Nothing
      , draft = Nothing
      , warnings = []
      , showAdditionalNutrients = False
      , units = []
      , nutrients = []
      , dateParam = dateParam
      , mealSlot = mealSlot
      , error = Nothing
      }
    , RequestAssistantStatus
    )


photoPreviewUrls : Model -> List String
photoPreviewUrls model =
    Assistant.previewUrls model.assistant


type Msg
    = AssistantMsg Assistant.Msg
    | ReviewMsg Review.Msg
    | UnitsLoaded (Result Client.ApiError Api.Foods.UnitListResponse)
    | NutrientsLoaded (Result Client.ApiError Api.Foods.NutrientListResponse)
    | AskForChangesClicked
    | ToggleAdditionalNutrients


type OutMsg
    = NoOp
    | RequestAssistantStatus
    | RequestFoodDraft FoodDraftPurpose Conversation (List File)
    | RevokePhotoPreviewUrls (List String)
    | RequestLocalContext
    | RequestAdHocLog CreateAdHocLogRequest
    | RequestCreateFood CreateFoodRequest
    | RequestCategorySuggestions Ticket CategorySuggestionRequest
    | RequestProductLog CreateLogRequest
    | LogCreated FoodLog
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        AssistantMsg subMsg ->
            let
                ( assistant, command, outMsg ) =
                    Assistant.updateFor AdHocLog subMsg model.assistant
            in
            applyAssistantOutMsg outMsg
                { model | assistant = assistant }
                (Cmd.map AssistantMsg command)

        ReviewMsg subMsg ->
            case model.review of
                Nothing ->
                    ( model, Cmd.none, NoOp )

                Just review ->
                    let
                        adjusted : Review.Model
                        adjusted =
                            case ( subMsg, model.draft ) of
                                ( Review.FormMsg (Editor.LogQuantityChanged amount), _ ) ->
                                    { review | form = Editor.changeLogQuantity amount review.form }

                                ( Review.FormMsg (Editor.LogUnitChanged unit), Just draft ) ->
                                    { review | form = Editor.changeLogUnit draft unit review.form }

                                _ ->
                                    review

                        ( next, command, outMsg ) =
                            Review.update subMsg adjusted
                    in
                    ( { model | review = Just next }
                    , Cmd.map ReviewMsg command
                    , mapReviewOutMsg outMsg
                    )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    let
                        units : List UnitItem
                        units =
                            case model.draft of
                                Just draft ->
                                    filterUnits draft response.items

                                Nothing ->
                                    response.items
                    in
                    hydrateReview (Review.UnitsLoaded (Ok { items = units }))
                        { model | units = response.items }

                Err error ->
                    ( { model | error = Just (Client.displayError error) }
                    , Cmd.none
                    , sessionOutMsg error
                    )

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    buildReview { model | nutrients = response.items }

                Err error ->
                    ( { model | error = Just (Client.displayError error) }
                    , Cmd.none
                    , sessionOutMsg error
                    )

        AskForChangesClicked ->
            let
                ( assistant, command, outMsg ) =
                    Assistant.updateFor AdHocLog Assistant.AskForChangesClicked model.assistant
            in
            applyAssistantOutMsg outMsg
                { model | assistant = assistant, review = Nothing }
                (Cmd.map AssistantMsg command)

        ToggleAdditionalNutrients ->
            ( { model | showAdditionalNutrients = not model.showAdditionalNutrients }
            , Cmd.none
            , NoOp
            )


hydrateReview : Review.Msg -> Model -> ( Model, Cmd Msg, OutMsg )
hydrateReview msg model =
    case model.review of
        Nothing ->
            ( model, Cmd.none, NoOp )

        Just review ->
            let
                ( next, command, outMsg ) =
                    Review.update msg review
            in
            ( { model | review = Just next }
            , Cmd.map ReviewMsg command
            , mapReviewOutMsg outMsg
            )


applyAssistantOutMsg :
    Assistant.OutMsg
    -> Model
    -> Cmd Msg
    -> ( Model, Cmd Msg, OutMsg )
applyAssistantOutMsg outMsg model command =
    case outMsg of
        Assistant.NoOutMsg ->
            ( model, command, NoOp )

        Assistant.RequestStatus ->
            ( model, command, RequestAssistantStatus )

        Assistant.RequestDraft purpose conversation photos ->
            ( model, command, RequestFoodDraft purpose conversation photos )

        Assistant.RevokePhotoPreviewUrls urls ->
            ( model, command, RevokePhotoPreviewUrls urls )

        Assistant.ApplyDraft _ ->
            ( model, command, NoOp )

        Assistant.CompleteDraft result ->
            buildReview
                { model
                    | estimate = Just result
                    , draft = Just result.draft
                    , warnings = result.warnings
                    , error = Nothing
                }

        Assistant.SessionExpired ->
            ( model, command, SessionExpired )


buildReview : Model -> ( Model, Cmd Msg, OutMsg )
buildReview model =
    case ( model.estimate, model.nutrients ) of
        ( Just result, _ :: _ ) ->
            let
                base : Review.Model
                base =
                    Review.init model.dateParam model.mealSlot
            in
            case
                Editor.applyAiLogDraft
                    model.nutrients
                    result.draft
                    result.suggestedLog
                    base.form
            of
                Ok form ->
                    ( { model
                        | review =
                            Just
                                { base
                                    | form = form
                                    , units = filterUnits result.draft model.units
                                    , nutrients = model.nutrients
                                }
                        , error = Nothing
                        , showAdditionalNutrients = False
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err message ->
                    ( { model | error = Just message }, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )


mapReviewOutMsg : Review.OutMsg -> OutMsg
mapReviewOutMsg outMsg =
    case outMsg of
        Review.NoOp ->
            NoOp

        Review.RequestLocalContext ->
            RequestLocalContext

        Review.RequestAdHocLog request ->
            RequestAdHocLog request

        Review.RequestCreateFood request ->
            RequestCreateFood request

        Review.RequestCategorySuggestions token request ->
            RequestCategorySuggestions token request

        Review.RequestProductLog request ->
            RequestProductLog request

        Review.LogCreated log ->
            LogCreated log

        Review.SessionExpired ->
            SessionExpired


filterUnits : FoodAssistant.FoodDraft -> List UnitItem -> List UnitItem
filterUnits draft =
    List.filter (\unit -> List.member unit.code (Editor.allowedLogUnitCodes draft))


sessionOutMsg : Client.ApiError -> OutMsg
sessionOutMsg error =
    if Client.isUnauthorized error then
        SessionExpired

    else
        NoOp


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    case model.review of
        Nothing ->
            UiPage.pageContainer device
                [ Feedback.maybeErrorBanner theme model.error
                , Element.map AssistantMsg
                    (Assistant.viewFor AdHocLog theme device False model.assistant)
                ]

        Just review ->
            UiPage.pageContainer device
                [ Typography.sectionTitle theme "Review food estimate"
                , Typography.mutedParagraph theme
                    "Nutrition values are totals for the entire portion you are logging."
                , warningView theme model.warnings
                , Button.textButton device
                    theme
                    { tone = Button.PrimaryOutline
                    , width = Button.FullWidth
                    , label = "Ask for changes"
                    , onPress = AskForChangesClicked
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                , additionalNutrientsToggle device theme model review
                , Element.map ReviewMsg
                    (Review.viewForAi model.showAdditionalNutrients
                        { model = review, device = device, theme = theme }
                    )
                ]


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView { model, device, theme } =
    Assistant.modalView theme device model.assistant
        |> Maybe.map (Element.map AssistantMsg)


additionalNutrientsToggle : Device -> Theme -> Model -> Review.Model -> Element Msg
additionalNutrientsToggle device theme model review =
    if List.any (not << isCoreNutrient << .code) review.form.nutrients then
        Button.textButton device
            theme
            { tone = Button.Ghost
            , width = Button.FullWidth
            , label =
                if model.showAdditionalNutrients then
                    "Hide additional nutrients"

                else
                    "Show additional nutrients"
            , onPress = ToggleAdditionalNutrients
            , submitState = Nothing
            , submittingLabel = Nothing
            , trailing = Nothing
            }

    else
        Element.none


isCoreNutrient : String -> Bool
isCoreNutrient code =
    List.member code [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]


warningView : Theme -> List String -> Element msg
warningView theme warnings =
    if List.isEmpty warnings then
        Element.none

    else
        Surface.formSection theme
            "Estimate notes"
            (List.map
                (\warning -> Typography.mutedParagraph theme ("Estimate: " ++ warning))
                warnings
            )
