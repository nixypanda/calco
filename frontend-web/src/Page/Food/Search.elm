module Page.Food.Search exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , QuickAddState
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
import Lib.Date as LocalDate
import Lib.Loadable exposing (Loadable(..))
import Ui
import Ui.Theme exposing (Theme)
import View.Search as SearchView



-- MODEL


type alias Model =
    { search : QueryState
    , results : Loadable Client.ApiError (List Foods.SearchResult)
    , recentItems : Loadable Client.ApiError (List Logs.RecentItem)
    , date : Maybe String
    , mealSlot : Maybe MealSlot
    , quickAdd : QuickAddState
    , addedItems : List String
    }


type QuickAddState
    = QuickAddIdle
    | QuickAddRequestingContext Logs.RecentItem
    | QuickAddSubmitting Logs.RecentItem
    | QuickAddFailed String


init : Maybe String -> Maybe MealSlot -> Model
init date mealSlot =
    { search = Search.empty
    , results = NotAsked
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
    }



-- UPDATE


type Msg
    = QueryChanged String
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
    | ResultClicked String
    | CreateCustomFoodClicked


type OutMsg
    = NoOp
    | RequestSearch Int Foods.SearchRequest
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


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
            applyQueryChange rawQuery model

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
                ( model, Cmd.none, RequestSearch token { query = query } )

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
                    in
                    ( { model
                        | quickAdd = QuickAddIdle
                        , addedItems =
                            case key of
                                Just value ->
                                    value :: model.addedItems

                                Nothing ->
                                    model.addedItems
                      }
                    , Cmd.none
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

        ResultClicked id ->
            ( model, Cmd.none, Navigate (FoodShow id model.date model.mealSlot) )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )


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



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ searchInputView theme device model
        , contentView theme device model
        ]


searchInputView : Theme -> Device -> Model -> Element Msg
searchInputView theme device model =
    let
        options : List Completion
        options =
            Search.completions model.search.query model.search.categorySuggestions
    in
    SearchView.searchInput theme
        device
        { onChange = QueryChanged
        , text = model.search.query
        , label = "Search for a food"
        , completions = options
        , onTabComplete = CompleteFirstSuggestion
        , onCompletionClick = CompletionClicked
        }


bodyView : Theme -> Model -> Device -> Element Msg
bodyView theme model device =
    case model.results of
        NotAsked ->
            Ui.emptyState theme "Search for a food to get started."

        Loading ->
            Ui.card theme [ Ui.skeletonLoading theme ]

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.errorBanner theme (Client.displayError error)
                , Ui.emptyState theme "No foods found. Try a different search."
                ]

        Success items ->
            if List.isEmpty items then
                Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
                    [ Ui.emptyState theme "No foods found. Try a different search."
                    , Ui.primarySubmitButton device
                        theme
                        { state = Ui.Idle
                        , idleLabel = "Create Custom Food"
                        , submittingLabel = "Create Custom Food"
                        , onPress = CreateCustomFoodClicked
                        }
                    ]

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


contentView : Theme -> Device -> Model -> Element Msg
contentView theme device model =
    if hasActiveSearch model then
        bodyView theme model device

    else
        recentsView theme device model


recentsView : Theme -> Device -> Model -> Element Msg
recentsView theme device model =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space8 ]
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
                        [ Element.width Element.fill, Element.spacing Ui.space8 ]
                        [ Ui.sectionTitle theme "Recent"
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
            List.member key model.addedItems

        adding : Bool
        adding =
            quickAddAddingKey model.quickAdd == Just key

        title : Element Msg
        title =
            if Ui.isSmall device then
                Ui.wrappedListItemTitle theme item.item.name

            else
                Ui.truncatedListItemTitle theme item.item.name
    in
    Ui.listRow
        { onSelect = RecentItemClicked item
        , leading = [ Ui.macroDotGhost ]
        , title = title
        , subtitle =
            [ Ui.mutedCaption theme
                (Ui.dotSeparated
                    [ item.item.brand
                    , Just (itemTypeLabel item)
                    , Just (quantityText item.quantity)
                    , Just (LocalDate.display item.lastUsedDate)
                    ]
                )
            ]
        , trailing =
            [ quickAddButton theme
                device
                { label =
                    if adding then
                        "Adding"

                    else if added then
                        "Added"

                    else
                        "Add"
                , enabled = not adding
                , onPress = RecentQuickAddClicked item
                }
            ]
        }


quickAddButton :
    Theme
    -> Device
    -> { label : String, enabled : Bool, onPress : Msg }
    -> Element Msg
quickAddButton theme device config =
    Input.button
        [ Background.color
            (if config.enabled then
                theme.brandBlue

             else
                theme.brandBlueDisabled
            )
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded Ui.radiusPill
        , Element.width
            (if Ui.isSmall device then
                Element.px 88

             else
                Element.px 96
            )
        , Element.paddingEach { top = 10, right = 14, bottom = 10, left = 14 }
        , Font.center
        , Font.medium
        ]
        { onPress =
            if config.enabled then
                Just config.onPress

            else
                Nothing
        , label = Element.text config.label
        }


itemTypeLabel : Logs.RecentItem -> String
itemTypeLabel item =
    case item.item.itemType of
        ItemRef.Product ->
            "Food"

        ItemRef.Meal ->
            "Meal"


quantityText : Nutrition.Quantity -> String
quantityText quantity =
    quantity.amount ++ " " ++ quantity.unit


hasActiveSearch : Model -> Bool
hasActiveSearch model =
    if not (String.isEmpty (String.trim model.search.query)) then
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
