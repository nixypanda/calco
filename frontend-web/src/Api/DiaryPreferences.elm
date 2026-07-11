module Api.DiaryPreferences exposing (get, put)

import Api.Client as Client
import Data.DiaryPreferences as DiaryPreferences exposing (DiaryPreferences)
import Url.Builder as Builder


get : (Result Client.ApiError DiaryPreferences -> msg) -> Cmd msg
get toMsg =
    Client.get
        (Builder.absolute [ "api", "diary-preferences" ] [])
        DiaryPreferences.decoder
        toMsg


put : DiaryPreferences -> (Result Client.ApiError DiaryPreferences -> msg) -> Cmd msg
put preferences toMsg =
    Client.put
        (Builder.absolute [ "api", "diary-preferences" ] [])
        (DiaryPreferences.encoder preferences)
        DiaryPreferences.decoder
        toMsg
