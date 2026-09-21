module Page.Food.Search exposing
    ( BarcodeScannerState(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , QuickAddButtonState(..)
    , QuickAddState
    , RecentItemsResult
    , SearchScope(..)
    , contentView
    , init
    , quickAddChipState
    , retarget
    , update
    )

import Api.Client as Client
import Api.Foods as Foods
import Api.Logs as Logs
import Data.BarcodeScan exposing (ScannerEvent)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.LocalContext exposing (LocalContext)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search exposing (Completion, QueryState)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html exposing (Html)
import Html.Attributes
import Html.Events
import I18n
import Json.Decode as Decode
import Lib.Date as LocalDate
import Lib.Loadable exposing (Loadable(..))
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Process
import Task
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Icon as Icon
import Ui.Input as UiInput
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Product
import View.Search as SearchView



-- MODEL


type alias Model =
    { search : QueryState
    , scope : SearchScope
    , results : Loadable Client.ApiError (List Foods.SearchResult)
    , barcodeQuery : String
    , barcodeLookup : Loadable Client.ApiError Foods.ProductDetail
    , barcodeToken : Ticket
    , barcodeScanner : BarcodeScannerState
    , recentItems : Loadable Client.ApiError (List Logs.RecentItem)
    , date : Maybe String
    , mealSlot : Maybe MealSlot
    , quickAdd : QuickAddState
    , addedItems : List { key : String, token : Ticket }
    , addedToken : Ticket
    , completionIndex : Int
    }


type SearchScope
    = All
    | History
    | Custom
    | Barcode


type BarcodeScannerState
    = ScannerIdle
    | ScannerStarting
    | ScannerActive
    | ScannerFailed String


{-| What the barcode pane should render, derived once from the query, lookup,
and scanner state so the view never reconciles those three fields itself.
-}
type BarcodeBody
    = BarcodeScanInProgress
    | BarcodeAwaitingInput
    | BarcodeInputPending
    | BarcodeLookingUp
    | BarcodeNotFound
    | BarcodeLookupFailed Client.ApiError
    | BarcodeOpening


{-| Which body the search pane shows for the current scope.
-}
type SearchBody
    = RecentsBody
    | ResultsBody
    | BarcodeResultsBody BarcodeBody


{-| Whether the ad-hoc log section belongs on screen for the current state.
-}
type AdHocSection
    = AdHocShown
    | AdHocHidden


type QuickAddState
    = QuickAddIdle
    | QuickAddRequestingContext QuickAddTarget
    | QuickAddSubmitting QuickAddTarget
    | QuickAddFailed String


type alias QuickAddTarget =
    { item : Logs.RecentItem
    , quantity : Nutrition.Quantity
    }


type QuickAddButtonState
    = QuickAddCanAdd
    | QuickAddAdding
    | QuickAddBlocked
    | QuickAddAdded


init : Maybe String -> Maybe MealSlot -> Model
init date mealSlot =
    { search = Search.empty
    , scope = History
    , results = NotAsked
    , barcodeQuery = ""
    , barcodeLookup = NotAsked
    , barcodeToken = Ticket.initial
    , barcodeScanner = ScannerIdle
    , recentItems =
        case date |> Maybe.andThen LocalDate.fromString of
            Just _ ->
                Loading

            Nothing ->
                NotAsked
    , date = date
    , mealSlot = mealSlot
    , quickAdd = QuickAddIdle
    , addedItems = []
    , addedToken = Ticket.initial
    , completionIndex = -1
    }


retarget : Maybe String -> Maybe MealSlot -> Model -> ( Model, Bool )
retarget date mealSlot model =
    if model.date == date && model.mealSlot == mealSlot then
        ( model, False )

    else
        ( { model
            | date = date
            , mealSlot = mealSlot
            , recentItems =
                case date |> Maybe.andThen LocalDate.fromString of
                    Just _ ->
                        Loading

                    Nothing ->
                        NotAsked
            , quickAdd = QuickAddIdle
            , addedItems = []
          }
        , True
        )



-- UPDATE


type Msg
    = QueryChanged String
    | ScopeSelected SearchScope
    | BarcodeChanged String
    | BarcodeSubmitted
    | BarcodeScanClicked
    | BarcodeScanCancelClicked
    | BarcodeScannerEventReceived ScannerEvent
    | BarcodeLookupCompleted Ticket (Result Client.ApiError Foods.BarcodeLookupResponse)
    | CategorySuggestionsCompleted Ticket (Result Client.ApiError Foods.CategorySuggestionResponse)
    | CompleteFirstSuggestion
    | CompletionClicked Completion
    | CompletionActiveChanged Int
    | DebounceElapsed Ticket String
    | CategoryDebounceElapsed Ticket String
    | SearchCompleted Ticket (Result Client.ApiError Foods.SearchResponse)
    | RecentItemsLoaded (Maybe String) (Maybe MealSlot) RecentItemsResult
    | RecentQuickAddClicked Logs.RecentItem Nutrition.Quantity
    | RecentItemClicked Logs.RecentItem
    | LocalContextReceived LocalContext
    | QuickAddCompleted (Result Client.ApiError FoodLog)
    | ClearRecentAdded String Ticket
    | ResultClicked String
    | CreateAdHocLogClicked
    | CreateAiLogClicked


type alias RecentItemsResult =
    Result Client.ApiError Logs.RecentItemsResponse


type OutMsg
    = NoOp
    | RequestSearch Ticket Foods.SearchRequest
    | RequestBarcodeScanStopAndSearch Ticket Foods.SearchRequest
    | RequestBarcodeLookup Ticket String
    | RequestBarcodeScanStart
    | RequestBarcodeScanStop
    | RequestCategorySuggestions Ticket Foods.CategorySuggestionRequest
    | RequestLocalContext
    | RequestCreateLog Logs.CreateLogRequest
    | LogCreated FoodLog
    | Navigate Route
    | SessionExpired


debounceConfig : Search.Debounce Msg
debounceConfig =
    { delayMs = 300
    , onSearchElapsed = DebounceElapsed
    , onCategoryElapsed = CategoryDebounceElapsed
    }


categorySuggestionsLimit : Int
categorySuggestionsLimit =
    8


applyQueryChange : String -> Model -> ( Model, Cmd Msg, OutMsg )
applyQueryChange rawQuery model =
    let
        ( search, debounceCmd ) =
            Search.onQueryChangedDebounced rawQuery model.search debounceConfig

        results : Loadable Client.ApiError (List Foods.SearchResult)
        results =
            if String.isEmpty (String.trim rawQuery) then
                NotAsked

            else
                Loading
    in
    ( { model | search = search, results = results, completionIndex = -1 }
    , debounceCmd
    , NoOp
    )


applyScopeChange : SearchScope -> Model -> ( Model, Cmd Msg, OutMsg )
applyScopeChange scope model =
    if scope == model.scope then
        ( model, Cmd.none, NoOp )

    else
        let
            leavingBarcode : Bool
            leavingBarcode =
                model.scope == Barcode && scope /= Barcode

            query : String
            query =
                String.trim model.search.query

            priorSearch : QueryState
            priorSearch =
                model.search

            nextSearch : QueryState
            nextSearch =
                { priorSearch
                    | searchToken = Ticket.next priorSearch.searchToken

                    -- Bumping the category token invalidates both a pending
                    -- suggestion debounce and an already in-flight response, so
                    -- neither can repopulate the list after the scope changed.
                    , categoryToken = Ticket.next priorSearch.categoryToken
                    , categorySuggestions = []
                }

            nextModel : Model
            nextModel =
                { model
                    | scope = scope
                    , search = nextSearch
                    , results =
                        if isTextScope scope && not (String.isEmpty query) then
                            Loading

                        else
                            NotAsked
                    , barcodeLookup = NotAsked
                    , barcodeToken = Ticket.next model.barcodeToken
                    , barcodeScanner =
                        if leavingBarcode then
                            ScannerIdle

                        else
                            model.barcodeScanner
                }
        in
        if isTextScope scope && not (String.isEmpty query) then
            ( nextModel
            , Cmd.none
            , if leavingBarcode then
                RequestBarcodeScanStopAndSearch nextSearch.searchToken
                    { query = query, scope = searchRequestScope scope }

              else
                RequestSearch nextSearch.searchToken
                    { query = query, scope = searchRequestScope scope }
            )

        else if leavingBarcode then
            ( nextModel, Cmd.none, RequestBarcodeScanStop )

        else
            ( nextModel, Cmd.none, NoOp )


applyBarcodeSubmit : Model -> ( Model, Cmd Msg, OutMsg )
applyBarcodeSubmit model =
    let
        barcode : String
        barcode =
            String.trim model.barcodeQuery

        nextToken : Ticket
        nextToken =
            Ticket.next model.barcodeToken
    in
    if String.isEmpty barcode then
        ( { model | barcodeLookup = NotAsked, barcodeToken = nextToken }
        , Cmd.none
        , NoOp
        )

    else
        ( { model | barcodeLookup = Loading, barcodeToken = nextToken }
        , Cmd.none
        , RequestBarcodeLookup nextToken barcode
        )


{-| Starting a scan clears any previous lookup and invalidates its in-flight
response, so a stale not-found result cannot resurface behind the camera.
-}
startScanner : Model -> ( Model, Cmd Msg, OutMsg )
startScanner model =
    ( { model
        | barcodeScanner = ScannerStarting
        , barcodeLookup = NotAsked
        , barcodeToken = Ticket.next model.barcodeToken
      }
    , Cmd.none
    , RequestBarcodeScanStart
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
            applyQueryChange rawQuery model

        CompletionActiveChanged index ->
            ( { model | completionIndex = index }, Cmd.none, NoOp )

        ScopeSelected scope ->
            applyScopeChange scope model

        BarcodeChanged rawBarcode ->
            ( { model
                | barcodeQuery = rawBarcode
                , barcodeLookup =
                    if String.isEmpty (String.trim rawBarcode) then
                        NotAsked

                    else
                        model.barcodeLookup
              }
            , Cmd.none
            , NoOp
            )

        BarcodeSubmitted ->
            applyBarcodeSubmit model

        BarcodeScanClicked ->
            case model.barcodeScanner of
                ScannerStarting ->
                    ( model, Cmd.none, NoOp )

                ScannerActive ->
                    ( model, Cmd.none, NoOp )

                ScannerIdle ->
                    startScanner model

                ScannerFailed _ ->
                    startScanner model

        BarcodeScanCancelClicked ->
            ( { model | barcodeScanner = ScannerIdle }
            , Cmd.none
            , RequestBarcodeScanStop
            )

        BarcodeScannerEventReceived event ->
            applyBarcodeScannerEvent event model

        BarcodeLookupCompleted token result ->
            if token /= model.barcodeToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model | barcodeLookup = Success response.product }
                        , Cmd.none
                        , Navigate
                            (FoodShow
                                response.product.id
                                model.date
                                model.mealSlot
                                response.lookup.note
                            )
                        )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | barcodeLookup = Failure error }
                            , Cmd.none
                            , SessionExpired
                            )

                        else
                            ( { model | barcodeLookup = Failure error }
                            , Cmd.none
                            , NoOp
                            )

        CategorySuggestionsCompleted token result ->
            if token /= model.search.categoryToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model
                            | search =
                                Search.setCategorySuggestions
                                    token
                                    response.items
                                    model.search
                          }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model
                                | search =
                                    Search.setCategorySuggestions token [] model.search
                              }
                            , Cmd.none
                            , SessionExpired
                            )

                        else
                            ( { model
                                | search =
                                    Search.setCategorySuggestions token [] model.search
                              }
                            , Cmd.none
                            , NoOp
                            )

        CompleteFirstSuggestion ->
            case
                List.head
                    (Search.completions model.search.query model.search.categorySuggestions)
            of
                Just completion ->
                    applyQueryChange
                        (Search.applyCompletion completion model.search.query)
                        model

                Nothing ->
                    ( model, Cmd.none, NoOp )

        CompletionClicked completion ->
            applyQueryChange
                (Search.applyCompletion completion model.search.query)
                model

        DebounceElapsed token query ->
            if token == model.search.searchToken then
                ( model
                , Cmd.none
                , RequestSearch token
                    { query = query, scope = searchRequestScope model.scope }
                )

            else
                ( model, Cmd.none, NoOp )

        CategoryDebounceElapsed token query ->
            if token == model.search.categoryToken then
                ( model
                , Cmd.none
                , RequestCategorySuggestions token
                    { query = query, limit = categorySuggestionsLimit }
                )

            else
                ( model, Cmd.none, NoOp )

        SearchCompleted token result ->
            if token /= model.search.searchToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model | results = Success response.items }, Cmd.none, NoOp )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | results = Failure error }, Cmd.none, SessionExpired )

                        else
                            ( { model | results = Failure error }, Cmd.none, NoOp )

        RecentItemsLoaded date mealSlot result ->
            if model.date /= date || model.mealSlot /= mealSlot then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model | recentItems = Success (List.take 10 response.items) }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | recentItems = Failure error }
                            , Cmd.none
                            , SessionExpired
                            )

                        else
                            ( { model | recentItems = Failure error }, Cmd.none, NoOp )

        RecentQuickAddClicked item quantity ->
            if canStartQuickAdd model.quickAdd then
                ( { model
                    | quickAdd =
                        QuickAddRequestingContext { item = item, quantity = quantity }
                  }
                , Cmd.none
                , RequestLocalContext
                )

            else
                ( model, Cmd.none, NoOp )

        RecentItemClicked item ->
            case item.item of
                FoodLog.ProductLogItem product ->
                    ( model
                    , Cmd.none
                    , Navigate (FoodShow product.id model.date model.mealSlot Nothing)
                    )

                FoodLog.MealLogItem meal ->
                    ( model, Cmd.none, Navigate (MealShow meal.id) )

                FoodLog.AdHocLogItem _ ->
                    ( model, Cmd.none, NoOp )

        LocalContextReceived context ->
            case model.quickAdd of
                QuickAddRequestingContext target ->
                    case quickAddRequest context model target of
                        Just request ->
                            ( { model | quickAdd = QuickAddSubmitting target }
                            , Cmd.none
                            , RequestCreateLog request
                            )

                        Nothing ->
                            ( { model
                                | quickAdd =
                                    QuickAddFailed
                                        (I18n.en TidFoodSearchErrorCouldNotReadDate)
                              }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        QuickAddCompleted result ->
            case result of
                Ok log ->
                    let
                        key : Maybe String
                        key =
                            quickAddTarget model.quickAdd
                                |> Maybe.map quickAddTargetKey

                        nextToken : Ticket
                        nextToken =
                            Ticket.next model.addedToken
                    in
                    ( { model
                        | quickAdd = QuickAddIdle
                        , addedToken = nextToken
                        , addedItems =
                            case key of
                                Just value ->
                                    { key = value, token = nextToken }
                                        :: List.filter
                                            (\addedItem -> addedItem.key /= value)
                                            model.addedItems

                                Nothing ->
                                    model.addedItems
                      }
                    , case key of
                        Just value ->
                            clearRecentAddedAfter value nextToken

                        Nothing ->
                            Cmd.none
                    , LogCreated log
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | quickAdd = QuickAddIdle
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | quickAdd =
                                QuickAddFailed (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        ClearRecentAdded key token ->
            ( { model
                | addedItems =
                    List.filter
                        (\addedItem ->
                            addedItem.key /= key || addedItem.token /= token
                        )
                        model.addedItems
              }
            , Cmd.none
            , NoOp
            )

        ResultClicked id ->
            ( model, Cmd.none, Navigate (FoodShow id model.date model.mealSlot Nothing) )

        CreateAdHocLogClicked ->
            ( model
            , Cmd.none
            , Navigate (AdHocLogCreate model.date model.mealSlot)
            )

        CreateAiLogClicked ->
            ( model
            , Cmd.none
            , Navigate (AiLogCreate model.date model.mealSlot)
            )


applyBarcodeScannerEvent :
    { event : String, barcode : Maybe String, message : Maybe String }
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
applyBarcodeScannerEvent event model =
    case event.event of
        "started" ->
            ( { model | barcodeScanner = ScannerActive }, Cmd.none, NoOp )

        "stopped" ->
            ( { model | barcodeScanner = ScannerIdle }, Cmd.none, NoOp )

        "failed" ->
            ( { model
                | barcodeScanner =
                    ScannerFailed
                        (Maybe.withDefault
                            (I18n.en TidFoodSearchErrorScannerStart)
                            event.message
                        )
              }
            , Cmd.none
            , NoOp
            )

        "detected" ->
            case event.barcode |> Maybe.map String.trim of
                Just barcode ->
                    if String.isEmpty barcode then
                        ( model, Cmd.none, NoOp )

                    else
                        applyBarcodeSubmit
                            { model
                                | barcodeQuery = barcode
                                , barcodeScanner = ScannerIdle
                            }

                Nothing ->
                    ( model, Cmd.none, NoOp )

        _ ->
            ( model, Cmd.none, NoOp )


quickAddRequest :
    LocalContext
    -> Model
    -> QuickAddTarget
    -> Maybe Logs.CreateLogRequest
quickAddRequest context model target =
    let
        rawDate : String
        rawDate =
            Maybe.withDefault context.date model.date
    in
    LocalDate.fromString rawDate
        |> Maybe.map
            (\logDate ->
                FoodLog.itemRef target.item.item
                    |> Maybe.map
                        (\item ->
                            { logDate = logDate
                            , deviceTimezone = Just context.timezone
                            , mealSlot = Maybe.map MealSlot.toString model.mealSlot
                            , item = item
                            , quantity = target.quantity
                            , notes = Nothing
                            }
                        )
            )
        |> Maybe.andThen identity


recentItemKey : Logs.RecentItem -> Nutrition.Quantity -> String
recentItemKey item quantity =
    FoodLog.itemRef item.item
        |> Maybe.map
            (\ref -> ItemRef.itemTypeToString ref.itemType ++ ":" ++ ref.id)
        |> Maybe.withDefault "ad-hoc"
        |> (\key -> key ++ ":" ++ Nutrition.quantityText quantity)


quickAddTargetKey : QuickAddTarget -> String
quickAddTargetKey target =
    recentItemKey target.item target.quantity


quickAddTarget : QuickAddState -> Maybe QuickAddTarget
quickAddTarget quickAdd =
    case quickAdd of
        QuickAddIdle ->
            Nothing

        QuickAddRequestingContext target ->
            Just target

        QuickAddSubmitting target ->
            Just target

        QuickAddFailed _ ->
            Nothing


quickAddAddingKey : QuickAddState -> Maybe String
quickAddAddingKey quickAdd =
    quickAdd
        |> quickAddTarget
        |> Maybe.map quickAddTargetKey


quickAddError : QuickAddState -> Maybe String
quickAddError quickAdd =
    case quickAdd of
        QuickAddFailed error ->
            Just error

        _ ->
            Nothing


canStartQuickAdd : QuickAddState -> Bool
canStartQuickAdd quickAdd =
    case quickAdd of
        QuickAddRequestingContext _ ->
            False

        QuickAddSubmitting _ ->
            False

        QuickAddIdle ->
            True

        QuickAddFailed _ ->
            True


clearRecentAddedAfter : String -> Ticket -> Cmd Msg
clearRecentAddedAfter key token =
    Process.sleep 500
        |> Task.perform (\_ -> ClearRecentAdded key token)



-- VIEW


contentView : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
contentView { model, device, theme, language } =
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.spacing DesignTokens.space24
        ]
        (searchInputView theme device language model
            :: searchContentView theme device language model
            :: adHocLogSection theme device language model
        )


searchBody : Model -> SearchBody
searchBody model =
    case model.scope of
        Barcode ->
            BarcodeResultsBody (barcodeBody model)

        _ ->
            textSearchBody model


textSearchBody : Model -> SearchBody
textSearchBody model =
    if not (String.isEmpty (String.trim model.search.query)) then
        ResultsBody

    else
        case model.results of
            NotAsked ->
                RecentsBody

            Loading ->
                ResultsBody

            Failure _ ->
                ResultsBody

            Success _ ->
                ResultsBody


barcodeBody : Model -> BarcodeBody
barcodeBody model =
    case model.barcodeScanner of
        ScannerStarting ->
            BarcodeScanInProgress

        ScannerActive ->
            BarcodeScanInProgress

        ScannerIdle ->
            barcodeLookupBody model

        ScannerFailed _ ->
            barcodeLookupBody model


barcodeLookupBody : Model -> BarcodeBody
barcodeLookupBody model =
    case model.barcodeLookup of
        Loading ->
            BarcodeLookingUp

        Success _ ->
            BarcodeOpening

        Failure error ->
            case error of
                Client.BadStatus 404 _ _ ->
                    BarcodeNotFound

                _ ->
                    BarcodeLookupFailed error

        NotAsked ->
            if String.isEmpty (String.trim model.barcodeQuery) then
                BarcodeAwaitingInput

            else
                BarcodeInputPending


{-| The ad-hoc log actions are always reachable for text scopes, but the
barcode pane only offers them once a lookup has genuinely found nothing.
-}
adHocSection : Model -> AdHocSection
adHocSection model =
    case searchBody model of
        BarcodeResultsBody BarcodeNotFound ->
            AdHocShown

        BarcodeResultsBody _ ->
            AdHocHidden

        RecentsBody ->
            AdHocShown

        ResultsBody ->
            AdHocShown


adHocLogSection : Theme -> Device -> Language -> Model -> List (Element Msg)
adHocLogSection theme device language model =
    case adHocSection model of
        AdHocShown ->
            [ adHocLogView theme device language ]

        AdHocHidden ->
            []


adHocLogView : Theme -> Device -> Language -> Element Msg
adHocLogView theme device language =
    Surface.formSection theme
        (I18n.t language TidFoodSearchAdHocTitle)
        [ Typography.mutedParagraph theme
            (I18n.t language TidFoodSearchAdHocDescription)
        , Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Element.el [ Element.width Element.fill ]
                (Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t language TidTitleCreateWithAi
                    , onPress = CreateAiLogClicked
                    , submitState = Just Button.Idle
                    , submittingLabel = Just (I18n.t language TidTitleCreateWithAi)
                    , trailing = Nothing
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Button.textButton device
                    theme
                    { tone = Button.PrimaryOutline
                    , width = Button.FullWidth
                    , label = I18n.t language TidFoodSearchEnterManually
                    , onPress = CreateAdHocLogClicked
                    , submitState = Just Button.Idle
                    , submittingLabel = Just (I18n.t language TidFoodSearchEnterManually)
                    , trailing = Nothing
                    }
                )
            ]
        ]


searchInputView : Theme -> Device -> Language -> Model -> Element Msg
searchInputView theme device language model =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space24 ]
        [ scopeControl theme language model.scope
        , if model.scope == Barcode then
            barcodeInputView theme device language model

          else
            textSearchInputView theme device language model
        ]


