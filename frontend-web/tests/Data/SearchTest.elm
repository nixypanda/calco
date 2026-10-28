module Data.SearchTest exposing (tests)

import Data.Search as Search exposing (CategorySuggestion, Completion(..), QueryState)
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Platform.Cmd as Cmd
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3, test)


tests : Test
tests =
    describe "Data.Search"
        [ describe "completion navigation"
            [ fuzz (Fuzz.maybe completionFuzzer) "empty options never yield a selection" <|
                \current ->
                    Expect.all
                        [ \_ -> Search.nextCompletion current [] |> Expect.equal Nothing
                        , \_ -> Search.previousCompletion current [] |> Expect.equal Nothing
                        ]
                        ()
            , fuzz2
                (Fuzz.maybe completionFuzzer)
                completionsFuzzer
                "the selection stays within the options"
              <|
                \current options ->
                    Expect.all
                        [ \_ ->
                            expectCompletionMember options (Search.nextCompletion current options)
                        , \_ ->
                            expectCompletionMember options
                                (Search.previousCompletion current options)
                        ]
                        ()
            , fuzz2
                uniqueCompletionsFuzzer
                (Fuzz.intRange 0 1000)
                "nextCompletion never moves to an earlier option"
              <|
                \options rawIndex ->
                    let
                        index : Int
                        index =
                            modBy (max 1 (List.length options)) rawIndex

                        current : Maybe Completion
                        current =
                            List.drop index options |> List.head
                    in
                    case current of
                        Nothing ->
                            Expect.pass

                        Just selected ->
                            case
                                ( Search.completionIndex selected options
                                , Search.nextCompletion (Just selected) options
                                    |> Maybe.andThen
                                        (\next -> Search.completionIndex next options)
                                )
                            of
                                ( Just before, Just after ) ->
                                    after |> Expect.atLeast before

                                _ ->
                                    Expect.fail "nextCompletion must resolve to an indexed option"
            , fuzz uniqueCompletionsFuzzer "nextCompletion moves to the exact adjacent option" <|
                \options ->
                    case options of
                        [] ->
                            Expect.pass

                        _ ->
                            List.map2
                                (\current expected ->
                                    Search.nextCompletion (Just current) options
                                        |> Expect.equal (Just expected)
                                )
                                (List.take (List.length options - 1) options)
                                (List.drop 1 options)
                                |> expectAll
            , fuzz
                uniqueCompletionsFuzzer
                "previousCompletion moves to the exact adjacent option"
              <|
                \options ->
                    case options of
                        [] ->
                            Expect.pass

                        _ ->
                            List.map2
                                (\current expected ->
                                    Search.previousCompletion (Just current) options
                                        |> Expect.equal (Just expected)
                                )
                                (List.drop 1 options)
                                (List.take (List.length options - 1) options)
                                |> expectAll
            , fuzz completionsFuzzer "nextCompletion stays on the last option" <|
                \options ->
                    let
                        unique : List Completion
                        unique =
                            uniqueCompletions options
                    in
                    case List.reverse unique |> List.head of
                        Nothing ->
                            Expect.pass

                        Just last ->
                            Search.nextCompletion (Just last) unique
                                |> Expect.equal (Just last)
            , fuzz completionsFuzzer "previousCompletion stays on the first option" <|
                \options ->
                    let
                        unique : List Completion
                        unique =
                            uniqueCompletions options
                    in
                    case List.head unique of
                        Nothing ->
                            Expect.pass

                        Just first ->
                            Search.previousCompletion (Just first) unique
                                |> Expect.equal (Just first)
            , fuzz categoryCompletionsFuzzer "a missing selection falls back to the first option" <|
                \options ->
                    let
                        current : Completion
                        current =
                            OperatorCompletion "not-a-category-completion"
                    in
                    Expect.all
                        [ \_ ->
                            Search.nextCompletion (Just current) options
                                |> Expect.equal (List.head options)
                        , \_ ->
                            Search.previousCompletion (Just current) options
                                |> Expect.equal (List.head options)
                        ]
                        ()
            ]
        , describe "completionIndex"
            [ fuzz2 completionFuzzer completionsFuzzer "reports the first matching index" <|
                \target options ->
                    case Search.completionIndex target options of
                        Nothing ->
                            List.member target options
                                |> Expect.equal False

                        Just index ->
                            Expect.all
                                [ \_ ->
                                    List.drop index options
                                        |> List.head
                                        |> Expect.equal (Just target)
                                , \_ ->
                                    List.take index options
                                        |> List.member target
                                        |> Expect.equal False
                                ]
                                ()
            ]
        , describe "applyCompletion"
            [ fuzz2 completionPrefixFuzzer wordFuzzer "only the last token changes" <|
                \prefix token ->
                    let
                        label : String
                        label =
                            "replacement-" ++ token
                    in
                    Search.applyCompletion (OperatorCompletion label) (prefix ++ token)
                        |> Expect.equal (prefix ++ label)
            , fuzz2
                categoryPrefixFuzzer
                categoryValueFuzzer
                "a category completion replaces only the last token"
              <|
                \prefix value ->
                    let
                        replacement : String
                        replacement =
                            prefix ++ Text.quoteIfWhitespace value

                        completion : Completion
                        completion =
                            CategoryCompletion replacement 1
                    in
                    Search.applyCompletion completion ("apple " ++ prefix ++ "typed")
                        |> Expect.equal ("apple " ++ replacement)
            , fuzz2
                categoryPrefixFuzzer
                categoryValueFuzzer
                "category completions roundtrip through categoryQuery"
              <|
                \prefix value ->
                    let
                        completion : Completion
                        completion =
                            CategoryCompletion (prefix ++ Text.quoteIfWhitespace value) 1
                    in
                    Search.applyCompletion completion (prefix ++ "typed")
                        |> Search.categoryQuery
                        |> Expect.equal (Just value)
            , fuzz categoryValueFuzzer "category values survive the quote and strip roundtrip" <|
                \value ->
                    Text.stripBoundingQuotes (Text.quoteIfWhitespace value)
                        |> Expect.equal value
            ]
        , describe "completions"
            [ fuzz operatorTokenFuzzer "operator prefixes suggest their full operator" <|
                \( token, operator ) ->
                    Search.completions token []
                        |> Expect.equal [ OperatorCompletion operator ]
            , fuzz2
                whitespaceFuzzer
                (Fuzz.list suggestionFuzzer)
                "an empty current token has no completions"
              <|
                \query suggestions ->
                    Search.completions query suggestions
                        |> Expect.equal []
            , fuzz2
                categoryPrefixFuzzer
                (Fuzz.list suggestionFuzzer)
                "category completions preserve order, values, and counts"
              <|
                \prefix suggestions ->
                    let
                        expected : List Completion
                        expected =
                            List.map
                                (\suggestion ->
                                    CategoryCompletion
                                        (prefix ++ Text.quoteIfWhitespace suggestion.value)
                                        suggestion.count
                                )
                                suggestions
                    in
                    Search.completions (prefix ++ "typed") suggestions
                        |> Expect.equal expected
            , fuzz2
                (Fuzz.map (\value -> "foo:" ++ value) wordFuzzer)
                (Fuzz.map2 (::) suggestionFuzzer (Fuzz.list suggestionFuzzer))
                "a non-category colon token has no completions"
              <|
                \query suggestions ->
                    Search.completions query suggestions
                        |> Expect.equal []
            ]
        , describe "onQueryChanged"
            [ fuzz2
                Fuzz.string
                queryStateFuzzer
                "advances both tickets by one and preserves the query"
              <|
                \raw state ->
                    let
                        next : QueryState
                        next =
                            Tuple.first (Search.onQueryChanged raw state)
                    in
                    Expect.all
                        [ \_ -> next.searchToken |> Expect.equal (Ticket.next state.searchToken)
                        , \_ -> next.categoryToken |> Expect.equal (Ticket.next state.categoryToken)
                        , \_ -> next.query |> Expect.equal raw
                        ]
                        ()
            , fuzz2
                whitespaceFuzzer
                queryStateFuzzer
                "whitespace queries clear suggestions and request no categories"
              <|
                \raw state ->
                    let
                        ( next, request ) =
                            Search.onQueryChanged raw state
                    in
                    Expect.all
                        [ \_ -> request |> Expect.equal Nothing
                        , \_ -> next.categorySuggestions |> Expect.equal []
                        ]
                        ()
            , fuzz2 plainQueryFuzzer queryStateFuzzer "plain queries clear category suggestions" <|
                \raw state ->
                    let
                        ( next, request ) =
                            Search.onQueryChanged raw state
                    in
                    Expect.all
                        [ \_ -> request |> Expect.equal Nothing
                        , \_ -> next.categorySuggestions |> Expect.equal []
                        ]
                        ()
            , fuzz3
                categoryPrefixFuzzer
                categoryValueFuzzer
                queryStateFuzzer
                "category queries request the new token and value"
              <|
                \prefix value state ->
                    let
                        raw : String
                        raw =
                            prefix ++ Text.quoteIfWhitespace value

                        ( next, request ) =
                            Search.onQueryChanged raw state
                    in
                    Expect.all
                        [ \_ ->
                            request
                                |> Expect.equal
                                    (Just
                                        { token = Ticket.next state.categoryToken
                                        , query = value
                                        }
                                    )
                        , \_ ->
                            next.categorySuggestions
                                |> Expect.equal state.categorySuggestions
                        ]
                        ()
            ]
        , describe "setCategorySuggestions"
            [ test "a live category token updates the suggestions" <|
                \_ ->
                    let
                        state : QueryState
                        state =
                            Search.empty

                        suggestions : List CategorySuggestion
                        suggestions =
                            [ { value = "fruit", count = 3 } ]
                    in
                    Search.setCategorySuggestions state.categoryToken suggestions state
                        |> Expect.equal { state | categorySuggestions = suggestions }
            , test "the next category token is stale and leaves the state unchanged" <|
                \_ ->
                    let
                        state : QueryState
                        state =
                            Search.empty
                    in
                    Search.setCategorySuggestions
                        (Ticket.next state.categoryToken)
                        [ { value = "fruit", count = 3 } ]
                        state
                        |> Expect.equal state
            , fuzz3
                queryStateFuzzer
                ticketFuzzer
                (Fuzz.list suggestionFuzzer)
                "applies only the live category token"
              <|
                \state token suggestions ->
                    let
                        expected : QueryState
                        expected =
                            if token == state.categoryToken then
                                { state | categorySuggestions = suggestions }

                            else
                                state
                    in
                    Search.setCategorySuggestions token suggestions state
                        |> Expect.equal expected
            ]
        , describe "onQueryChangedDebounced"
            [ fuzz2 Fuzz.string queryStateFuzzer "shares onQueryChanged's state transition" <|
                \raw state ->
                    Tuple.first (Search.onQueryChangedDebounced raw state debounce)
                        |> Expect.equal (Tuple.first (Search.onQueryChanged raw state))
            , fuzz2 whitespaceFuzzer queryStateFuzzer "empty or whitespace emits no command" <|
                \raw state ->
                    let
                        ( next, command ) =
                            Search.onQueryChangedDebounced raw state debounce
                    in
                    Expect.all
                        [ \_ -> command |> Expect.equal Cmd.none
                        , \_ ->
                            next
                                |> Expect.equal (Tuple.first (Search.onQueryChanged raw state))
                        ]
                        ()
            , fuzz2 plainQueryFuzzer queryStateFuzzer "a non-empty query emits a command" <|
                \raw state ->
                    let
                        ( next, command ) =
                            Search.onQueryChangedDebounced raw state debounce
                    in
                    Expect.all
                        [ \_ -> command |> Expect.notEqual Cmd.none
                        , \_ ->
                            next
                                |> Expect.equal (Tuple.first (Search.onQueryChanged raw state))
                        ]
                        ()
            ]
        ]



