module Data.LogSummary exposing
    ( DaySummary
    , listDecoder
    )

import Json.Decode as Decode exposing (Decoder)


type alias DaySummary =
    { date : String
    , energyKcal : Float
    , proteinG : Float
    , carbsG : Float
    , fatG : Float
    }


decoder : Decoder DaySummary
decoder =
    Decode.map5 DaySummary
        (Decode.field "date" Decode.string)
        (Decode.field "energy_kcal" decimalDecoder)
        (Decode.field "protein_g" decimalDecoder)
        (Decode.field "carbs_g" decimalDecoder)
        (Decode.field "fat_g" decimalDecoder)


listDecoder : Decoder (List DaySummary)
listDecoder =
    Decode.field "days" (Decode.list decoder)


decimalDecoder : Decoder Float
decimalDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case String.toFloat raw of
                    Just value ->
                        Decode.succeed value

                    Nothing ->
                        Decode.fail "Expected a decimal string"
            )
