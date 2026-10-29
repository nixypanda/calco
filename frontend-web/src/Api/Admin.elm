module Api.Admin exposing (createUser, disableUser, enableUser, getUser, listUsers, resetPassword)

import Api.Client as Client
import Data.Auth as Auth
import Data.User as User exposing (User)


listUsers : (Result Client.ApiError (List User) -> msg) -> Cmd msg
listUsers toMsg =
    Client.get "/api/admin/users" User.listUsersDecoder toMsg


getUser : String -> (Result Client.ApiError User -> msg) -> Cmd msg
getUser userId toMsg =
    Client.get ("/api/admin/users/" ++ userId) User.userDecoder toMsg


createUser : User.CreateUserRequest -> (Result Client.ApiError Auth.LoginSession -> msg) -> Cmd msg
createUser request toMsg =
    Client.post "/api/admin/users" (User.createUserEncoder request) Auth.loginSessionDecoder toMsg


resetPassword : String -> User.ResetPasswordRequest -> (Result Client.ApiError () -> msg) -> Cmd msg
resetPassword userId request toMsg =
    Client.postEmpty ("/api/admin/users/" ++ userId ++ "/reset-password")
        (User.resetPasswordEncoder request)
        toMsg


disableUser : String -> (Result Client.ApiError () -> msg) -> Cmd msg
disableUser userId toMsg =
    Client.postNoBody ("/api/admin/users/" ++ userId ++ "/disable") toMsg


enableUser : String -> (Result Client.ApiError () -> msg) -> Cmd msg
enableUser userId toMsg =
    Client.postNoBody ("/api/admin/users/" ++ userId ++ "/enable") toMsg
