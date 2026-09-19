module Api.Client exposing
    ( ApiError(..)
    , delete
    , displayError
    , failure
    , get
    , isUnauthorized
    , post
    , postEmpty
    , postMultipart
    , postNoBody
    , put
    )

import Dict
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type ApiError
    = BadUrl
    | Timeout
    | NetworkError
    | BadStatus Int String String
    | RateLimited (Maybe Int)
    | BadBody


get : String -> Decoder value -> (Result ApiError value -> msg) -> Cmd msg
get path decoder toMsg =
    request "GET" path Http.emptyBody decoder toMsg


post : String -> Encode.Value -> Decoder value -> (Result ApiError value -> msg) -> Cmd msg
post path body decoder toMsg =
    request "POST" path (Http.jsonBody body) decoder toMsg


postMultipart :
    String
    -> List Http.Part
    -> Decoder value
    -> (Result ApiError value -> msg)
    -> Cmd msg
postMultipart path parts decoder toMsg =
    request "POST" path (Http.multipartBody parts) decoder toMsg


postEmpty : String -> Encode.Value -> (Result ApiError () -> msg) -> Cmd msg
postEmpty path body toMsg =
    request "POST" path (Http.jsonBody body) (Decode.succeed ()) toMsg


postNoBody : String -> (Result ApiError () -> msg) -> Cmd msg
postNoBody path toMsg =
    request "POST" path Http.emptyBody (Decode.succeed ()) toMsg


put : String -> Encode.Value -> Decoder value -> (Result ApiError value -> msg) -> Cmd msg
put path body decoder toMsg =
    request "PUT" path (Http.jsonBody body) decoder toMsg


delete : String -> (Result ApiError () -> msg) -> Cmd msg
delete path toMsg =
    request "DELETE" path Http.emptyBody (Decode.succeed ()) toMsg


request :
    String
    -> String
    -> Http.Body
    -> Decoder value
    -> (Result ApiError value -> msg)
    -> Cmd msg
request method path body decoder toMsg =
    Http.request
        { method = method
        , headers = []
        , url = path
        , body = body
        , expect = expectJson decoder toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


expectJson : Decoder value -> (Result ApiError value -> msg) -> Http.Expect msg
expectJson decoder toMsg =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ _ ->
                    Err BadUrl

                Http.Timeout_ ->
                    Err Timeout

                Http.NetworkError_ ->
                    Err NetworkError

                Http.BadStatus_ metadata body ->
                    if metadata.statusCode == 429 then
                        Err
                            (RateLimited
                                (metadata.headers
                                    |> Dict.get "retry-after"
                                    |> Maybe.andThen String.toInt
                                )
                            )

                    else
                        Err (decodeBackendError metadata.statusCode body)

                Http.GoodStatus_ _ body ->
                    if String.isEmpty body then
                        Decode.decodeString decoder "null"
                            |> Result.mapError (always BadBody)

                    else
                        Decode.decodeString decoder body
                            |> Result.mapError (always BadBody)


decodeBackendError : Int -> String -> ApiError
decodeBackendError status body =
    case Decode.decodeString backendErrorDecoder body of
        Ok ( code, message ) ->
            BadStatus status code message

        Err _ ->
            BadStatus status "unknown" body


backendErrorDecoder : Decoder ( String, String )
backendErrorDecoder =
    Decode.map2 Tuple.pair
        (Decode.at [ "error", "code" ] Decode.string)
        (Decode.at [ "error", "message" ] Decode.string)


isUnauthorized : ApiError -> Bool
isUnauthorized error =
    case error of
        BadStatus 401 _ _ ->
            True

        _ ->
            False


displayError : ApiError -> String
displayError error =
    case error of
        BadUrl ->
            "Could not connect to the server. Refresh the page and try again."

        Timeout ->
            "The server took too long to respond. Try again."

        NetworkError ->
            "Could not reach the server. Check your connection and try again."

        BadStatus _ code message ->
            if String.isEmpty code || code == "unknown" then
                "The server could not complete the request. Try again."

            else
                message

        RateLimited maybeSeconds ->
            case maybeSeconds of
                Just seconds ->
                    "Too many requests. Try again in " ++ String.fromInt seconds ++ " seconds."

                Nothing ->
                    "Too many requests. Please wait before trying again."

        BadBody ->
            "The server returned an unexpected response. Refresh the page and try again."


failure :
    { noOp : outMsg
    , sessionExpired : outMsg
    , applyError : String -> model -> model
    }
    -> ApiError
    -> model
    -> ( model, Cmd msg, outMsg )
failure config error model =
    let
        updatedModel : model
        updatedModel =
            config.applyError (displayError error) model
    in
    ( updatedModel
    , Cmd.none
    , if isUnauthorized error then
        config.sessionExpired

      else
        config.noOp
    )
