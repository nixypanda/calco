module Session exposing
    ( Session
    , SessionState(..)
    , applyAuthResult
    , clear
    , init
    , isAdmin
    , isAuthenticated
    , setAdminExists
    )

import Api.Client exposing (ApiError)
import Data.Auth as Auth


type SessionState
    = Loading
    | Loaded


type alias Session =
    { state : SessionState
    , identity : Maybe Auth.Identity
    , profile : Maybe Auth.Profile
    , adminExists : Bool
    }


init : Session
init =
    { state = Loading
    , identity = Nothing
    , profile = Nothing
    , adminExists = True
    }


applyAuthResult : Result ApiError Auth.LoginSession -> Session -> Session
applyAuthResult result session =
    case result of
        Ok loginSession ->
            { session
                | state = Loaded
                , identity = Just loginSession.identity
                , profile = loginSession.profile
            }

        Err _ ->
            clear { session | state = Loaded }


setAdminExists : Bool -> Session -> Session
setAdminExists adminExists session =
    { session | adminExists = adminExists }


clear : Session -> Session
clear session =
    { session | identity = Nothing, profile = Nothing }


isAuthenticated : Session -> Bool
isAuthenticated session =
    session.identity /= Nothing


isAdmin : Session -> Bool
isAdmin session =
    case session.identity of
        Just identity ->
            identity.role == Auth.Admin

        Nothing ->
            False
