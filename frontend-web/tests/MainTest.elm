module MainTest exposing (helloWorld)

import Expect
import Test exposing (Test, test)


helloWorld : Test
helloWorld =
    test "hello world" <|
        \_ ->
            "Hello, Elm!"
                |> Expect.equal "Hello, Elm!"
