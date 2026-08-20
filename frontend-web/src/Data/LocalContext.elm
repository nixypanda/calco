module Data.LocalContext exposing (LocalContext)

{-| What the browser reports about the device's own calendar position, pushed in
over the `localContextReceived` port — both as the reply to a save that needs the
real date and unprompted when the day rolls over under an open tab. `date` stays
a `String` because the save paths use it as a fallback for an already-`String`
date field; the rollover path parses it.
-}


type alias LocalContext =
    { date : String
    , timezone : String
    }
