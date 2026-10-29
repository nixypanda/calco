module Lib.TextTest exposing (tests)

import Expect
import Fuzz exposing (Fuzzer)
import Lib.Text as Text
import Test exposing (Test, describe, fuzz, fuzz2)


tests : Test
tests =
    describe "Lib.Text"
        [ fuzz2 Fuzz.string Fuzz.string "blank helpers agree on blankness and trimming" <|
            \fallback raw ->
                let
                    expected : String
                    expected =
                        if Text.isBlank raw then
                            fallback

                        else
                            String.trim raw
                in
                ( Text.blankToMaybe raw == Nothing
                , Text.trimOrDefault fallback raw
                , Text.requireTrimmed fallback raw
                )
                    |> Expect.equal
                        ( Text.isBlank raw
                        , expected
                        , Result.fromMaybe fallback (Text.blankToMaybe raw)
                        )
        , fuzz commaInput
            "commaSeparatedUniqueLower normalizes, deduplicates, and keeps first-seen order"
          <|
            \raw ->
                let
                    entries : List String
                    entries =
                        Text.commaSeparatedUniqueLower raw

                    expected : List String
                    expected =
                        raw |> String.split "," |> List.filterMap normalizeToken |> firstUnique
                in
                Expect.all
                    [ \_ -> entries |> Expect.equal expected
                    , \_ ->
                        entries
                            |> String.join ","
                            |> Text.commaSeparatedUniqueLower
                            |> Expect.equal entries
                    ]
                    ()
        , fuzz separatorFuzzer
            "splitQuotedWhitespace is lossless and preserves separators and quoted whitespace"
          <|
            \separator ->
                let
                    quoted : String
                    quoted =
                        "before" ++ separator ++ "\"a b\"" ++ separator ++ "after"
                in
                Expect.all
                    [ \_ ->
                        Text.splitQuotedWhitespace ("a" ++ separator ++ "b")
                            |> Expect.equal [ "a", separator, "b" ]
                    , \_ ->
                        Text.splitQuotedWhitespace quoted
                            |> Expect.equal
                                [ "before", separator, "\"a b\"", separator, "after" ]
                    , \_ ->
                        Text.splitQuotedWhitespace quoted |> String.concat |> Expect.equal quoted
                    , \_ ->
                        Text.splitQuotedWhitespace (separator ++ "category:dairy")
                            |> Expect.equal [ "", separator, "category:dairy" ]
                    , \_ ->
                        Text.splitQuotedWhitespace ("a" ++ separator ++ separator ++ "b")
                            |> Expect.equal [ "a", separator, "", separator, "b" ]
                    ]
                    ()
        , fuzz textWithoutBoundaryQuote
            "quoteIfWhitespace quotes exactly whitespace and stripBoundingQuotes inverts it"
          <|
            \value ->
                let
                    quoted : String
                    quoted =
                        Text.quoteIfWhitespace value

                    expected : String
                    expected =
                        if containsWhitespace value then
                            "\"" ++ value ++ "\""

                        else
                            value
                in
                ( quoted, Text.stripBoundingQuotes quoted ) |> Expect.equal ( expected, value )
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


firstUnique : List String -> List String
firstUnique values =
    List.foldl
        (\value unique ->
            if List.member value unique then
                unique

            else
                unique ++ [ value ]
        )
        []
        values


separatorFuzzer : Fuzzer String
separatorFuzzer =
    Fuzz.oneOfValues [ " ", "\t", "\n", "\u{000D}" ]


{-| Arbitrary trimmed strings that do not start or end with a double quote.
`Fuzz.filter` retries at most 15 times; a boundary quote is rare, so the filter
rejects very few values and does not bias the generator toward shorter strings.
-}
textWithoutBoundaryQuote : Fuzzer String
textWithoutBoundaryQuote =
    Fuzz.string
        |> Fuzz.map String.trim
        |> Fuzz.filter
            (\value ->
                not (String.startsWith "\"" value) && not (String.endsWith "\"" value)
            )


containsWhitespace : String -> Bool
containsWhitespace value =
    String.any (\char -> List.member char [ ' ', '\n', '\t', '\u{000D}' ]) value