textSearchInputView : Theme -> Device -> Language -> Model -> Element Msg
textSearchInputView theme device language model =
    let
        options : List Completion
        options =
            Search.completions model.search.query model.search.categorySuggestions
    in
    SearchView.searchInput theme
        device
        { id = "food-search-completions"
        , onChange = QueryChanged
        , text = model.search.query
        , label = UiInput.LabelInside (searchLabel language model.scope)
        , completions = options
        , activeIndex = model.completionIndex
        , onActiveChanged = CompletionActiveChanged
        , onTabComplete = CompleteFirstSuggestion
        , onCompletionClick = CompletionClicked
        }


barcodeInputView : Theme -> Device -> Language -> Model -> Element Msg
barcodeInputView theme device language model =
    let
        input : Element Msg
        input =
            UiInput.searchInput theme
                { onChange = BarcodeChanged
                , text = model.barcodeQuery
                , label = UiInput.LabelInside (I18n.t language TidFoodSearchEnterBarcode)
                , extraAttrs = [ onEnterSubmit BarcodeSubmitted, UiInput.numericInputMode ]
                }

        searchButton : Element Msg
        searchButton =
            Button.textButton device
                theme
                { tone = Button.PrimaryOutline
                , width = Button.FullWidth
                , label = I18n.t language TidNavSearch
                , onPress = BarcodeSubmitted
                , submitState =
                    Just
                        (if model.barcodeLookup == Loading then
                            Button.Submitting

                         else if String.isEmpty (String.trim model.barcodeQuery) then
                            Button.Disabled

                         else
                            Button.Idle
                        )
                , submittingLabel = Just (I18n.t language TidFoodSearchSearching)
                , trailing = Nothing
                }

        scanButton : Element Msg
        scanButton =
            case model.barcodeScanner of
                ScannerStarting ->
                    Button.textButton device
                        theme
                        { tone = Button.Primary
                        , width = Button.FullWidth
                        , label = I18n.t language TidFoodSearchScan
                        , onPress = BarcodeScanClicked
                        , submitState = Just Button.Submitting
                        , submittingLabel = Just (I18n.t language TidFoodSearchStarting)
                        , trailing = Nothing
                        }

                ScannerActive ->
                    Button.textButton device
                        theme
                        { tone = Button.Danger
                        , width = Button.FullWidth
                        , label = I18n.t language TidCommonCancel
                        , onPress = BarcodeScanCancelClicked
                        , submitState = Nothing
                        , submittingLabel = Nothing
                        , trailing = Nothing
                        }

                _ ->
                    Button.textButton device
                        theme
                        { tone = Button.Primary
                        , width = Button.FullWidth
                        , label = I18n.t language TidFoodSearchScan
                        , onPress = BarcodeScanClicked
                        , submitState = Just Button.Idle
                        , submittingLabel = Just (I18n.t language TidFoodSearchStarting)
                        , trailing = Nothing
                        }

        controls : Element Msg
        controls =
            Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ scanButton, searchButton ]

        inputRow : Element Msg
        inputRow =
            Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ input, controls ]
    in
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        (inputRow :: barcodeScannerStateView theme language model.barcodeScanner)


