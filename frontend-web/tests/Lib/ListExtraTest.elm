module Lib.ListExtraTest exposing (tests)

import Expect
import Lib.ListExtra as ListExtra
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Lib.ListExtra"
        [ test "updates item at index" <|
            \_ ->
                ListExtra.updateAt 1 ((+) 10) [ 1, 2, 3 ]
                    |> Expect.equal [ 1, 12, 3 ]
        , test "removes item at index" <|
            \_ ->
                ListExtra.removeAt 1 [ "a", "b", "c" ]
                    |> Expect.equal [ "a", "c" ]
        , test "uniqueBy keeps first item for each key in input order" <|
            \_ ->
                [ { id = "a", value = 1 }
                , { id = "b", value = 2 }
                , { id = "a", value = 3 }
                ]
                    |> ListExtra.uniqueBy .id
                    |> Expect.equal
                        [ { id = "a", value = 1 }
                        , { id = "b", value = 2 }
                        ]
        ]
