module Data.Auth exposing
    ( BootstrapStatus
    , Identity
    , LoginRequest
    , LoginSession
    , Profile
    , Role(..)
    , Session(..)
    , applyAuthResult
    , bootstrapAdminEncoder
    , bootstrapStatusDecoder
    , clearSession
    , initSession
    , isAdmin
    , isAuthenticated
    , loginRequestEncoder
    , loginSessionDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type Role
    = Admin
    | User
    | OtherRole


type alias Identity =
    { id : String, username : String, role : Role }


type alias Profile =
    { id : String, displayName : String }


type alias LoginSession =
    { identity : Identity, profile : Maybe Profile }


type alias BootstrapStatus =
    { adminExists : Bool }


type alias LoginRequest =
    { username : String, password : String }


roleDecoder : Decoder Role
roleDecoder =
    Decode.string
        |> Decode.map
            (\role ->
                case role of
                    "admin" ->
                        Admin

                    "user" ->
                        User

                    _ ->
                        OtherRole
            )


identityDecoder : Decoder Identity
identityDecoder =
    Decode.map3 Identity
        (Decode.field "id" Decode.string)
        (Decode.field "username" Decode.string)
        (Decode.field "role" roleDecoder)


profileDecoder : Decoder Profile
profileDecoder =
    Decode.map2 Profile
        (Decode.field "id" Decode.string)
        (Decode.field "display_name" Decode.string)


loginSessionDecoder : Decoder LoginSession
loginSessionDecoder =
    Decode.map2 LoginSession
        (Decode.field "identity" identityDecoder)
        (Decode.field "profile" (Decode.nullable profileDecoder))


bootstrapStatusDecoder : Decoder BootstrapStatus
bootstrapStatusDecoder =
    Decode.map BootstrapStatus (Decode.field "admin_exists" Decode.bool)


loginRequestEncoder : LoginRequest -> Encode.Value
loginRequestEncoder request =
    Encode.object
        [ ( "username", Encode.string request.username )
        , ( "password", Encode.string request.password )
        ]


bootstrapAdminEncoder : LoginRequest -> Encode.Value
bootstrapAdminEncoder =
    loginRequestEncoder



-- SESSION


type Session
    = Loading
    | Authenticated Identity
    | Unauthenticated


initSession : Session
initSession =
    Loading


applyAuthResult : Result error LoginSession -> Session -> Session
applyAuthResult result _ =
    case result of
        Ok loginSession ->
            Authenticated loginSession.identity

        Err _ ->
            Unauthenticated


clearSession : Session -> Session
clearSession _ =
    Unauthenticated


isAuthenticated : Session -> Bool
isAuthenticated session =
    case session of
        Authenticated _ ->
            True

        _ ->
            False


isAdmin : Session -> Bool
isAdmin session =
    case session of
        Authenticated identity ->
            identity.role == Admin

        _ ->
            False
