module Support.Fixtures exposing
    ( date
    , networkErrorMessage
    , today
    , tupleFirst
    , tupleThird
    , unauthorized
    )

{-| Small, non page-specific values shared by tests.

Page-specific model builders stay next to their page tests. This module only
holds dates, canonical API errors, and tuple helpers that several tests need to
name identically.

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


{-| A literal copy of the English network-error string. It must not call
`I18n.en`: a translation regression has to change actual output while leaving
this expected value alone, otherwise the assertion could never fail.
-}
networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tupleFirst : ( a, b, c ) -> a
tupleFirst ( value, _, _ ) =
    value


tupleThird : ( a, b, c ) -> c
tupleThird ( _, _, value ) =
    value