barcodeScannerStateView : Theme -> Language -> BarcodeScannerState -> List (Element Msg)
barcodeScannerStateView theme language scanner =
    case scanner of
        ScannerIdle ->
            []

        ScannerFailed message ->
            [ Feedback.errorBanner theme message ]

        ScannerStarting ->
            [ barcodeScannerPreview theme (I18n.t language TidFoodSearchStartingCamera) ]

        ScannerActive ->
            [ barcodeScannerPreview theme (I18n.t language TidFoodSearchCenterBarcode) ]


barcodeScannerPreview : Theme -> String -> Element Msg
barcodeScannerPreview theme caption =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        , Element.padding DesignTokens.space8
        , Background.color theme.cardSurfaceBg
        , Border.width 1
        , Border.color theme.chipBorder
        , Border.rounded DesignTokens.radiusCard
        ]
        [ Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 380)
            , Border.rounded DesignTokens.radiusCard
            , Element.clip
            , Background.color theme.mediaBackdrop
            , Element.inFront (barcodeScannerGuide theme)
            ]
            (Element.html barcodeScannerVideo)
        , Typography.mutedCaptionParagraph theme caption
        ]


barcodeScannerGuide : Theme -> Element Msg
barcodeScannerGuide theme =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.paddingXY DesignTokens.space16 0
        ]
        (Element.el
            [ Element.centerY
            , Element.width Element.fill
            , Element.height (Element.px 96)
            , Border.rounded DesignTokens.radiusControl
            , Border.color theme.focusRing
            , Border.widthEach
                { top = 2
                , right = 0
                , bottom = 2
                , left = 0
                }
            ]
            Element.none
        )


