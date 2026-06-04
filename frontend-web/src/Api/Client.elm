module Api.Client exposing
    ( ApiError(..)
    , delete
    , displayError
    , get
    , isUnauthorized
    , post
    , postEmpty
    , postNoBody
    , put
    )

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type ApiError
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Int String String
    | BadBody String


get : String -> Decoder value -> (Result ApiError value -> msg) -> Cmd msg
get path decoder toMsg =
    request "GET" path Http.emptyBody decoder toMsg


post : String -> Encode.Value -> Decoder value -> (Result ApiError value -> msg) -> Cmd msg
post path body decoder toMsg =
    request "POST" path (Http.jsonBody body) decoder toMsg


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
                Http.BadUrl_ url ->
                    Err (BadUrl url)

                Http.Timeout_ ->
                    Err Timeout

                Http.NetworkError_ ->
                    Err NetworkError

                Http.BadStatus_ metadata body ->
                    Err (decodeBackendError metadata.statusCode body)

                Http.GoodStatus_ _ body ->
                    if String.isEmpty body then
                        Decode.decodeString decoder "null"
                            |> Result.mapError Decode.errorToString
                            |> Result.mapError BadBody

                    else
                        Decode.decodeString decoder body
                            |> Result.mapError Decode.errorToString
                            |> Result.mapError BadBody


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
        BadUrl url ->
            "Bad URL: " ++ url

        Timeout ->
            "Request timed out"

        NetworkError ->
            "Network error"

        BadStatus _ code message ->
            if String.isEmpty code || code == "unknown" then
                message

            else
                code ++ ": " ++ message

        BadBody message ->
            "Unexpected response: " ++ message
