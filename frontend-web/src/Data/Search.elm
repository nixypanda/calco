module Data.Search exposing
    ( Completion(..)
    , applyCompletion
    , categoryQuery
    , completionLabel
    , completions
    )

import Lib.Text as Text


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
    Text.splitQuotedWhitespace query


stripCategoryValue : String -> String
stripCategoryValue value =
    Text.stripBoundingQuotes value


quoteCategory : String -> String
quoteCategory value =
    Text.quoteIfWhitespace value
