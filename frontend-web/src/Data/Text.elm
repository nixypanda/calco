module Data.Text exposing (blankToMaybe, isBlank, trimOrDefault)


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
