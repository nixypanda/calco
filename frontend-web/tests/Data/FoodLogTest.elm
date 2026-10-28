module Data.FoodLogTest exposing (tests)

import Data.FoodLog as FoodLog exposing (FoodLog, LogItem(..))
import Data.ItemRef as ItemRef
import Data.MealSlot as MealSlot exposing (MealSlot)
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Support.Fixtures as Fixtures
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, test)


tests : Test
tests =
    describe "Data.FoodLog"
        [ describe "logsForDate"
            [ fuzz2
                SupportFuzz.localDate
                SupportFuzz.foodLogList
                "is a filter for the requested date"
              <|
                \date logs ->
                    let
                        selected : List FoodLog
                        selected =
                            FoodLog.logsForDate date logs
                    in
                    Expect.all
                        [ \_ ->
                            List.all
                                (\log -> LocalDate.equals log.logDate date)
                                selected
                                |> Expect.equal True
                        , \_ ->
                            List.length selected
                                |> Expect.equal
                                    (List.length
                                        (List.filter
                                            (\log -> LocalDate.equals log.logDate date)
                                            logs
                                        )
                                    )
                        , \_ ->
                            List.all
                                (\log ->
                                    not (LocalDate.equals log.logDate date)
                                        || List.member log selected
                                )
                                logs
                                |> Expect.equal True
                        ]
                        ()
            , fuzz2
                SupportFuzz.localDate
                SupportFuzz.foodLogList
                "preserves the input order of matching logs"
              <|
                \date logs ->
                    let
                        matching : List FoodLog
                        matching =
                            [ sampleLog "ordered-a" date Nothing
                            , sampleLog "ordered-b" date Nothing
                            , sampleLog "ordered-c" date Nothing
                            ]

                        allLogs : List FoodLog
                        allLogs =
                            matching ++ logs
                    in
                    FoodLog.logsForDate date allLogs
                        |> Expect.equal
                            (List.filter (\log -> LocalDate.equals log.logDate date) allLogs)
            ]
        , describe "logsForSlot"
            [ fuzz2
                SupportFuzz.maybeMealSlot
                SupportFuzz.foodLogList
                "is a filter for the requested slot"
              <|
                \slot logs ->
                    let
                        selected : List FoodLog
                        selected =
                            FoodLog.logsForSlot slot logs
                    in
                    Expect.all
                        [ \_ ->
                            List.all (\log -> log.mealSlot == slot) selected
                                |> Expect.equal True
                        , \_ ->
                            List.length selected
                                |> Expect.equal
                                    (List.length
                                        (List.filter (\log -> log.mealSlot == slot) logs)
                                    )
                        , \_ ->
                            List.all
                                (\log -> log.mealSlot /= slot || List.member log selected)
                                logs
                                |> Expect.equal True
                        ]
                        ()
            , fuzz2
                SupportFuzz.maybeMealSlot
                SupportFuzz.foodLogList
                "preserves the input order of matching logs"
              <|
                \slot logs ->
                    let
                        matching : List FoodLog
                        matching =
                            [ sampleLog "ordered-a" Fixtures.today slot
                            , sampleLog "ordered-b" Fixtures.today slot
                            , sampleLog "ordered-c" Fixtures.today slot
                            ]

                        allLogs : List FoodLog
                        allLogs =
                            matching ++ logs
                    in
                    FoodLog.logsForSlot slot allLogs
                        |> Expect.equal
                            (List.filter (\log -> log.mealSlot == slot) allLogs)
            ]
        , describe "buckets"
            [ fuzz SupportFuzz.foodLogList "date buckets partition the log list" <|
                \logs ->
                    let
                        buckets : List (List FoodLog)
                        buckets =
                            List.map (\date -> FoodLog.logsForDate date logs) (distinctDates logs)

                        flattened : List FoodLog
                        flattened =
                            List.concat buckets
                    in
                    Expect.all
                        [ \_ -> List.length flattened |> Expect.equal (List.length logs)
                        , \_ ->
                            List.all
                                (\log ->
                                    countOccurrences log flattened
                                        == countOccurrences log logs
                                )
                                logs
                                |> Expect.equal True
                        ]
                        ()
            , fuzz SupportFuzz.foodLogList "slot buckets partition the log list" <|
                \logs ->
                    let
                        slots : List (Maybe MealSlot)
                        slots =
                            Nothing :: List.map Just MealSlot.all

                        buckets : List (List FoodLog)
                        buckets =
                            List.map (\slot -> FoodLog.logsForSlot slot logs) slots

                        flattened : List FoodLog
                        flattened =
                            List.concat buckets
                    in
                    Expect.all
                        [ \_ -> List.length flattened |> Expect.equal (List.length logs)
                        , \_ ->
                            List.all
                                (\log ->
                                    countOccurrences log flattened
                                        == countOccurrences log logs
                                )
                                logs
                                |> Expect.equal True
                        ]
                        ()
            ]
        , describe "item accessors"
            [ fuzz SupportFuzz.foodLog "name, brand, and ref follow the item shape" <|
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
            ]
        , describe "decoder exception"
            [ {- Intentional decoder leniency (plan section 6.5): an unknown meal
                 slot decodes as `Nothing` instead of rejecting the whole log.
              -}
              test "an unknown meal slot decodes as Nothing" <|
                \_ ->
                    Decode.decodeValue FoodLog.decoder unknownSlotLog
                        |> Result.map .mealSlot
                        |> Expect.equal (Ok Nothing)
            ]
        ]



-- Decoder exception fixture


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



-- References


{-| A minimal log used to force several entries to share a date or slot, so the
order laws are deterministic rather than depending on the fuzzer colliding
two randomly generated dates.
-}
sampleLog : String -> LocalDate -> Maybe MealSlot -> FoodLog
sampleLog id date slot =
    { id = id
    , logDate = date
    , deviceTimezone = Nothing
    , mealSlot = slot
    , item = AdHocLogItem { name = id, brand = Nothing }
    , quantity = { amount = "1", unit = "g" }
    , nutrients = []
    , notes = Nothing
    }


distinctDates : List FoodLog -> List LocalDate
distinctDates logs =
    List.foldl
        (\log dates ->
            if List.any (\date -> LocalDate.equals date log.logDate) dates then
                dates

            else
                dates ++ [ log.logDate ]
        )
        []
        logs


countOccurrences : a -> List a -> Int
countOccurrences value list =
    List.length (List.filter ((==) value) list)