barcodeScannerVideo : Html Msg
barcodeScannerVideo =
    Html.video
        [ Html.Attributes.id barcodeScannerVideoId
        , Html.Attributes.attribute "autoplay" ""
        , Html.Attributes.attribute "playsinline" ""
        , Html.Attributes.attribute "muted" ""
        , Html.Attributes.style "display" "block"
        , Html.Attributes.style "width" "100%"
        , Html.Attributes.style "height" "100%"
        , Html.Attributes.style "object-fit" "contain"
        ]
        []


barcodeScannerVideoId : String
barcodeScannerVideoId =
    "calco-barcode-scanner-video"


scopeControl : Theme -> Language -> SearchScope -> Element Msg
scopeControl theme language selectedScope =
    Element.row
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space4
        , Element.padding DesignTokens.space4
        , Background.color theme.inputFill
        , Border.width 1
        , Border.color theme.chipBorder
        , Border.rounded DesignTokens.radiusControl
        ]
        (List.map (scopeSegment theme language selectedScope) searchScopes)


scopeSegment : Theme -> Language -> SearchScope -> SearchScope -> Element Msg
scopeSegment theme language selectedScope scope =
    let
        selected : Bool
        selected =
            scope == selectedScope

        foreground : Element.Color
        foreground =
            if selected then
                Element.rgb255 255 255 255

            else
                theme.textMedium

        background : Element.Color
        background =
            if selected then
                theme.brandBlue

            else
                theme.inputFill
    in
    Input.button
        [ Element.width (Element.fillPortion 1)
        , Element.height (Element.px DesignTokens.minimumTargetSize)
        , Background.color background
        , Border.rounded DesignTokens.radiusControl
        , Font.color foreground
        , Font.medium
        , Typography.caption
        , UiCommon.uiClass "ui-motion ui-pressable"
        , if selected then
            Element.mouseOver []

          else
            Element.mouseOver [ Background.color theme.brandBlueSoft ]
        ]
        { onPress = Just (ScopeSelected scope)
        , label =
            Element.el
                [ Element.centerX
                , Element.centerY
                , Element.clip
                , UiCommon.uiClass "ui-text-ellipsis"
                ]
                (Element.text (scopeLabel language scope))
        }