-- Fuzzers


ticketFuzzer : Fuzzer Ticket
ticketFuzzer =
    Fuzz.map
        (\count ->
            List.foldl (\_ current -> Ticket.next current) Ticket.initial (List.range 1 count)
        )
        (Fuzz.intRange 0 50)


wordFuzzer : Fuzzer String
wordFuzzer =
    Fuzz.map (\value -> "word" ++ String.fromInt value) (Fuzz.intRange 0 1000)


categoryValueFuzzer : Fuzzer String
categoryValueFuzzer =
    Fuzz.map2
        (\first rest -> String.join " " (first :: rest))
        wordFuzzer
        (Fuzz.list wordFuzzer)


suggestionFuzzer : Fuzzer CategorySuggestion
suggestionFuzzer =
    Fuzz.map2
        (\value count -> { value = value, count = count })
        categoryValueFuzzer
        (Fuzz.intRange 0 1000)


completionFuzzer : Fuzzer Completion
completionFuzzer =
    Fuzz.oneOf
        [ Fuzz.map OperatorCompletion SupportFuzz.segment
        , Fuzz.map2 CategoryCompletion SupportFuzz.segment (Fuzz.intRange 0 1000)
        ]


completionsFuzzer : Fuzzer (List Completion)
completionsFuzzer =
    Fuzz.list completionFuzzer


