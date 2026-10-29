module Api.LogsTest exposing (tests)

import Api.Logs as Logs
import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.MealSlot as MealSlot
import Data.Nutrition as Nutrition
import Dict exposing (Dict)
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Api.Logs request encoders"
        [ fuzz createLogFuzzer
            "createLogRequestEncoder preserves required values and conditional context"
          <|
            \request ->
                case decodeObject (Logs.createLogRequestEncoder request) of
                    Err message ->
                        Expect.fail message

                    Ok fields ->
                        expectAll
                            [ expectValue "log_date"
                                Decode.string
                                (LocalDate.format request.logDate)
                                fields
                            , expectValue "item" ItemRef.decoder request.item fields
                            , expectValue "quantity"
                                Nutrition.quantityDecoder
                                request.quantity
                                fields
                            , expectNullableValue "notes" Decode.string request.notes fields
                            , expectOptionalValue "meal_slot"
                                Decode.string
                                (Maybe.map MealSlot.toString request.mealSlot)
                                fields
                            , expectOptionalValue "device_timezone"
                                Decode.string
                                request.deviceTimezone
                                fields
                            ]
        , fuzz updateLogFuzzer
            "updateLogRequestEncoder preserves quantity and nullable meal_slot/notes"
          <|
            \request ->
                case decodeObject (Logs.updateLogRequestEncoder request) of
                    Err message ->
                        Expect.fail message

                    Ok fields ->
                        expectAll
                            [ expectValue "quantity"
                                Nutrition.quantityDecoder
                                request.quantity
                                fields
                            , expectNullableValue "meal_slot"
                                Decode.string
                                (Maybe.map MealSlot.toString request.mealSlot)
                                fields
                            , expectNullableValue "notes" Decode.string request.notes fields
                            ]
        , fuzz createAdHocLogFuzzer
            "createAdHocLogRequestEncoder preserves required values and optional branches"
          <|
            \request ->
                case decodeObject (Logs.createAdHocLogRequestEncoder request) of
                    Err message ->
                        Expect.fail message

                    Ok fields ->
                        expectAll
                            [ expectValue "log_date"
                                Decode.string
                                (LocalDate.format request.logDate)
                                fields
                            , expectValue "name" Decode.string request.name fields
                            , expectValue "quantity"
                                Nutrition.quantityDecoder
                                request.quantity
                                fields
                            , expectValue "nutrients"
                                (Decode.list Nutrition.decoder)
                                request.nutrients
                                fields
                            , expectNullableValue "brand" Decode.string request.brand fields
                            , expectNullableValue "notes" Decode.string request.notes fields
                            , expectOptionalValue "meal_slot"
                                Decode.string
                                (Maybe.map MealSlot.toString request.mealSlot)
                                fields
                            , expectOptionalValue "device_timezone"
                                Decode.string
                                request.deviceTimezone
                                fields
                            ]
        ]


createLogFuzzer : Fuzzer Logs.CreateLogRequest
createLogFuzzer =
    Fuzz.map6
        (\logDate deviceTimezone mealSlot item quantity notes ->
            { logDate = logDate
            , deviceTimezone = deviceTimezone
            , mealSlot = mealSlot
            , item = item
            , quantity = quantity
            , notes = notes
            }
        )
        Support.localDate
        (Fuzz.maybe Fuzz.string)
        Support.maybeMealSlot
        itemRefFuzzer
        quantityFuzzer
        (Fuzz.maybe Fuzz.string)


updateLogFuzzer : Fuzzer Logs.UpdateLogRequest
updateLogFuzzer =
    Fuzz.map3
        (\mealSlot quantity notes ->
            { mealSlot = mealSlot, quantity = quantity, notes = notes }
        )
        Support.maybeMealSlot
        quantityFuzzer
        (Fuzz.maybe Fuzz.string)


createAdHocLogFuzzer : Fuzzer Logs.CreateAdHocLogRequest
createAdHocLogFuzzer =
    Fuzz.map8
        (\logDate deviceTimezone mealSlot name brand quantity nutrients notes ->
            { logDate = logDate
            , deviceTimezone = deviceTimezone
            , mealSlot = mealSlot
            , name = name
            , brand = brand
            , quantity = quantity
            , nutrients = nutrients
            , notes = notes
            }
        )
        Support.localDate
        (Fuzz.maybe Fuzz.string)
        Support.maybeMealSlot
        Fuzz.string
        (Fuzz.maybe Fuzz.string)
        quantityFuzzer
        (Fuzz.list nutrientFuzzer)
        (Fuzz.maybe Fuzz.string)


itemRefFuzzer : Fuzzer ItemRef
itemRefFuzzer =
    Fuzz.map2 ItemRef
        (Fuzz.oneOfValues [ ItemRef.Product, ItemRef.Meal ])
        Fuzz.string


quantityFuzzer : Fuzzer Nutrition.Quantity
quantityFuzzer =
    Fuzz.map2
        (\amount unit -> { amount = amount, unit = unit })
        Support.nonNegativeAmountString
        Support.segment


nutrientFuzzer : Fuzzer Nutrition.NutrientAmount
nutrientFuzzer =
    Fuzz.map3
        (\code amount unit -> { code = code, amount = amount, unit = unit })
        Support.segment
        Support.amountString
        Support.segment


decodeObject : Encode.Value -> Result String (Dict String Decode.Value)
decodeObject value =
    Decode.decodeValue (Decode.dict Decode.value) value
        |> Result.mapError (always "encoder did not produce a JSON object")


expectValue :
    String
    -> Decode.Decoder a
    -> a
    -> Dict String Decode.Value
    -> Expect.Expectation
expectValue key decoder expected fields =
    Dict.get key fields
        |> Maybe.map (Decode.decodeValue decoder)
        |> Expect.equal (Just (Ok expected))


expectNullableValue :
    String
    -> Decode.Decoder a
    -> Maybe a
    -> Dict String Decode.Value
    -> Expect.Expectation
expectNullableValue key decoder expected fields =
    Dict.get key fields
        |> Maybe.map (Decode.decodeValue (Decode.nullable decoder))
        |> Expect.equal (Just (Ok expected))


expectOptionalValue :
    String
    -> Decode.Decoder a
    -> Maybe a
    -> Dict String Decode.Value
    -> Expect.Expectation
expectOptionalValue key decoder expected fields =
    case expected of
        Nothing ->
            Dict.member key fields
                |> Expect.equal False

        Just value ->
            Dict.get key fields
                |> Maybe.map (Decode.decodeValue decoder)
                |> Expect.equal (Just (Ok value))


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()
