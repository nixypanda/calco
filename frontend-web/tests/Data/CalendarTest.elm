module Data.CalendarTest exposing (tests)

import Data.Calendar as Calendar
import Expect
import Lib.Date as LocalDate
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.Calendar"
        [ test "shifts months across year boundaries" <|
            \_ ->
                ( Calendar.shiftMonth -1 "2026-01"
                , Calendar.shiftMonth 1 "2026-12"
                )
                    |> Expect.equal ( "2025-12", "2027-01" )
        , test "builds a complete Sunday-first leap-month grid" <|
            \_ ->
                Calendar.monthCells "2024-02"
                    |> Expect.equal
                        ([ Nothing, Nothing, Nothing, Nothing ]
                            ++ List.map Just (List.range 1 29)
                            ++ [ Nothing, Nothing ]
                        )
        , test "returns month boundaries as local dates" <|
            \_ ->
                ( Calendar.monthStart "2026-07"
                , Calendar.monthEnd "2026-07"
                )
                    |> Expect.equal
                        ( LocalDate.fromString "2026-07-01"
                        , LocalDate.fromString "2026-07-31"
                        )
        , test "creates descending month ranges" <|
            \_ ->
                Calendar.monthsDescending 4 "2026-02"
                    |> Expect.equal
                        [ "2026-02", "2026-01", "2025-12", "2025-11" ]
        ]
