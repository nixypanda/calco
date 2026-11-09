module Api.DiaryPrefs exposing (get, put)

import Api.Client as Client
import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Url.Builder as Builder


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
