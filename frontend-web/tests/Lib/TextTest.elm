module Lib.TextTest exposing (tests)

import Char
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Text as Text
import Test exposing (Test, describe, fuzz, fuzz2)


tests : Test
tests =
    describe "Lib.Text"
        [ fuzz Fuzz.string "blankToMaybe agrees with isBlank" <|
            \raw ->
                (Text.blankToMaybe raw == Nothing)
                    |> Expect.equal (Text.isBlank raw)
        , fuzz Fuzz.string "blankToMaybe is invariant under trimming" <|
            \raw ->
                Text.blankToMaybe (String.trim raw)
                    |> Expect.equal (Text.blankToMaybe raw)
        , fuzz2 Fuzz.string
            Fuzz.string
            "trimOrDefault is trim for non-blanks and fallback for blanks"
          <|
            \fallback raw ->
                Text.trimOrDefault fallback raw
                    |> Expect.equal
                        (if Text.isBlank raw then
                            fallback

                         else
                            String.trim raw
                        )
        , fuzz2 Fuzz.string
            Fuzz.string
            "requireTrimmed matches blankToMaybe mapped into Result"
          <|
            \problem raw ->
                Text.requireTrimmed problem raw
                    |> Expect.equal
                        (case Text.blankToMaybe raw of
                            Just value ->
                                Ok value

                            Nothing ->
                                Err problem
                        )
        , fuzz commaInput "commaSeparatedUniqueLower emits normalized unique entries" <|
            \raw ->
                let
                    entries : List String
                    entries =
                        Text.commaSeparatedUniqueLower raw

                    inputTokens : List String
                    inputTokens =
                        normalizedTokens raw
                in
                Expect.all
                    [ \_ -> List.all isNormalizedEntry entries |> Expect.equal True
                    , \_ -> hasNoDuplicates entries |> Expect.equal True
                    , \_ ->
                        List.all (\entry -> List.member entry inputTokens) entries
                            |> Expect.equal True
                    ]
                    ()
        , fuzz commaInput
            "commaSeparatedUniqueLower preserves first-occurrence order and completeness"
          <|
            \raw ->
                let
                    entries : List String
                    entries =
                        Text.commaSeparatedUniqueLower raw

                    inputTokens : List String
                    inputTokens =
                        normalizedTokens raw

                    firstIndices : List Int
                    firstIndices =
                        List.filterMap (\entry -> firstIndex entry inputTokens) entries
                in
                Expect.all
                    [ \_ -> List.length firstIndices |> Expect.equal (List.length entries)
                    , \_ -> isStrictlyIncreasing firstIndices |> Expect.equal True
                    , \_ ->
                        List.all (\token -> List.member token entries) inputTokens
                            |> Expect.equal True
                    ]
                    ()
        , fuzz commaInput "commaSeparatedUniqueLower is idempotent when re-joined" <|
            \raw ->
                let
                    entries : List String
                    entries =
                        Text.commaSeparatedUniqueLower raw
                in
                entries
                    |> String.join ","
                    |> Text.commaSeparatedUniqueLower
                    |> Expect.equal entries
        , fuzz Fuzz.string "splitQuotedWhitespace is lossless" <|
            \raw ->
                Text.splitQuotedWhitespace raw
                    |> String.concat
                    |> Expect.equal raw
        , fuzz2 separatorFuzzer
            (Fuzz.listOfLengthBetween 1 6 wordFuzzer)
            "splitQuotedWhitespace splits on every supported whitespace separator"
          <|
            \separator words ->
                Text.splitQuotedWhitespace (String.join separator words)
                    |> Expect.equal (alternatingTokens separator words)
        , fuzz separatorFuzzer
            "splitQuotedWhitespace preserves leading, trailing, and repeated separators"
          <|
            \separator ->
                Expect.all
                    [ \_ ->
                        Text.splitQuotedWhitespace (separator ++ "category:dairy")
                            |> Expect.equal [ "", separator, "category:dairy" ]
                    , \_ ->
                        Text.splitQuotedWhitespace ("a" ++ separator)
                            |> Expect.equal [ "a", separator, "" ]
                    , \_ ->
                        Text.splitQuotedWhitespace ("a" ++ separator ++ separator ++ "b")
                            |> Expect.equal [ "a", separator, "", separator, "b" ]
                    ]
                    ()
        , fuzz2 separatorFuzzer
            (Fuzz.listOfLengthBetween 2 5 wordFuzzer)
            "splitQuotedWhitespace keeps quoted whitespace in one token for every separator"
          <|
            \separator words ->
                let
                    phrase : String
                    phrase =
                        String.join separator words

                    input : String
                    input =
                        "before"
                            ++ separator
                            ++ "\""
                            ++ phrase
                            ++ "\""
                            ++ separator
                            ++ "after"
                in
                Text.splitQuotedWhitespace input
                    |> Expect.equal
                        [ "before"
                        , separator
                        , "\"" ++ phrase ++ "\""
                        , separator
                        , "after"
                        ]
        , fuzz textWithoutBoundaryQuote "stripBoundingQuotes inverts quoteIfWhitespace" <|
            \value ->
                Text.quoteIfWhitespace value
                    |> Text.stripBoundingQuotes
                    |> Expect.equal value
        , fuzz Fuzz.string "quoteIfWhitespace adds exactly the surrounding quotes" <|
            \value ->
                let
                    quoted : String
                    quoted =
                        Text.quoteIfWhitespace value
                in
                if containsWhitespace value then
                    Expect.all
                        [ \_ -> String.startsWith "\"" quoted |> Expect.equal True
                        , \_ -> String.endsWith "\"" quoted |> Expect.equal True
                        , \_ ->
                            String.dropLeft 1 (String.dropRight 1 quoted)
                                |> Expect.equal value
                        ]
                        ()

                else
                    quoted |> Expect.equal value
        ]


