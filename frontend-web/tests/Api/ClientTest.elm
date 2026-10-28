module Api.ClientTest exposing (tests)

import Api.Client as Client exposing (ApiError(..))
import Expect exposing (Expectation)
import Support.Fixtures as Fixtures
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz, test)


type OutMsg
    = NoOp
    | SessionExpired


type alias Model =
    { appliedError : Maybe String }


tests : Test
tests =
    describe "Api.Client"
        [ isUnauthorizedOnlyFor401
        , isUnauthorizedAtStatusEdges
        , failureExpiresOnlyUnauthorizedSessions
        , failureAppliesDisplayError
        , displayErrorIsNeverBlank
        , blankBackendMessageFallsBack
        , networkErrorHasDisplayMessage
        , canonicalUnauthorizedFixture
        ]


isUnauthorizedOnlyFor401 : Test
isUnauthorizedOnlyFor401 =
    fuzz FuzzSupport.apiError "isUnauthorized is true only for BadStatus 401" <|
        \error ->
            case error of
                BadStatus status _ _ ->
                    Client.isUnauthorized error
                        |> Expect.equal (status == 401)

                _ ->
                    Client.isUnauthorized error
                        |> Expect.equal False


{-| Explicit edge statuses for the privacy-relevant session-expiry decision:
only 401 expires a session; 403 and 429 are ordinary failures.
-}
isUnauthorizedAtStatusEdges : Test
isUnauthorizedAtStatusEdges =
    test "only status 401 is unauthorized at the 401/403/429 edges" <|
        \_ ->
            [ ( 401, True )
            , ( 403, False )
            , ( 429, False )
            ]
                |> List.map
                    (\( status, expected ) ->
                        Client.isUnauthorized (BadStatus status "denied" "Denied")
                            |> Expect.equal expected
                            |> Expect.onFail ("status " ++ String.fromInt status)
                    )
                |> expectAll


failureExpiresOnlyUnauthorizedSessions : Test
failureExpiresOnlyUnauthorizedSessions =
    fuzz FuzzSupport.apiError "failure expires the session exactly when isUnauthorized holds" <|
        \error ->
            let
                ( _, _, outMsg ) =
                    Client.failure config error emptyModel

                expected : OutMsg
                expected =
                    if Client.isUnauthorized error then
                        SessionExpired

                    else
                        NoOp
            in
            outMsg |> Expect.equal expected


failureAppliesDisplayError : Test
failureAppliesDisplayError =
    fuzz FuzzSupport.apiError "failure applies the display message for every error" <|
        \error ->
            let
                ( model, _, _ ) =
                    Client.failure config error emptyModel
            in
            model.appliedError
                |> Expect.equal (Just (Client.displayError error))


displayErrorIsNeverBlank : Test
displayErrorIsNeverBlank =
    fuzz FuzzSupport.apiError "displayError never returns a blank message" <|
        \error ->
            Client.displayError error
                |> String.trim
                |> Expect.notEqual ""


{-| The fuzzer samples empty and whitespace messages only probabilistically, so
the blank-message fallback also gets deterministic cases.
-}
blankBackendMessageFallsBack : Test
blankBackendMessageFallsBack =
    test "blank backend messages fall back to a non-blank display message" <|
        \_ ->
            [ Client.BadStatus 400 "validation" ""
            , Client.BadStatus 500 "server_error" "   "
            ]
                |> List.map
                    (\error ->
                        Client.displayError error
                            |> String.trim
                            |> String.isEmpty
                    )
                |> Expect.equal [ False, False ]


networkErrorHasDisplayMessage : Test
networkErrorHasDisplayMessage =
    test "a network failure still yields a non-blank message" <|
        \_ ->
            Client.displayError Client.NetworkError
                |> String.trim
                |> Expect.notEqual ""


canonicalUnauthorizedFixture : Test
canonicalUnauthorizedFixture =
    test "the shared unauthorized fixture is classified and expires the session" <|
        \_ ->
            let
                ( model, _, outMsg ) =
                    Client.failure config Fixtures.unauthorized emptyModel
            in
            Expect.all
                [ \_ ->
                    Client.isUnauthorized Fixtures.unauthorized
                        |> Expect.equal True
                , \_ -> outMsg |> Expect.equal SessionExpired
                , \_ ->
                    model.appliedError
                        |> Expect.equal (Just (Client.displayError Fixtures.unauthorized))
                ]
                ()


config :
    { noOp : OutMsg
    , sessionExpired : OutMsg
    , applyError : String -> Model -> Model
    }
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
