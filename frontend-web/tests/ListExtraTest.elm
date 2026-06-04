module ListExtraTest exposing (tests)

import Data.ListExtra as ListExtra
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.ListExtra"
        [ test "updates item at index" <|
            \_ ->
                ListExtra.updateAt 1 ((+) 10) [ 1, 2, 3 ]
                    |> Expect.equal [ 1, 12, 3 ]
        , test "removes item at index" <|
            \_ ->
                ListExtra.removeAt 1 [ "a", "b", "c" ]
                    |> Expect.equal [ "a", "c" ]
        ]
