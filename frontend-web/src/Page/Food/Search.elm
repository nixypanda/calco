module Page.Food.Search exposing
    ( BarcodeScannerState(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , QuickAddState
    , SearchScope(..)
    , contentView
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods
import Api.Logs as Logs
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
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
import Json.Decode as Decode
import Lib.Date as LocalDate
import Lib.Loadable exposing (Loadable(..))
import Process
import Task
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon exposing (Icon)
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
    , barcodeToken : Int
    , barcodeScanner : BarcodeScannerState
    , recentItems : Loadable Client.ApiError (List Logs.RecentItem)
    , date : Maybe String
    , mealSlot : Maybe MealSlot
    , quickAdd : QuickAddState
    , addedItems : List { key : String, token : Int }
    , addedToken : Int
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


type QuickAddState
    = QuickAddIdle
    | QuickAddRequestingContext Logs.RecentItem
    | QuickAddSubmitting Logs.RecentItem
    | QuickAddFailed String


type QuickAddButtonState
    = QuickAddCanAdd
    | QuickAddAdding
    | QuickAddAdded


init : Maybe String -> Maybe MealSlot -> Model
init date mealSlot =
    { search = Search.empty
    , scope = All
    , results = NotAsked
    , barcodeQuery = ""
    , barcodeLookup = NotAsked
    , barcodeToken = 0
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
    , addedToken = 0
    }



-- UPDATE


type Msg
    = QueryChanged String
    | ScopeSelected SearchScope
    | BarcodeChanged String
    | BarcodeSubmitted
    | BarcodeScanClicked
    | BarcodeScanCancelClicked
    | BarcodeScannerEventReceived { event : String, barcode : Maybe String, message : Maybe String }
    | BarcodeLookupCompleted Int (Result Client.ApiError Foods.ProductDetail)
    | CategorySuggestionsCompleted Int (Result Client.ApiError Foods.CategorySuggestionResponse)
    | CompleteFirstSuggestion
    | CompletionClicked Completion
    | DebounceElapsed Int String
    | SearchCompleted Int (Result Client.ApiError Foods.SearchResponse)
    | RecentItemsLoaded (Result Client.ApiError Logs.RecentItemsResponse)
    | RecentQuickAddClicked Logs.RecentItem
    | RecentItemClicked Logs.RecentItem
    | LocalContextReceived { date : String, timezone : String }
    | QuickAddCompleted (Result Client.ApiError FoodLog)
    | ClearRecentAdded String Int
    | ResultClicked String
    | CreateCustomFoodClicked


type OutMsg
    = NoOp
    | RequestSearch Int Foods.SearchRequest
    | RequestBarcodeScanStopAndSearch Int Foods.SearchRequest
    | RequestBarcodeLookup Int String
    | RequestBarcodeScanStart
    | RequestBarcodeScanStop
    | RequestCategorySuggestions Int Foods.CategorySuggestionRequest
    | RequestLocalContext
    | RequestCreateLog Logs.CreateLogRequest
    | Navigate Route
    | SessionExpired


debounceConfig : { delayMs : Int, onFire : Int -> String -> Msg }
debounceConfig =
    { delayMs = 300
    , onFire = DebounceElapsed
    }


applyQueryChange : String -> Model -> ( Model, Cmd Msg, OutMsg )
applyQueryChange rawQuery model =
    let
        ( search, debounceCmd, categoryReq ) =
            Search.onQueryChanged rawQuery model.search (Just debounceConfig)

        results : Loadable Client.ApiError (List Foods.SearchResult)
        results =
            if String.isEmpty (String.trim rawQuery) then
                NotAsked

            else
                Loading
    in
    ( { model | search = search, results = results }
    , debounceCmd
    , case categoryReq of
        Just req ->
            RequestCategorySuggestions req.token { query = req.query, limit = 8 }

        Nothing ->
            NoOp
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
                    | searchToken = priorSearch.searchToken + 1
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
                    , barcodeToken = model.barcodeToken + 1
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

        nextToken : Int
        nextToken =
            model.barcodeToken + 1
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


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
            applyQueryChange rawQuery model

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
                    ( { model | barcodeScanner = ScannerStarting }
                    , Cmd.none
                    , RequestBarcodeScanStart
                    )

                ScannerFailed _ ->
                    ( { model | barcodeScanner = ScannerStarting }
                    , Cmd.none
                    , RequestBarcodeScanStart
                    )

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
                    Ok product ->
                        ( { model | barcodeLookup = Success product }
                        , Cmd.none
                        , Navigate (FoodShow product.id model.date model.mealSlot)
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

        RecentItemsLoaded result ->
            case result of
                Ok response ->
                    ( { model | recentItems = Success response.items }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | recentItems = Failure error }, Cmd.none, SessionExpired )

                    else
                        ( { model | recentItems = Failure error }, Cmd.none, NoOp )

        RecentQuickAddClicked item ->
            if canStartQuickAdd model.quickAdd then
                ( { model
                    | quickAdd = QuickAddRequestingContext item
                  }
                , Cmd.none
                , RequestLocalContext
                )

            else
                ( model, Cmd.none, NoOp )

        RecentItemClicked item ->
            case item.item.itemType of
                ItemRef.Product ->
                    ( model, Cmd.none, Navigate (FoodShow item.item.id model.date model.mealSlot) )

                ItemRef.Meal ->
                    ( model, Cmd.none, Navigate (MealShow item.item.id) )

        LocalContextReceived context ->
            case model.quickAdd of
                QuickAddRequestingContext item ->
                    case quickAddRequest context model item of
                        Just request ->
                            ( { model | quickAdd = QuickAddSubmitting item }
                            , Cmd.none
                            , RequestCreateLog request
                            )

                        Nothing ->
                            ( { model
                                | quickAdd =
                                    QuickAddFailed
                                        "Could not read selected date."
                              }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        QuickAddCompleted result ->
            case result of
                Ok _ ->
                    let
                        key : Maybe String
                        key =
                            quickAddItem model.quickAdd
                                |> Maybe.map recentItemKey

                        nextToken : Int
                        nextToken =
                            model.addedToken + 1
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
                    , NoOp
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
            ( model, Cmd.none, Navigate (FoodShow id model.date model.mealSlot) )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )


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
                            "Could not start barcode scanner."
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
    { date : String, timezone : String }
    -> Model
    -> Logs.RecentItem
    -> Maybe Logs.CreateLogRequest
quickAddRequest context model recentItem =
    let
        rawDate : String
        rawDate =
            Maybe.withDefault context.date model.date
    in
    LocalDate.fromString rawDate
        |> Maybe.map
            (\logDate ->
                { logDate = logDate
                , deviceTimezone = Just context.timezone
                , mealSlot = Maybe.map MealSlot.toString model.mealSlot
                , item =
                    { itemType = recentItem.item.itemType
                    , id = recentItem.item.id
                    }
                , quantity = recentItem.quantity
                , notes = Nothing
                }
            )


recentItemKey : Logs.RecentItem -> String
recentItemKey item =
    ItemRef.itemTypeToString item.item.itemType ++ ":" ++ item.item.id


quickAddItem : QuickAddState -> Maybe Logs.RecentItem
quickAddItem quickAdd =
    case quickAdd of
        QuickAddIdle ->
            Nothing

        QuickAddRequestingContext item ->
            Just item

        QuickAddSubmitting item ->
            Just item

        QuickAddFailed _ ->
            Nothing


quickAddAddingKey : QuickAddState -> Maybe String
quickAddAddingKey quickAdd =
    quickAdd
        |> quickAddItem
        |> Maybe.map recentItemKey


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


clearRecentAddedAfter : String -> Int -> Cmd Msg
clearRecentAddedAfter key token =
    Process.sleep 500
        |> Task.perform (\_ -> ClearRecentAdded key token)



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ contentView { model = model, device = device, theme = theme } ]


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView { model, device, theme } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ searchInputView theme device model
        , searchContentView theme device model
        ]


searchInputView : Theme -> Device -> Model -> Element Msg
searchInputView theme device model =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ scopeControl theme device model.scope
        , if model.scope == Barcode then
            barcodeInputView theme device model

          else
            textSearchInputView theme device model
        ]


