module Page.Food.Search exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods
import Data.MealSlot exposing (MealSlot)
import Data.Route exposing (Route(..))
import Data.Search as Search exposing (Completion, QueryState)
import Element exposing (Device, Element)
import Lib.Loadable exposing (Loadable(..))
import Ui
import View.Search as SearchView


type alias Model =
    { search : QueryState
    , results : Loadable Client.ApiError (List Foods.SearchResult)
    , mealSlot : Maybe MealSlot
    }


type Msg
    = QueryChanged String
    | CategorySuggestionsCompleted Int (Result Client.ApiError Foods.CategorySuggestionResponse)
    | CompleteFirstSuggestion
    | CompletionClicked Completion
    | DebounceElapsed Int String
    | SearchCompleted Int (Result Client.ApiError Foods.SearchResponse)
    | ResultClicked String
    | CreateCustomFoodClicked


type OutMsg
    = NoOp
    | RequestSearch Int Foods.SearchRequest
    | RequestCategorySuggestions Int Foods.CategorySuggestionRequest
    | Navigate Route
    | SessionExpired


init : Maybe MealSlot -> Model
init mealSlot =
    { search = Search.empty
    , results = NotAsked
    , mealSlot = mealSlot
    }


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

        ResultClicked id ->
            ( model, Cmd.none, Navigate (FoodShow id model.mealSlot) )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ searchInputView model
        , bodyView model device
        ]


searchInputView : Model -> Element Msg
searchInputView model =
    let
        options : List Completion
        options =
            Search.completions model.search.query model.search.categorySuggestions
    in
    SearchView.searchInput
        { onChange = QueryChanged
        , text = model.search.query
        , label = "Search for a food"
        , completions = options
        , onTabComplete = CompleteFirstSuggestion
        , onCompletionClick = CompletionClicked
        }


bodyView : Model -> Device -> Element Msg
bodyView model device =
    case model.results of
        NotAsked ->
            Ui.emptyState "Search for a food to get started."

        Loading ->
            Ui.loading "Searching foods..."

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.errorBanner (Client.displayError error)
                , Ui.emptyState "No foods found. Try a different search."
                ]

        Success items ->
            if List.isEmpty items then
                Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
                    [ Ui.emptyState "No foods found. Try a different search."
                    , Ui.button "Create Custom Food" CreateCustomFoodClicked
                    ]

            else
                Ui.card
                    (List.map
                        (\item ->
                            SearchView.resultRow
                                device
                                { query = model.search.query
                                , item = item
                                , onSelect = ResultClicked
                                }
                        )
                        items
                    )
