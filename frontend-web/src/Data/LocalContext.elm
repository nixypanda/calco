module Data.LocalContext exposing (LocalContext, RawLocalContext, fromRaw)

import Lib.Date as LocalDate exposing (LocalDate)


{-| What the browser reports about the device's own calendar position, already
parsed into a domain date.
-}
type alias LocalContext =
    { date : LocalDate, timezone : String }


{-| The shape the `localContextReceived` port carries: JSON primitives only, so
the date is still the browser's `YYYY-MM-DD` string.
-}
type alias RawLocalContext =
    { date : String, timezone : String }


{-| Parse the port payload into a `LocalContext`. An unparseable date is
rejected here rather than flowing into the app as an invalid value.
-}
fromRaw : RawLocalContext -> Maybe LocalContext
fromRaw raw =
    Maybe.map
        (\date -> { date = date, timezone = raw.timezone })
        (LocalDate.fromString raw.date)
