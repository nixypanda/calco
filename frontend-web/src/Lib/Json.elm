module Lib.Json exposing (andMap, maybe)

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


maybe : (a -> Encode.Value) -> Maybe a -> Encode.Value
maybe encoder maybeValue =
    case maybeValue of
        Just value ->
            encoder value

        Nothing ->
            Encode.null


andMap : Decoder value -> Decoder (value -> result) -> Decoder result
andMap valueDecoder functionDecoder =
    Decode.map2 (<|) functionDecoder valueDecoder
