module Support.Fixtures exposing
    ( today
    , unauthorized
    )

{-| Small, non page-specific values shared by tests.

Page-specific model builders stay next to their page tests. This module only
holds dates and a canonical API error that several tests need to name
identically.

-}

import Api.Client as Client exposing (ApiError)
import Lib.Date as LocalDate exposing (LocalDate)
import Time


{-| Parse a canonical `YYYY-MM-DD` string. Invalid input falls back to the
Unix epoch so a test fixture can never loop forever; callers that care about a
specific date should use `today` or construct the date explicitly.
-}
date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            epoch


epoch : LocalDate
epoch =
    LocalDate.fromPosix Time.utc (Time.millisToPosix 0)


today : LocalDate
today =
    date "2026-08-18"


unauthorized : ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"