bodyView : Theme -> Language -> Model -> Device -> Element Msg
bodyView theme language model device =
    case model.results of
        NotAsked ->
            Feedback.emptyState theme (I18n.t language TidFoodSearchEmptyPrompt)

        Loading ->
            Surface.section theme
                { header =
                    Just
                        (Skeleton.barCustom theme
                            { width = Element.px 120, height = 24 }
                        )
                , body =
                    List.map (\_ -> Skeleton.listRow theme)
                        (List.range 1 3)
                , footer = Nothing
                }

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ Feedback.errorBanner theme (Client.displayError error)
                , Feedback.emptyState theme (I18n.t language TidFoodSearchNoFoods)
                ]

        Success items ->
            if List.isEmpty items then
                textEmptyState theme language model.scope

            else
                Surface.section theme
                    { header =
                        Just
                            (Typography.subsectionTitle
                                theme
                                (I18n.t language TidFoodSearchResults)
                            )
                    , body =
                        List.map
                            (\item ->
                                SearchView.resultRow theme
                                    language
                                    device
                                    { query = model.search.query
                                    , item = item
                                    , onSelect = ResultClicked
                                    }
                            )
                            items
                    , footer = Nothing
                    }


searchContentView : Theme -> Device -> Language -> Model -> Element Msg
searchContentView theme device language model =
    case searchBody model of
        RecentsBody ->
            recentsView device theme language model

        ResultsBody ->
            bodyView theme language model device

        BarcodeResultsBody body ->
            barcodeBodyView theme language body