textSearchInputView : Theme -> Device -> Model -> Element Msg
textSearchInputView theme device model =
    let
        options : List Completion
        options =
            Search.completions model.search.query model.search.categorySuggestions
    in
    SearchView.searchInput theme
        device
        { onChange = QueryChanged
        , text = model.search.query
        , label = searchLabel model.scope
        , completions = options
        , onTabComplete = CompleteFirstSuggestion
        , onCompletionClick = CompletionClicked
        }


barcodeInputView : Theme -> Device -> Model -> Element Msg
barcodeInputView theme device model =
    let
        input : Element Msg
        input =
            Ui.searchInput theme
                { onChange = BarcodeChanged
                , text = model.barcodeQuery
                , label = "Enter barcode"
                , extraAttrs = [ onEnterSubmit BarcodeSubmitted ]
                }

        searchButton : Element Msg
        searchButton =
            Ui.secondarySubmitButton device
                theme
                { state =
                    if model.barcodeLookup == Loading then
                        Ui.Submitting

                    else if String.isEmpty (String.trim model.barcodeQuery) then
                        Ui.Disabled

                    else
                        Ui.Idle
                , idleLabel = "Search"
                , submittingLabel = "Searching"
                , onPress = BarcodeSubmitted
                }

        scanButton : Element Msg
        scanButton =
            case model.barcodeScanner of
                ScannerStarting ->
                    Ui.primarySubmitButton device
                        theme
                        { state = Ui.Submitting
                        , idleLabel = "Scan"
                        , submittingLabel = "Starting"
                        , onPress = BarcodeScanClicked
                        }

                ScannerActive ->
                    Ui.fullWidthDangerButton device theme "Cancel" BarcodeScanCancelClicked

                _ ->
                    Ui.primarySubmitButton device
                        theme
                        { state = Ui.Idle
                        , idleLabel = "Scan"
                        , submittingLabel = "Starting"
                        , onPress = BarcodeScanClicked
                        }

        controls : Element Msg
        controls =
            if Ui.isSmall device then
                Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space8
                    ]
                    [ scanButton, searchButton ]

            else
                Element.row
                    [ Element.width (Element.px 280)
                    , Element.spacing DesignTokens.space8
                    , Element.alignBottom
                    ]
                    [ scanButton, searchButton ]

        inputRow : Element Msg
        inputRow =
            if Ui.isSmall device then
                Element.column
                    [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                    [ input, controls ]

            else
                Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space8
                    , Element.alignBottom
                    ]
                    [ input, controls ]
    in
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        (inputRow :: barcodeScannerStateView theme device model.barcodeScanner)


