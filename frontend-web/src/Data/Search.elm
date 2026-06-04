module Data.Search exposing
    ( Completion(..)
    , applyCompletion
    , categoryQuery
    , completionLabel
    , completions
    )


type Completion
    = OperatorCompletion String
    | CategoryCompletion String Int


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
