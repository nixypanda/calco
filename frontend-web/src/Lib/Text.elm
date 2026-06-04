module Lib.Text exposing
    ( blankToMaybe
    , commaSeparatedUniqueLower
    , isBlank
    , isWhitespace
    , quoteIfWhitespace
    , splitQuotedWhitespace
    , stripBoundingQuotes
    , trimLeadingQuote
    , trimOrDefault
    , trimTrailingQuote
    )


isBlank : String -> Bool
isBlank value =
    String.isEmpty (String.trim value)


blankToMaybe : String -> Maybe String
blankToMaybe raw =
    let
        trimmed : String
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just trimmed


trimOrDefault : String -> String -> String
trimOrDefault fallback raw =
    case blankToMaybe raw of
        Just value ->
            value

        Nothing ->
            fallback


commaSeparatedUniqueLower : String -> List String
commaSeparatedUniqueLower raw =
    raw
        |> String.split ","
        |> List.foldl addUniqueLower []
        |> List.reverse


splitQuotedWhitespace : String -> List String
splitQuotedWhitespace raw =
    raw
        |> String.toList
        |> List.foldl tokenStep { current = "", parts = [], inQuotes = False }
        |> finishTokens


stripBoundingQuotes : String -> String
stripBoundingQuotes value =
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


quoteIfWhitespace : String -> String
quoteIfWhitespace value =
    if String.any isWhitespace value then
        "\"" ++ value ++ "\""

    else
        value


isWhitespace : Char -> Bool
isWhitespace char =
    List.member char [ ' ', '\n', '\t', '\u{000D}' ]


addUniqueLower : String -> List String -> List String
addUniqueLower raw categories =
    case normalizeLower raw of
        Just category ->
            if List.member category categories then
                categories

            else
                category :: categories

        Nothing ->
            categories


normalizeLower : String -> Maybe String
normalizeLower raw =
    let
        value : String
        value =
            raw
                |> String.trim
                |> String.toLower
    in
    if String.isEmpty value then
        Nothing

    else
        Just value


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
