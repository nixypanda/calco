module Data.SearchTest exposing (tests)

import Data.Search as Search exposing (CategorySuggestion, Completion(..), QueryState)
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Platform.Cmd as Cmd
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "Data.Search"
        [ fuzz uniqueCompletionsFuzzer
            "completion navigation moves exactly one step and clamps at both ends"
          <|
            \options ->
                navigationExpectations options
                    |> expectAll
        , fuzz2 completionFuzzer
            completionsFuzzer
            "completionIndex reports the first exact index or Nothing"
          <|
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
        , fuzz applyCaseFuzzer
            "applyCompletion replaces only the last token and category values roundtrip"
          <|
            \caseValue ->
                case caseValue of
                    OperatorApply prefix token ->
                        let
                            label : String
                            label =
                                "replacement-" ++ token
                        in
                        Search.applyCompletion (OperatorCompletion label) (prefix ++ token)
                            |> Expect.equal (prefix ++ label)

                    CategoryApply prefix value ->
                        let
                            replacement : String
                            replacement =
                                prefix ++ Text.quoteIfWhitespace value

                            applied : String
                            applied =
                                Search.applyCompletion
                                    (CategoryCompletion replacement 1)
                                    ("apple " ++ prefix ++ "typed")
                        in
                        Expect.all
                            [ \_ -> applied |> Expect.equal ("apple " ++ replacement)
                            , \_ -> Search.categoryQuery applied |> Expect.equal (Just value)
                            ]
                            ()
        , fuzz completionsCaseFuzzer
            "completions handles operator, empty, category, plain, and non-category colon tokens"
          <|
            \caseValue ->
                Expect.all
                    [ \_ -> Search.completions "apple" [] |> Expect.equal []
                    , \_ ->
                        Search.completions caseValue.query caseValue.suggestions
                            |> Expect.equal caseValue.expected
                    ]
                    ()
        , fuzz3
            queryInputFuzzer
            (Fuzz.list suggestionFuzzer)
            queryStateFuzzer
            "onQueryChanged advances tokens, preserves query text, and gates category requests"
          <|
            \raw suggestions state ->
                let
                    ( next, request ) =
                        Search.onQueryChanged raw state

                    categoryValue : Maybe String
                    categoryValue =
                        Search.categoryQuery raw

                    expectedRequest : Maybe Search.CategoryRequest
                    expectedRequest =
                        categoryValue
                            |> Maybe.map
                                (\value ->
                                    { token = Ticket.next state.categoryToken, query = value }
                                )

                    expectedSuggestions : List CategorySuggestion
                    expectedSuggestions =
                        case categoryValue of
                            Nothing ->
                                []

                            Just _ ->
                                if String.isEmpty (String.trim raw) then
                                    []

                                else
                                    state.categorySuggestions
                in
                Expect.all
                    [ \_ ->
                        next.searchToken
                            |> Expect.equal (Ticket.next state.searchToken)
                    , \_ ->
                        next.categoryToken
                            |> Expect.equal (Ticket.next state.categoryToken)
                    , \_ -> next.query |> Expect.equal raw
                    , \_ -> request |> Expect.equal expectedRequest
                    , \_ ->
                        next.categorySuggestions
                            |> Expect.equal expectedSuggestions
                    , \_ ->
                        Search.setCategorySuggestions next.categoryToken suggestions next
                            |> Expect.equal { next | categorySuggestions = suggestions }
                    , \_ ->
                        Search.setCategorySuggestions
                            (Ticket.next next.categoryToken)
                            suggestions
                            next
                            |> Expect.equal next
                    ]
                    ()
        , fuzz2 queryInputFuzzer
            queryStateFuzzer
            "onQueryChangedDebounced shares the state transition and commands only non-empty text"
          <|
            \raw state ->
                let
                    ( next, command ) =
                        Search.onQueryChangedDebounced raw state debounce

                    ( expectedState, _ ) =
                        Search.onQueryChanged raw state
                in
                Expect.all
                    [ \_ -> next |> Expect.equal expectedState
                    , \_ ->
                        (command == Cmd.none)
                            |> Expect.equal (String.isEmpty (String.trim raw))
                    ]
                    ()
        ]


