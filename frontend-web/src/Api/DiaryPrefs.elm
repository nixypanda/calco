module Api.DiaryPrefs exposing (get, put)

import Api.Client as Client
import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Url.Builder as Builder


{-| elm/http measures `timeout` in milliseconds, so this is a 10-second bound.
-}
prefsTimeoutMs : Int
prefsTimeoutMs =
    10000


get : (Result Client.ApiError DiaryPrefs -> msg) -> Cmd msg
get toMsg =
    Client.getWithTimeout prefsTimeoutMs
        (Builder.absolute [ "api", "diary-preferences" ] [])
        DiaryPrefs.decoder
        toMsg


put : DiaryPrefs -> (Result Client.ApiError DiaryPrefs -> msg) -> Cmd msg
put prefs toMsg =
    Client.put (Builder.absolute [ "api", "diary-preferences" ] [])
        (DiaryPrefs.encoder prefs)
        DiaryPrefs.decoder
        toMsg