barcodeBodyView : Theme -> Language -> BarcodeBody -> Element Msg
barcodeBodyView theme language body =
    case body of
        BarcodeScanInProgress ->
            Element.none

        BarcodeAwaitingInput ->
            Feedback.emptyState theme (I18n.t language TidFoodSearchEnterBarcodePrompt)

        BarcodeInputPending ->
            Element.none

        BarcodeLookingUp ->
            Skeleton.card theme { rows = 3 }

        BarcodeNotFound ->
            Feedback.emptyStateWithIcon theme
                { icon = Icon.SearchX
                , message = I18n.t language TidFoodSearchBarcodeNotFound
                }

        BarcodeLookupFailed error ->
            Feedback.errorBanner theme (Client.displayError error)

        BarcodeOpening ->
            Feedback.emptyState theme (I18n.t language TidFoodSearchOpeningFood)


textEmptyState : Theme -> Language -> SearchScope -> Element Msg
textEmptyState theme language scope =
    Feedback.emptyStateWithIcon theme
        { icon = Icon.SearchX
        , message =
            case scope of
                History ->
                    I18n.t language TidFoodSearchNoLoggedFoods

                Custom ->
                    I18n.t language TidFoodSearchNoCustomFoods

                _ ->
                    I18n.t language TidFoodSearchNoFoods
        }


