module Data.LogSummary exposing
    ( DaySummary
    , fromLogs
    , listDecoder
    )

import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)


type alias DaySummary =
    { date : LocalDate, energyKcal : Float, proteinG : Float, carbsG : Float, fatG : Float }


fromLogs : LocalDate -> List { log | nutrients : List NutrientAmount } -> Maybe DaySummary
fromLogs date logs =
    if List.isEmpty logs then
        Nothing

    else
        Just
            { date = date
            , energyKcal = Nutrition.sumNutrient "ENERGY_KCAL" logs
            , proteinG = Nutrition.sumNutrient "PROTEIN_G" logs
            , carbsG = Nutrition.sumNutrient "CARBS_G" logs
            , fatG = Nutrition.sumNutrient "FAT_G" logs
            }


decoder : Decoder DaySummary
decoder =
    Decode.map5 DaySummary
        (Decode.field "date" LocalDate.decoder)
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
