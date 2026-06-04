module Session exposing
    ( Session(..)
    , applyAuthResult
    , clear
    , init
    , isAdmin
    , isAuthenticated
    )

import Api.Client exposing (ApiError)
import Data.Auth as Auth


type Session
    = Loading
    | Authenticated Auth.Identity (Maybe Auth.Profile)
    | Unauthenticated


init : Session
init =
    Loading


applyAuthResult : Result ApiError Auth.LoginSession -> Session -> Session
applyAuthResult result _ =
    case result of
        Ok loginSession ->
            Authenticated loginSession.identity loginSession.profile

        Err _ ->
            Unauthenticated


clear : Session -> Session
clear _ =
    Unauthenticated


isAuthenticated : Session -> Bool
isAuthenticated session =
    case session of
        Authenticated _ _ ->
            True

        _ ->
            False


isAdmin : Session -> Bool
isAdmin session =
    case session of
        Authenticated identity _ ->
            identity.role == Auth.Admin

        _ ->
            False