searchScopes : List SearchScope
searchScopes =
    [ All, History, Custom, Barcode ]


scopeLabel : Language -> SearchScope -> String
scopeLabel language scope =
    case scope of
        All ->
            I18n.t language TidFoodSearchScopeAll

        History ->
            I18n.t language TidFoodSearchScopeHistory

        Custom ->
            I18n.t language TidFoodSearchScopeCustom

        Barcode ->
            I18n.t language TidFoodSearchScopeBarcode


searchLabel : Language -> SearchScope -> String
searchLabel language scope =
    case scope of
        All ->
            I18n.t language TidFoodSearchPromptAll

        History ->
            I18n.t language TidFoodSearchPromptHistory

        Custom ->
            I18n.t language TidFoodSearchPromptCustom

        Barcode ->
            I18n.t language TidFoodSearchEnterBarcode


isTextScope : SearchScope -> Bool
isTextScope scope =
    scope /= Barcode


searchRequestScope : SearchScope -> Foods.SearchScope
searchRequestScope scope =
    case scope of
        History ->
            Foods.SearchHistory

        Custom ->
            Foods.SearchCustom

        _ ->
            Foods.SearchAll


onEnterSubmit : msg -> Element.Attribute msg
onEnterSubmit submitMsg =
    Element.htmlAttribute
        (Html.Events.preventDefaultOn "keydown"
            (Decode.field "key" Decode.string
                |> Decode.andThen
                    (\key ->
                        if key == "Enter" then
                            Decode.succeed ( submitMsg, True )

                        else
                            Decode.fail "not handled"
                    )
            )
        )


