module Data.LocalContext exposing (LocalContext)

{-| What the browser reports about the device's own calendar position, pushed in
over the `localContextReceived` port. `date` stays a `String` because every
consumer uses it as a fallback for an already-`String` date field.
-}


type alias LocalContext =
    { date : String
    , timezone : String
    }
