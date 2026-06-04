module JsonTest exposing (tests)

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Json as Json
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Lib.Json"
        [ test "maybe encodes Just values with the provided encoder" <|
            \_ ->
                Json.maybe Encode.string (Just "notes")
                    |> Encode.encode 0
                    |> Expect.equal "\"notes\""
        , test "maybe encodes Nothing as null" <|
            \_ ->
                Json.maybe Encode.string Nothing
                    |> Encode.encode 0
                    |> Expect.equal "null"
        , test "andMap applies additional decoder fields" <|
            \_ ->
                Decode.decodeString pairDecoder """{"left":"a","right":2}"""
                    |> Expect.equal (Ok ( "a", 2 ))
        ]


pairDecoder : Decode.Decoder ( String, Int )
pairDecoder =
    Decode.map Tuple.pair
        (Decode.field "left" Decode.string)
        |> Json.andMap (Decode.field "right" Decode.int)