type ApplyCase
    = OperatorApply String String
    | CategoryApply String String


type alias CompletionsCase =
    { query : String
    , suggestions : List CategorySuggestion
    , expected : List Completion
    }


applyCaseFuzzer : Fuzzer ApplyCase
applyCaseFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 OperatorApply completionPrefixFuzzer wordFuzzer
        , Fuzz.map2 CategoryApply categoryPrefixFuzzer categoryValueFuzzer
        ]


completionsCaseFuzzer : Fuzzer CompletionsCase
completionsCaseFuzzer =
    Fuzz.oneOf
        [ Fuzz.map
            (\( token, operator ) ->
                { query = token, suggestions = [], expected = [ OperatorCompletion operator ] }
            )
            operatorTokenFuzzer
        , Fuzz.map2
            (\query suggestions ->
                { query = query, suggestions = suggestions, expected = [] }
            )
            whitespaceFuzzer
            (Fuzz.list suggestionFuzzer)
        , Fuzz.map2
            (\prefix suggestions ->
                { query = prefix ++ "typed"
                , suggestions = suggestions
                , expected =
                    List.map
                        (\suggestion ->
                            CategoryCompletion
                                (prefix ++ Text.quoteIfWhitespace suggestion.value)
                                suggestion.count
                        )
                        suggestions
                }
            )
            categoryPrefixFuzzer
            (Fuzz.list suggestionFuzzer)
        , Fuzz.map2
            (\word suggestions ->
                { query = word, suggestions = suggestions, expected = [] }
            )
            wordFuzzer
            (Fuzz.list suggestionFuzzer)
        , Fuzz.map2
            (\word suggestions ->
                { query = "foo:" ++ word, suggestions = suggestions, expected = [] }
            )
            wordFuzzer
            (Fuzz.list suggestionFuzzer)
        ]


navigationExpectations : List Completion -> List Expect.Expectation
navigationExpectations options =
    [ Search.nextCompletion Nothing options |> Expect.equal (List.head options)
    , Search.previousCompletion Nothing options |> Expect.equal (List.head options)
    , Search.nextCompletion (Just missingCompletion) options |> Expect.equal (List.head options)
    , Search.previousCompletion (Just missingCompletion) options
        |> Expect.equal (List.head options)
    ]
        ++ List.indexedMap
            (\index option ->
                let
                    nextExpected : Completion
                    nextExpected =
                        List.drop (index + 1) options
                            |> List.head
                            |> Maybe.withDefault option

                    previousExpected : Completion
                    previousExpected =
                        List.drop (max 0 (index - 1)) options
                            |> List.head
                            |> Maybe.withDefault option
                in
                Expect.all
                    [ \_ ->
                        Search.nextCompletion (Just option) options
                            |> Expect.equal (Just nextExpected)
                    , \_ ->
                        Search.previousCompletion (Just option) options
                            |> Expect.equal (Just previousExpected)
                    ]
                    ()
            )
            options


missingCompletion : Completion
missingCompletion =
    OperatorCompletion "missing-option"


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


queryInputFuzzer : Fuzzer String
queryInputFuzzer =
    Fuzz.oneOf
        [ whitespaceFuzzer
        , plainQueryFuzzer
        , Fuzz.map2
            (\prefix value -> prefix ++ Text.quoteIfWhitespace value)
            categoryPrefixFuzzer
            categoryValueFuzzer
        ]


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


debounce : Search.Debounce ()
debounce =
    { delayMs = 0
    , onSearchElapsed = \_ _ -> ()
    , onCategoryElapsed = \_ _ -> ()
    }


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()