uniqueCompletionsFuzzer : Fuzzer (List Completion)
uniqueCompletionsFuzzer =
    Fuzz.map
        (\count ->
            List.range 0 (count - 1)
                |> List.map
                    (\index ->
                        CategoryCompletion ("category-" ++ String.fromInt index) index
                    )
        )
        (Fuzz.intRange 0 20)


categoryCompletionsFuzzer : Fuzzer (List Completion)
categoryCompletionsFuzzer =
    Fuzz.list
        (Fuzz.map2 CategoryCompletion SupportFuzz.segment (Fuzz.intRange 0 1000))


queryStateFuzzer : Fuzzer QueryState
queryStateFuzzer =
    Fuzz.map4
        (\query searchToken categoryToken suggestions ->
            { query = query
            , searchToken = searchToken
            , categoryToken = categoryToken
            , categorySuggestions = suggestions
            }
        )
        Fuzz.string
        ticketFuzzer
        ticketFuzzer
        (Fuzz.list suggestionFuzzer)


categoryPrefixFuzzer : Fuzzer String
categoryPrefixFuzzer =
    Fuzz.oneOfValues [ "category:", "-category:" ]


completionPrefixFuzzer : Fuzzer String
completionPrefixFuzzer =
    Fuzz.map3
        (\leading previousTokens separator ->
            leading
                ++ List.foldl
                    (\token prefix -> prefix ++ Text.quoteIfWhitespace token ++ separator)
                    ""
                    previousTokens
        )
        (Fuzz.oneOfValues [ "", " ", "  ", "\t", "\n" ])
        (Fuzz.list (Fuzz.oneOf [ wordFuzzer, categoryValueFuzzer ]))
        (Fuzz.oneOfValues [ " ", "  ", "\t" ])