recentsView : Device -> Theme -> Language -> Model -> Element Msg
recentsView device theme language model =
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.spacing DesignTokens.space8
        ]
        [ Feedback.maybeErrorBanner theme (quickAddError model.quickAdd)
        , case model.recentItems of
            NotAsked ->
                noRecentsState theme language

            Loading ->
                Skeleton.card theme { rows = 2 }

            Failure _ ->
                Element.none

            Success items ->
                if List.isEmpty items then
                    noRecentsState theme language

                else
                    Element.column
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ Surface.section theme
                            { header =
                                Just
                                    (Typography.sectionTitle
                                        theme
                                        (I18n.t language TidFoodSearchRecent)
                                    )
                            , body =
                                List.map (recentItemRow device theme language model) items
                            , footer = Nothing
                            }
                        ]
        ]


noRecentsState : Theme -> Language -> Element Msg
noRecentsState theme language =
    Feedback.emptyStateWithIcon theme
        { icon = Icon.Utensils
        , message = I18n.t language TidFoodSearchNoRecents
        }


recentItemRow : Device -> Theme -> Language -> Model -> Logs.RecentItem -> Element Msg
recentItemRow device theme language model item =
    Element.column [ Element.width Element.fill ]
        [ Surface.listRow
            { onSelect = RecentItemClicked item
            , leading = [ View.Product.macroDotGhost ]
            , title = Typography.wrappedListItemTitle theme (FoodLog.itemName item.item)
            , subtitle =
                [ Typography.mutedCaptionParagraph theme
                    (Text.dotSeparated
                        [ FoodLog.itemBrand item.item
                        , Nutrition.servingCaloriesText item
                        ]
                    )
                ]
            , trailing = []
            }

        -- Quick-add chips sit outside `Surface.listRow`, whose subtitle slot is
        -- inside the row-select button and cannot hold nested buttons.
        , quickAddChipRow device theme language model item
        ]


quickAddChipRow : Device -> Theme -> Language -> Model -> Logs.RecentItem -> Element Msg
quickAddChipRow device theme language model item =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        , Element.paddingEach
            { top = 0
            , right = DesignTokens.space16
            , bottom = DesignTokens.space16
            , left = DesignTokens.space16
            }
        ]
        (List.map (quickAddChip device theme language model item) (quickAddQuantities item))


quickAddQuantities : Logs.RecentItem -> List Nutrition.Quantity
quickAddQuantities item =
    case List.map .quantity item.topQuantities of
        [] ->
            [ item.quantity ]

        quantities ->
            quantities


quickAddChipState : Model -> Logs.RecentItem -> Nutrition.Quantity -> QuickAddButtonState
quickAddChipState model item quantity =
    let
        key : String
        key =
            recentItemKey item quantity
    in
    if quickAddAddingKey model.quickAdd == Just key then
        QuickAddAdding

    else if not (canStartQuickAdd model.quickAdd) then
        -- A sibling chip is mid-flight, so this tap would be dropped by the
        -- `canStartQuickAdd` guard. Show that the chip is unavailable instead.
        QuickAddBlocked

    else if List.any (\addedItem -> addedItem.key == key) model.addedItems then
        QuickAddAdded

    else
        QuickAddCanAdd


quickAddChip :
    Device
    -> Theme
    -> Language
    -> Model
    -> Logs.RecentItem
    -> Nutrition.Quantity
    -> Element Msg
quickAddChip device theme language model item quantity =
    let
        state : QuickAddButtonState
        state =
            quickAddChipState model item quantity

        label : String
        label =
            "+ " ++ Nutrition.quantityText quantity

        ( tone, submitState, submittingLabel ) =
            case state of
                QuickAddCanAdd ->
                    ( Button.GhostFilled, Nothing, Nothing )

                QuickAddAdding ->
                    ( Button.GhostFilled
                    , Just Button.Submitting
                    , Just (I18n.t language TidFoodSearchAdding)
                    )

                QuickAddAdded ->
                    ( Button.Primary, Just Button.Submitted, Nothing )

                QuickAddBlocked ->
                    ( Button.GhostFilled, Just Button.Disabled, Nothing )
    in
    Button.textButton device
        theme
        { tone = tone
        , width = Button.ContentWidth
        , label = label
        , onPress = RecentQuickAddClicked item quantity
        , submitState = submitState
        , submittingLabel = submittingLabel
        , trailing = Nothing
        }
