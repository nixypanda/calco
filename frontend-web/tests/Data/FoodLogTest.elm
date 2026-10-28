module Data.FoodLogTest exposing (tests)

import Data.FoodLog as FoodLog exposing (LogItem(..))
import Data.ItemRef as ItemRef
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz3, test)


tests : Test
tests =
    describe "Data.FoodLog"
        [ fuzz3
            SupportFuzz.localDate
            SupportFuzz.maybeMealSlot
            SupportFuzz.foodLogList
            "logsForDate and logsForSlot are exact order-preserving filters"
          <|
            \date slot logs ->
                Expect.all
                    [ \_ ->
                        FoodLog.logsForDate date logs
                            |> Expect.equal
                                (List.filter
                                    (\log -> LocalDate.equals log.logDate date)
                                    logs
                                )
                    , \_ ->
                        FoodLog.logsForSlot slot logs
                            |> Expect.equal
                                (List.filter (\log -> log.mealSlot == slot) logs)
                    ]
                    ()
        , fuzz SupportFuzz.foodLog "name, brand, and ref follow the item shape" <|
            \log ->
                case log.item of
                    ProductLogItem product ->
                        Expect.all
                            [ \_ -> FoodLog.itemName log.item |> Expect.equal product.name
                            , \_ -> FoodLog.itemBrand log.item |> Expect.equal product.brand
                            , \_ ->
                                FoodLog.itemRef log.item
                                    |> Expect.equal
                                        (Just
                                            { itemType = ItemRef.Product
                                            , id = product.id
                                            }
                                        )
                            ]
                            ()

                    MealLogItem meal ->
                        Expect.all
                            [ \_ -> FoodLog.itemName log.item |> Expect.equal meal.name
                            , \_ -> FoodLog.itemBrand log.item |> Expect.equal Nothing
                            , \_ ->
                                FoodLog.itemRef log.item
                                    |> Expect.equal
                                        (Just
                                            { itemType = ItemRef.Meal
                                            , id = meal.id
                                            }
                                        )
                            ]
                            ()

                    AdHocLogItem adHoc ->
                        Expect.all
                            [ \_ -> FoodLog.itemName log.item |> Expect.equal adHoc.name
                            , \_ -> FoodLog.itemBrand log.item |> Expect.equal adHoc.brand
                            , \_ -> FoodLog.itemRef log.item |> Expect.equal Nothing
                            ]
                            ()
        , {- Intentional decoder leniency (plan section 6.5): an unknown meal
             slot decodes as `Nothing` instead of rejecting the whole log. This
             cannot be expressed as a roundtrip because the wire value has no
             domain representation.
          -}
          test "an unknown meal slot decodes as Nothing" <|
            \_ ->
                Decode.decodeValue FoodLog.decoder unknownSlotLog
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok Nothing)
        ]


unknownSlotLog : Encode.Value
unknownSlotLog =
    Encode.object
        [ ( "id", Encode.string "log-1" )
        , ( "log_date", Encode.string "2024-01-01" )
        , ( "device_timezone", Encode.null )
        , ( "meal_slot", Encode.string "brunch" )
        , ( "item"
          , Encode.object
                [ ( "type", Encode.string "ad_hoc" )
                , ( "name", Encode.string "Toast" )
                ]
          )
        , ( "quantity"
          , Encode.object
                [ ( "amount", Encode.string "1" )
                , ( "unit", Encode.string "g" )
                ]
          )
        , ( "nutrients", Encode.list Encode.string [] )
        , ( "notes", Encode.null )
        ]