whitespaceFuzzer : Fuzzer String
whitespaceFuzzer =
    Fuzz.oneOfValues [ "", " ", "  ", "\t", "\n", "\u{000D}", " \t " ]


plainQueryFuzzer : Fuzzer String
plainQueryFuzzer =
    Fuzz.map2
        (\first rest -> String.join " " (first :: rest))
        wordFuzzer
        (Fuzz.list wordFuzzer)


operatorTokenFuzzer : Fuzzer ( String, String )
operatorTokenFuzzer =
    Fuzz.map2
        (\excluded length ->
            let
                operator : String
                operator =
                    if excluded then
                        "-category:"

                    else
                        "category:"
            in
            ( String.left length operator, operator )
        )
        (Fuzz.oneOfValues [ False, True ])
        (Fuzz.intRange 1 8)



-- Helpers


debounce : Search.Debounce ()
debounce =
    { delayMs = 0
    , onSearchElapsed = \_ _ -> ()
    , onCategoryElapsed = \_ _ -> ()
    }


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    case expectations of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map (\expectation _ -> expectation) expectations) ()


uniqueCompletions : List Completion -> List Completion
uniqueCompletions options =
    List.foldl
        (\completion unique ->
            if List.member completion unique then
                unique

            else
                unique ++ [ completion ]
        )
        []
        options


expectCompletionMember : List Completion -> Maybe Completion -> Expect.Expectation
expectCompletionMember options result =
    if List.isEmpty options then
        result |> Expect.equal Nothing

    else
        case result of
            Just chosen ->
                List.member chosen options |> Expect.equal True

            Nothing ->
                Expect.fail "non-empty options must yield a completion"
