module Lib.JsonTest exposing (tests)

import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Lib.Json as Json
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Lib.Json"
        [ fuzz (Fuzz.maybe Fuzz.string)
            "Json.maybe and Decode.nullable round trip Maybe values"
          <|
            \value ->
                Json.maybe Encode.string value
                    |> Decode.decodeValue (Decode.nullable Decode.string)
                    |> Expect.equal (Ok value)
        , fuzz payloadFuzzer "Json.andMap decodes every field" <|
            \payload ->
                payload
                    |> payloadEncoder
                    |> Decode.decodeValue payloadDecoder
                    |> Expect.equal (Ok payload)
        ]


type alias Payload =
    { name : String
    , count : Int
    , amount : Float
    , enabled : Bool
    }


payloadFuzzer : Fuzzer Payload
payloadFuzzer =
    Fuzz.map4 Payload
        Fuzz.string
        (Fuzz.intRange -1000000 1000000)
        Fuzz.niceFloat
        Fuzz.bool


payloadDecoder : Decoder Payload
payloadDecoder =
    Decode.map Payload
        (Decode.field "name" Decode.string)
        |> Json.andMap (Decode.field "count" Decode.int)
        |> Json.andMap (Decode.field "amount" Decode.float)
        |> Json.andMap (Decode.field "enabled" Decode.bool)


payloadEncoder : Payload -> Encode.Value
payloadEncoder payload =
    Encode.object
        [ ( "name", Encode.string payload.name )
        , ( "count", Encode.int payload.count )
        , ( "amount", Encode.float payload.amount )
        , ( "enabled", Encode.bool payload.enabled )
        ]
