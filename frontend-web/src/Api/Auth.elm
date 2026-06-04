module Api.Auth exposing (bootstrapStatus, createAdmin, login, logout, session)

import Api.Client as Client
import Data.Auth as Auth


bootstrapStatus : (Result Client.ApiError Auth.BootstrapStatus -> msg) -> Cmd msg
bootstrapStatus toMsg =
    Client.get "/api/auth/bootstrap/status" Auth.bootstrapStatusDecoder toMsg


createAdmin : Auth.LoginRequest -> (Result Client.ApiError Auth.LoginSession -> msg) -> Cmd msg
createAdmin request toMsg =
    Client.post
        "/api/auth/bootstrap/admin"
        (Auth.bootstrapAdminEncoder request)
        Auth.loginSessionDecoder
        toMsg


login : Auth.LoginRequest -> (Result Client.ApiError Auth.LoginSession -> msg) -> Cmd msg
login request toMsg =
    Client.post "/api/auth/login" (Auth.loginRequestEncoder request) Auth.loginSessionDecoder toMsg


session : (Result Client.ApiError Auth.LoginSession -> msg) -> Cmd msg
session toMsg =
    Client.get "/api/auth/session" Auth.loginSessionDecoder toMsg


logout : (Result Client.ApiError () -> msg) -> Cmd msg
logout toMsg =
    Client.postNoBody "/api/auth/logout" toMsg