barcodeScannerStateView : Theme -> Device -> BarcodeScannerState -> List (Element Msg)
barcodeScannerStateView theme device scanner =
    case scanner of
        ScannerIdle ->
            []

        ScannerFailed message ->
            [ Ui.errorBanner theme message ]

        ScannerStarting ->
            [ barcodeScannerPreview theme device "Starting camera..." ]

        ScannerActive ->
            [ barcodeScannerPreview theme device "Center the barcode on the guide." ]


barcodeScannerPreview : Theme -> Device -> String -> Element Msg
barcodeScannerPreview theme device caption =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        , Element.padding DesignTokens.space8
        , Background.color theme.cardBg
        , Border.width 1
        , Border.color theme.chipBorder
        , Border.rounded DesignTokens.radiusCard
        ]
        [ Element.el
            [ Element.width Element.fill
            , Element.height
                (Element.px
                    (if Ui.isSmall device then
                        380

                     else
                        320
                    )
                )
            , Border.rounded DesignTokens.radiusCard
            , Element.clip
            , Background.color (Element.rgb255 0 0 0)
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


scopeControl : Theme -> Device -> SearchScope -> Element Msg
scopeControl theme device selectedScope =
    Element.row
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space4
        , Element.padding DesignTokens.space4
        , Background.color theme.inputFill
        , Border.width 1
        , Border.color theme.chipBorder
        , Border.rounded DesignTokens.radiusControl
        ]
        (List.map (scopeSegment theme device selectedScope) searchScopes)


scopeSegment : Theme -> Device -> SearchScope -> SearchScope -> Element Msg
scopeSegment theme device selectedScope scope =
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
        , Element.height
            (Element.px
                (if Ui.isSmall device then
                    40

                 else
                    36
                )
            )
        , Background.color background
        , Border.rounded DesignTokens.radiusControl
        , Font.color foreground
        , Font.medium
        , Font.size 14
        , Typography.uiClass "ui-motion ui-pressable"
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
                , Typography.uiClass "ui-text-ellipsis"
                ]
                (Element.text (scopeLabel scope))
        }