commaInput : Fuzzer String
commaInput =
    Fuzz.frequency
        [ ( 1, Fuzz.string )
        , ( 3
          , Fuzz.listOfLengthBetween 0 8 (Fuzz.stringOfLengthBetween 0 6)
                |> Fuzz.map (String.join ",")
          )
        ]


normalizedTokens : String -> List String
normalizedTokens raw =
    raw
        |> String.split ","
        |> List.filterMap normalizeToken


normalizeToken : String -> Maybe String
normalizeToken raw =
    let
        trimmed : String
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just (String.toLower trimmed)


isNormalizedEntry : String -> Bool
isNormalizedEntry entry =
    not (Text.isBlank entry)
        && (String.trim entry == entry)
        && (String.toLower entry == entry)


hasNoDuplicates : List a -> Bool
hasNoDuplicates items =
    List.length items == List.length (List.foldl keepFirst [] items)


keepFirst : a -> List a -> List a
keepFirst item seen =
    if List.member item seen then
        seen

    else
        item :: seen


firstIndex : a -> List a -> Maybe Int
firstIndex target items =
    items
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, item ) -> item == target)
        |> List.head
        |> Maybe.map Tuple.first


isStrictlyIncreasing : List Int -> Bool
isStrictlyIncreasing indices =
    case indices of
        first :: second :: rest ->
            first < second && isStrictlyIncreasing (second :: rest)

        _ ->
            True


wordFuzzer : Fuzzer String
wordFuzzer =
    Fuzz.listOfLengthBetween 1 5 letterFuzzer
        |> Fuzz.map String.fromList


letterFuzzer : Fuzzer Char
letterFuzzer =
    Fuzz.oneOfValues (List.map Char.fromCode (List.range 97 122))


separatorFuzzer : Fuzzer String
separatorFuzzer =
    Fuzz.oneOfValues [ " ", "\t", "\n", "\u{000D}" ]


alternatingTokens : String -> List String -> List String
alternatingTokens separator words =
    case words of
        [] ->
            []

        first :: rest ->
            first
                :: List.concatMap (\word -> [ separator, word ]) rest


{-| Arbitrary trimmed strings that do not start or end with a double quote.

`Fuzz.filter` retries at most 15 times. A boundary quote is rare in
`Fuzz.string`, so the filter rejects very few values and does not bias the
generator toward shorter or otherwise special strings. Interior quotes are
allowed and deliberately exercised.

-}
textWithoutBoundaryQuote : Fuzzer String
textWithoutBoundaryQuote =
    Fuzz.string
        |> Fuzz.map String.trim
        |> Fuzz.filter
            (\value ->
                not (String.startsWith "\"" value)
                    && not (String.endsWith "\"" value)
            )


containsWhitespace : String -> Bool
containsWhitespace value =
    String.any
        (\char -> List.member char [ ' ', '\n', '\t', '\u{000D}' ])
        value
