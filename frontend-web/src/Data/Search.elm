module Data.Search exposing
    ( CategoryRequest
    , CategorySuggestion
    , Completion(..)
    , Debounce
    , QueryState
    , applyCompletion
    , categoryQuery
    , completionLabel
    , completions
    , empty
    , onQueryChanged
    , onQueryChangedDebounced
    , setCategorySuggestions
    , withCategoryToken
    , withQuery
    , withSearchToken
    )

import Lib.Text as Text
import Process
import Task


type Completion
    = OperatorCompletion String
    | CategoryCompletion String Int


type alias CategorySuggestion =
    { value : String
    , count : Int
    }


type alias CategoryRequest =
    { token : Int
    , query : String
    }


type alias QueryState =
    { query : String
    , searchToken : Int
    , categoryToken : Int
    , categorySuggestions : List CategorySuggestion
    }


empty : QueryState
empty =
    { query = ""
    , searchToken = 0
    , categoryToken = 0
    , categorySuggestions = []
    }


type alias Debounce msg =
    { delayMs : Int
    , onSearchElapsed : Int -> String -> msg
    , onCategoryElapsed : Int -> String -> msg
    }


onQueryChanged : String -> QueryState -> ( QueryState, Maybe CategoryRequest )
onQueryChanged rawQuery state =
    let
        isEmpty : Bool
        isEmpty =
            String.isEmpty (String.trim rawQuery)

        nextSearchToken : Int
        nextSearchToken =
            state.searchToken + 1

        nextCategoryToken : Int
        nextCategoryToken =
            state.categoryToken + 1

        categoryReq : Maybe CategoryRequest
        categoryReq =
            categoryQuery rawQuery
                |> Maybe.map
                    (\value ->
                        { token = nextCategoryToken
                        , query = value
                        }
                    )

        nextCategorySuggestions : List CategorySuggestion
        nextCategorySuggestions =
            case categoryReq of
                Nothing ->
                    []

                Just _ ->
                    if isEmpty then
                        []

                    else
                        state.categorySuggestions

        nextState : QueryState
        nextState =
            { state
                | query = rawQuery
                , searchToken = nextSearchToken
                , categoryToken = nextCategoryToken
                , categorySuggestions = nextCategorySuggestions
            }
    in
    ( nextState, categoryReq )


onQueryChangedDebounced :
    String
    -> QueryState
    -> Debounce msg
    -> ( QueryState, Cmd msg )
onQueryChangedDebounced rawQuery state config =
    let
        trimmed : String
        trimmed =
            String.trim rawQuery

        ( nextState, categoryReq ) =
            onQueryChanged rawQuery state
    in
    ( nextState
    , Cmd.batch
        (List.filterMap identity
            [ if String.isEmpty trimmed then
                Nothing

              else
                Just
                    (debounceAfter config.delayMs
                        nextState.searchToken
                        trimmed
                        config.onSearchElapsed
                    )
            , categoryReq
                |> Maybe.map
                    (\req ->
                        debounceAfter config.delayMs
                            req.token
                            req.query
                            config.onCategoryElapsed
                    )
            ]
        )
    )


debounceAfter : Int -> Int -> String -> (Int -> String -> msg) -> Cmd msg
debounceAfter delayMs token query onFire =
    Process.sleep (toFloat delayMs)
        |> Task.perform (\_ -> onFire token query)


setCategorySuggestions : Int -> List CategorySuggestion -> QueryState -> QueryState
setCategorySuggestions token suggestions state =
    if state.categoryToken == token then
        { state | categorySuggestions = suggestions }

    else
        state


withQuery : String -> QueryState -> QueryState
withQuery query state =
    { state | query = query }


withSearchToken : Int -> QueryState -> QueryState
withSearchToken token state =
    { state | searchToken = token }


withCategoryToken : Int -> QueryState -> QueryState
withCategoryToken token state =
    { state | categoryToken = token }


completions : String -> List { a | value : String, count : Int } -> List Completion
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
    queryBeforeCurrentToken query ++ replacement


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
    Text.splitQuotedWhitespace query


stripCategoryValue : String -> String
stripCategoryValue value =
    Text.stripBoundingQuotes value


quoteCategory : String -> String
quoteCategory value =
    Text.quoteIfWhitespace value
