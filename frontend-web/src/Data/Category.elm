module Data.Category exposing (formatInput, normalize, parseInput)


normalize : String -> Maybe String
normalize raw =
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


parseInput : String -> List String
parseInput raw =
    raw
        |> String.split ","
        |> List.foldl addUnique []
        |> List.reverse


formatInput : List String -> String
formatInput categories =
    String.join ", " categories


addUnique : String -> List String -> List String
addUnique raw categories =
    case normalize raw of
        Just category ->
            if List.member category categories then
                categories

            else
                category :: categories

        Nothing ->
            categories
