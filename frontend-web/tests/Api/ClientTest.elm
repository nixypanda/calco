module Api.ClientTest exposing (tests)

{-| Failure classification and display-message laws for `Api.Client`.

The unauthorized law is the allowed 401 exception from `docs/testing.md`: it
cannot be folded into a page story because every page consumes the same
`failure` helper, and a per-page 401 test would duplicate this one. The law
covers the whole `ApiError` space plus the 401/403/429 edges that decide whether
a session is expired.

-}

import Api.Client as Client exposing (ApiError(..))
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz)


type OutMsg
    = NoOp
    | SessionExpired


type alias Model =
    { appliedError : Maybe String }


tests : Test
tests =
    describe "Api.Client" [ unauthorizedExpiresSession, displayErrorIsNeverBlank ]


{-| Allowed 401 exception: `isUnauthorized` is true exactly for status 401, and
`failure` expires the session exactly then.
-}
unauthorizedExpiresSession : Test
unauthorizedExpiresSession =
    fuzz FuzzSupport.apiError "only a 401 is unauthorized and expires the session" <|
        \error ->
            let
                ( _, _, outMsg ) =
                    Client.failure config error emptyModel

                expected : OutMsg
                expected =
                    if isUnauthorizedStatus error then
                        SessionExpired

                    else
                        NoOp
            in
            Expect.all
                [ \_ -> outMsg |> Expect.equal expected
                , \_ -> statusEdges |> List.map statusEdgeExpectation |> expectAll
                ]
                ()


isUnauthorizedStatus : ApiError -> Bool
isUnauthorizedStatus error =
    case error of
        BadStatus 401 _ _ ->
            True

        _ ->
            False


statusEdges : List ( Int, Bool )
statusEdges =
    [ ( 401, True )
    , ( 403, False )
    ]


statusEdgeExpectation : ( Int, Bool ) -> Expectation
statusEdgeExpectation ( status, expected ) =
    Client.isUnauthorized (BadStatus status "denied" "Denied")
        |> Expect.equal expected
        |> Expect.onFail ("status " ++ String.fromInt status)


{-| Includes deterministic blank/whitespace backend messages because the generic
fuzzer only samples them probabilistically.
-}
displayErrorIsNeverBlank : Test
displayErrorIsNeverBlank =
    fuzz displayErrorInput "displayError never returns a blank message" <|
        \error ->
            Client.displayError error |> String.trim |> Expect.notEqual ""


displayErrorInput : Fuzzer ApiError
displayErrorInput =
    Fuzz.oneOf
        [ FuzzSupport.apiError
        , Fuzz.constant (BadStatus 400 "validation" "")
        , Fuzz.constant (BadStatus 500 "server_error" "   ")
        , Fuzz.constant NetworkError
        ]


config : { noOp : OutMsg, sessionExpired : OutMsg, applyError : String -> Model -> Model }
config =
    { noOp = NoOp
    , sessionExpired = SessionExpired
    , applyError = \message model -> { model | appliedError = Just message }
    }


emptyModel : Model
emptyModel =
    { appliedError = Nothing }


expectAll : List Expectation -> Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()
