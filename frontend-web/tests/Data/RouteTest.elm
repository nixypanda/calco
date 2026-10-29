module Data.RouteTest exposing (tests)

import Data.Route as Route exposing (Route(..))
import Expect
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz, test)
import Url


{-| `Support.Fuzz.segment` never produces `""`, `"."`, or `".."`: backend
IDs are UUIDs, and browsers normalize dot segments even when percent-encoded, so
no `routeToPath` output could roundtrip those values. Percent signs, spaces,
slashes, unicode, and the reserved words "new"/"custom" are all generated.
-}
tests : Test
tests =
    describe "Data.Route"
        [ fuzz Support.route "routeToPath then fromUrl is the identity" <|
            \route ->
                route |> Route.routeToPath |> parsePath |> Expect.equal (Just route)
        , fuzz Support.route
            "primaryRoute is idempotent and never maps a known route to NotFound"
          <|
            \route ->
                Expect.all
                    [ \_ ->
                        Route.primaryRoute (Route.primaryRoute route)
                            |> Expect.equal (Route.primaryRoute route)
                    ]
                    ()
        , {- Negative exception: NotFound is the only route excluded from the
             roundtrip because `routeToPath NotFound == "/"` parses as `Root`.
             This case protects the intentional fallback for unknown URLs.
          -}
          test "an unrecognized URL parses to NotFound" <|
            \_ ->
                Url.fromString "http://localhost/definitely-not-a-route"
                    |> Maybe.map Route.fromUrl
                    |> Expect.equal (Just NotFound)
        ]


parsePath : String -> Maybe Route
parsePath path =
    Url.fromString ("http://localhost" ++ path) |> Maybe.map Route.fromUrl