bodyView : Theme -> Model -> Device -> Element Msg
bodyView theme model device =
    case model.results of
        NotAsked ->
            Ui.emptyState theme "Search for a food to get started."

        Loading ->
            Ui.card theme [ Ui.skeletonLoading theme ]

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ Ui.errorBanner theme (Client.displayError error)
                , Ui.emptyState theme "No foods found. Try a different search."
                ]

        Success items ->
            if List.isEmpty items then
                textEmptyState theme device model.scope

            else
                Ui.listCard theme
                    { rows =
                        List.map
                            (\item ->
                                SearchView.resultRow theme
                                    device
                                    { query = model.search.query
                                    , item = item
                                    , onSelect = ResultClicked
                                    }
                            )
                            items
                    , footer = Nothing
                    }


searchContentView : Theme -> Device -> Model -> Element Msg
searchContentView theme device model =
    if model.scope == Barcode then
        if hasActiveSearch model then
            barcodeBodyView theme device model

        else
            recentsView theme device model

    else if hasActiveSearch model then
        bodyView theme model device

    else
        recentsView theme device model


barcodeBodyView : Theme -> Device -> Model -> Element Msg
barcodeBodyView theme device model =
    case model.barcodeLookup of
        NotAsked ->
            Ui.emptyState theme "Enter a barcode to look up a food."

        Loading ->
            Ui.card theme [ Ui.skeletonLoading theme ]

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ Ui.errorBanner theme (barcodeErrorMessage error)
                , Ui.emptyState theme "No food found for that barcode."
                , Ui.primarySubmitButton device
                    theme
                    { state = Ui.Idle
                    , idleLabel = "Create Custom Food"
                    , submittingLabel = "Create Custom Food"
                    , onPress = CreateCustomFoodClicked
                    }
                ]

        Success _ ->
            Ui.emptyState theme "Opening food."


textEmptyState : Theme -> Device -> SearchScope -> Element Msg
textEmptyState theme device scope =
    let
        message : String
        message =
            case scope of
                History ->
                    "No logged foods found. Try a different search."

                Custom ->
                    "No custom foods found. Try a different search."

                _ ->
                    "No foods found. Try a different search."

        canCreate : Bool
        canCreate =
            scope /= History
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        (Ui.emptyState theme message
            :: (if canCreate then
                    [ Ui.primarySubmitButton device
                        theme
                        { state = Ui.Idle
                        , idleLabel = "Create Custom Food"
                        , submittingLabel = "Create Custom Food"
                        , onPress = CreateCustomFoodClicked
                        }
                    ]

                else
                    []
               )
        )


searchScopes : List SearchScope
searchScopes =
    [ All, History, Custom, Barcode ]


scopeLabel : SearchScope -> String
scopeLabel scope =
    case scope of
        All ->
            "All"

        History ->
            "History"

        Custom ->
            "Custom"

        Barcode ->
            "Barcode"


searchLabel : SearchScope -> String
searchLabel scope =
    case scope of
        All ->
            "Search for a food"

        History ->
            "Search your logged foods"

        Custom ->
            "Search your custom foods"

        Barcode ->
            "Enter barcode"


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


