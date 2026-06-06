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
    exposing
        ( CategorySuggestion
        , CategorySuggestionRequest
        , SearchRequest
        , SearchResult
        )
import Data.MealSlot exposing (MealSlot)
import Data.Route exposing (Route(..))
import Data.Search as Search exposing (Completion)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.Loadable exposing (Loadable(..))
import Process
import Task
import Ui
import View.Search as SearchView


type alias Model =
    { query : String
    , searchToken : Int
    , categoryToken : Int
    , categorySuggestions : List CategorySuggestion
    , results : Loadable Client.ApiError (List SearchResult)
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
    | RequestSearch Int SearchRequest
    | RequestCategorySuggestions Int CategorySuggestionRequest
    | Navigate Route
    | SessionExpired


init : Maybe MealSlot -> Model
init mealSlot =
    { query = ""
    , searchToken = 0
    , categoryToken = 0
    , categorySuggestions = []
    , results = NotAsked
    , mealSlot = mealSlot
    }


onQueryChanged : String -> Model -> ( Model, Cmd Msg, OutMsg )
onQueryChanged rawQuery model =
    let
        query : String
        query =
            rawQuery

        trimmed : String
        trimmed =
            String.trim query

        nextCategoryToken : Int
        nextCategoryToken =
            model.categoryToken + 1

        categoryOutMsg : OutMsg
        categoryOutMsg =
            case Search.categoryQuery query of
                Just value ->
                    RequestCategorySuggestions nextCategoryToken
                        { query = value, limit = 8 }

                Nothing ->
                    NoOp
    in
    if String.isEmpty trimmed then
        ( { model
            | query = query
            , results = NotAsked
            , searchToken = model.searchToken + 1
            , categoryToken = nextCategoryToken
            , categorySuggestions = []
          }
        , Cmd.none
        , NoOp
        )

    else
        let
            nextToken : Int
            nextToken =
                model.searchToken + 1
        in
        ( { model
            | query = query
            , searchToken = nextToken
            , categoryToken = nextCategoryToken
            , categorySuggestions =
                if categoryOutMsg == NoOp then
                    []

                else
                    model.categorySuggestions
            , results = Loading
          }
        , debounce nextToken trimmed
        , categoryOutMsg
        )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
            onQueryChanged rawQuery model

        CategorySuggestionsCompleted token result ->
            if token /= model.categoryToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model | categorySuggestions = response.items }, Cmd.none, NoOp )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | categorySuggestions = [] }, Cmd.none, SessionExpired )

                        else
                            ( { model | categorySuggestions = [] }, Cmd.none, NoOp )

        CompleteFirstSuggestion ->
            case List.head (Search.completions model.query model.categorySuggestions) of
                Just completion ->
                    onQueryChanged (Search.applyCompletion completion model.query) model

                Nothing ->
                    ( model, Cmd.none, NoOp )

        CompletionClicked completion ->
            onQueryChanged (Search.applyCompletion completion model.query) model

        DebounceElapsed token query ->
            if token == model.searchToken then
                ( model, Cmd.none, RequestSearch token { query = query } )

            else
                ( model, Cmd.none, NoOp )

        SearchCompleted token result ->
            if token /= model.searchToken then
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
            ( model, Cmd.none, Navigate (FoodDetail id model.mealSlot) )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )


debounce : Int -> String -> Cmd Msg
debounce token query =
    Process.sleep 300
        |> Task.perform (\_ -> DebounceElapsed token query)


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ searchInput model
        , bodyView model device
        ]


searchInput : Model -> Element Msg
searchInput model =
    let
        options : List Completion
        options =
            Search.completions model.query model.categorySuggestions
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Input.text
            [ Border.rounded 12
            , Background.color Ui.inputFill
            , Element.padding 12
            , Element.htmlAttribute
                (SearchView.tabCompletionHandler CompleteFirstSuggestion options)
            ]
            { onChange = QueryChanged
            , text = model.query
            , placeholder = Nothing
            , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Search for a food")
            }
        , SearchView.completionDropdown { onSelect = CompletionClicked } options
        ]


bodyView : Model -> Device -> Element Msg
bodyView model device =
    case model.results of
        NotAsked ->
            Ui.emptyState "Search for a food to get started."

        Loading ->
            Ui.loading "Searching foods..."

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing 12 ]
                [ Ui.errorBanner (Client.displayError error)
                , Ui.emptyState "No foods found. Try a different search."
                ]

        Success items ->
            if List.isEmpty items then
                Element.column [ Element.width Element.fill, Element.spacing 12 ]
                    [ Ui.emptyState "No foods found. Try a different search."
                    , Ui.button "Create Custom Food" CreateCustomFoodClicked
                    ]

            else
                Ui.card
                    (List.map
                        (\item ->
                            SearchView.resultRow
                                device
                                { query = model.query
                                , item = item
                                , onSelect = ResultClicked
                                }
                        )
                        items
                    )
