module Data.User exposing
    ( CreateUserRequest
    , ResetPasswordRequest
    , User
    , createUserEncoder
    , listUsersDecoder
    , resetPasswordEncoder
    , userDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias User =
    { id : String, username : String, displayName : String, status : String, createdAt : String }


type alias CreateUserRequest =
    { username : String, displayName : String, initialPassword : String }


type alias ResetPasswordRequest =
    { newPassword : String }


userDecoder : Decoder User
userDecoder =
    Decode.map5 User
        (Decode.field "id" Decode.string)
        (Decode.field "username" Decode.string)
        (Decode.field "display_name" Decode.string)
        (Decode.field "status" Decode.string)
        (Decode.field "created_at" Decode.string)


listUsersDecoder : Decoder (List User)
listUsersDecoder =
    Decode.field "users" (Decode.list userDecoder)


createUserEncoder : CreateUserRequest -> Encode.Value
createUserEncoder request =
    Encode.object
        [ ( "username", Encode.string request.username )
        , ( "display_name", Encode.string request.displayName )
        , ( "initial_password", Encode.string request.initialPassword )
        ]


resetPasswordEncoder : ResetPasswordRequest -> Encode.Value
resetPasswordEncoder request =
    Encode.object [ ( "new_password", Encode.string request.newPassword ) ]