barcodeErrorMessage : Client.ApiError -> String
barcodeErrorMessage error =
    case error of
        Client.BadStatus 404 _ _ ->
            "No food matched that barcode."

        _ ->
            Client.displayError error


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


recentsView : Theme -> Device -> Model -> Element Msg
recentsView theme device model =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Ui.maybeErrorBanner theme (quickAddError model.quickAdd)
        , case model.recentItems of
            NotAsked ->
                Element.none

            Loading ->
                Ui.card theme [ Ui.skeletonLoading theme ]

            Failure _ ->
                Element.none

            Success items ->
                if List.isEmpty items then
                    Element.none

                else
                    Element.column
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ Typography.sectionTitle theme "Recent"
                        , Ui.listCard theme
                            { rows = List.map (recentItemRow theme device model) items
                            , footer = Nothing
                            }
                        ]
        ]


recentItemRow : Theme -> Device -> Model -> Logs.RecentItem -> Element Msg
recentItemRow theme device model item =
    let
        key : String
        key =
            recentItemKey item

        added : Bool
        added =
            List.any (\addedItem -> addedItem.key == key) model.addedItems

        adding : Bool
        adding =
            quickAddAddingKey model.quickAdd == Just key

        title : Element Msg
        title =
            if Ui.isSmall device then
                Typography.wrappedListItemTitle theme item.item.name

            else
                Typography.truncatedListItemTitle theme item.item.name
    in
    Ui.listRow
        { onSelect = RecentItemClicked item
        , leading = [ View.Product.macroDotGhost ]
        , title = title
        , subtitle =
            [ Typography.mutedCaptionParagraph theme
                (Ui.dotSeparated
                    [ item.item.brand
                    , Just (Nutrition.quantityText item.quantity)
                    , Nutrition.servingCaloriesText item
                    ]
                )
            ]
        , trailing =
            [ quickAddButton theme
                { state =
                    if adding then
                        QuickAddAdding

                    else if added then
                        QuickAddAdded

                    else
                        QuickAddCanAdd
                , onPress = RecentQuickAddClicked item
                }
            ]
        }


quickAddButton :
    Theme
    -> { state : QuickAddButtonState, onPress : Msg }
    -> Element Msg
quickAddButton theme config =
    let
        enabled : Bool
        enabled =
            config.state /= QuickAddAdding

        title : String
        title =
            quickAddButtonTitle config.state
    in
    Input.button
        [ Background.color
            (if enabled then
                theme.brandBlue

             else
                theme.brandBlueDisabled
            )
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded DesignTokens.radiusPill
        , Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Element.paddingEach { top = 10, right = 14, bottom = 10, left = 14 }
        , Font.center
        , Font.medium
        , Element.htmlAttribute (Html.Attributes.title title)
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" title)
        ]
        { onPress =
            if enabled then
                Just config.onPress

            else
                Nothing
        , label =
            Icon.view
                { icon = quickAddButtonIcon config.state
                , size = 18
                , color = Element.rgb255 255 255 255
                }
        }


quickAddButtonTitle : QuickAddButtonState -> String
quickAddButtonTitle state =
    case state of
        QuickAddCanAdd ->
            "Add"

        QuickAddAdding ->
            "Adding"

        QuickAddAdded ->
            "Added"


quickAddButtonIcon : QuickAddButtonState -> Icon
quickAddButtonIcon state =
    case state of
        QuickAddCanAdd ->
            Icon.Plus

        QuickAddAdding ->
            Icon.LoaderCircle

        QuickAddAdded ->
            Icon.Check


hasActiveSearch : Model -> Bool
hasActiveSearch model =
    if model.scope == Barcode then
        if not (String.isEmpty (String.trim model.barcodeQuery)) then
            True

        else
            case model.barcodeLookup of
                NotAsked ->
                    False

                Loading ->
                    True

                Failure _ ->
                    True

                Success _ ->
                    True

    else if not (String.isEmpty (String.trim model.search.query)) then
        True

    else
        case model.results of
            NotAsked ->
                False

            Loading ->
                True

            Failure _ ->
                True

            Success _ ->
                True
