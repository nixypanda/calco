module Page.FoodSearch exposing
    ( Completion
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , isBarcodeVisible
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
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html
import Html.Events
import Json.Decode as Decode
import Loadable exposing (Loadable(..))
import Process
import Route exposing (Route(..))
import Task
import Ui
import View.FoodSearchResults as FoodSearchResults


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


type Completion
    = OperatorCompletion String
    | CategoryCompletion String Int


init : Maybe MealSlot -> Model
init mealSlot =
    { query = ""
    , searchToken = 0
    , categoryToken = 0
    , categorySuggestions = []
    , results = NotAsked
    , mealSlot = mealSlot
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
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
                    case categoryQuery query of
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
            case List.head (completions model.query model.categorySuggestions) of
                Just completion ->
                    update (QueryChanged (applyCompletion completion model.query)) model

                Nothing ->
                    ( model, Cmd.none, NoOp )

        CompletionClicked completion ->
            update (QueryChanged (applyCompletion completion model.query)) model

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


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value)
        && String.all Char.isDigit value


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ searchInput model
        , bodyView model
        ]


searchInput : Model -> Element Msg
searchInput model =
    let
        options : List Completion
        options =
            completions model.query model.categorySuggestions
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Input.text
            [ Border.rounded 6
            , Border.width 1
            , Border.color (Element.rgb255 209 213 219)
            , Element.padding 10
            , Element.htmlAttribute (tabCompletionHandler options)
            ]
            { onChange = QueryChanged
            , text = model.query
            , placeholder = Nothing
            , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Search for a food")
            }
        , completionDropdown options
        ]


tabCompletionHandler : List Completion -> Html.Attribute Msg
tabCompletionHandler options =
    Html.Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Tab" && not (List.isEmpty options) then
                        Decode.succeed ( CompleteFirstSuggestion, True )

                    else
                        Decode.fail "not handled"
                )
        )


completionDropdown : List Completion -> Element Msg
completionDropdown options =
    if List.isEmpty options then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.height (Element.px (completionDropdownHeight options))
            , Element.scrollbarY
            , Element.spacing 2
            , Element.padding 4
            , Border.rounded 6
            , Border.width 1
            , Border.color Ui.borderGray
            , Background.color Ui.cardBg
            ]
            (List.map completionRow options)


completionDropdownHeight : List Completion -> Int
completionDropdownHeight options =
    min 224 (8 + List.length options * 38)


completionRow : Completion -> Element Msg
completionRow completion =
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY 10 8
        , Border.rounded 4
        ]
        { onPress = Just (CompletionClicked completion)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 8 ]
                [ Element.el
                    [ Element.width Element.fill, Font.medium ]
                    (Element.text (completionLabel completion))
                , case completion of
                    CategoryCompletion _ count ->
                        Ui.badge (String.fromInt count)

                    OperatorCompletion _ ->
                        Element.none
                ]
        }


completions : String -> List CategorySuggestion -> List Completion
completions query suggestions =
    let
        token : String
        token =
            currentToken query

        current : String
        current =
            String.toLower token
    in
    if String.isEmpty current then
        []

    else if not (String.contains ":" current) then
        [ if String.startsWith current "category:" then
            Just (OperatorCompletion "category:")

          else
            Nothing
        , if String.startsWith current "-category:" then
            Just (OperatorCompletion "-category:")

          else
            Nothing
        ]
            |> List.filterMap identity

    else
        case categoryPrefix token of
            Just prefix ->
                suggestions
                    |> List.map
                        (\category ->
                            CategoryCompletion
                                (prefix ++ quoteCategory category.value)
                                category.count
                        )

            Nothing ->
                []


completionLabel : Completion -> String
completionLabel completion =
    case completion of
        OperatorCompletion replacement ->
            replacement

        CategoryCompletion replacement _ ->
            replacement


applyCompletion : Completion -> String -> String
applyCompletion completion query =
    replaceCurrentToken query (completionLabel completion)


categoryQuery : String -> Maybe String
categoryQuery query =
    let
        token : String
        token =
            currentToken query
    in
    categoryPrefix token
        |> Maybe.map (\prefix -> stripCategoryValue (String.dropLeft (String.length prefix) token))


categoryPrefix : String -> Maybe String
categoryPrefix token =
    if String.startsWith "category:" token then
        Just "category:"

    else if String.startsWith "-category:" token then
        Just "-category:"

    else
        Nothing


currentToken : String -> String
currentToken query =
    query
        |> tokens
        |> List.reverse
        |> List.head
        |> Maybe.withDefault ""


replaceCurrentToken : String -> String -> String
replaceCurrentToken query replacement =
    let
        before : String
        before =
            queryBeforeCurrentToken query
    in
    before ++ replacement


queryBeforeCurrentToken : String -> String
queryBeforeCurrentToken query =
    query
        |> tokensWithSeparators
        |> List.reverse
        |> List.drop 1
        |> List.reverse
        |> String.concat


tokens : String -> List String
tokens query =
    tokensWithSeparators query
        |> List.filter (String.trim >> String.isEmpty >> not)


tokensWithSeparators : String -> List String
tokensWithSeparators query =
    query
        |> String.toList
        |> List.foldl tokenStep { current = "", parts = [], inQuotes = False }
        |> finishTokens


type alias TokenState =
    { current : String
    , parts : List String
    , inQuotes : Bool
    }


tokenStep : Char -> TokenState -> TokenState
tokenStep char state =
    if char == '"' then
        { state | current = state.current ++ String.fromChar char, inQuotes = not state.inQuotes }

    else if isWhitespace char && not state.inQuotes then
        { state
            | current = ""
            , parts = String.fromChar char :: state.current :: state.parts
        }

    else
        { state | current = state.current ++ String.fromChar char }


finishTokens : TokenState -> List String
finishTokens state =
    List.reverse (state.current :: state.parts)


stripCategoryValue : String -> String
stripCategoryValue value =
    value
        |> String.trim
        |> trimLeadingQuote
        |> trimTrailingQuote


trimLeadingQuote : String -> String
trimLeadingQuote value =
    if String.startsWith "\"" value then
        String.dropLeft 1 value

    else
        value


trimTrailingQuote : String -> String
trimTrailingQuote value =
    if String.endsWith "\"" value then
        String.dropRight 1 value

    else
        value


quoteCategory : String -> String
quoteCategory value =
    if String.any isWhitespace value then
        "\"" ++ value ++ "\""

    else
        value


isWhitespace : Char -> Bool
isWhitespace char =
    List.member char [ ' ', '\n', '\t', '\u{000D}' ]


bodyView : Model -> Element Msg
bodyView model =
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
                            FoodSearchResults.resultRow
                                { query = model.query
                                , item = item
                                , onSelect = ResultClicked
                                }
                        )
                        items
                    )
