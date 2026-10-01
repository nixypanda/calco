module Api.Goals exposing
    ( SaveGoalRequest
    , getGoal
    , saveGoal
    , saveGoalRequestEncoder
    )

import Api.Client as Client
import Data.Goals as Goals exposing (GoalSnapshot, GoalTargets)
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Url.Builder as Builder


type alias SaveGoalRequest =
    { localDate : LocalDate, deviceTimezone : String, targets : GoalTargets }


getGoal : LocalDate -> (Result Client.ApiError GoalSnapshot -> msg) -> Cmd msg
getGoal date toMsg =
    Client.get
        (Builder.absolute [ "api", "goal" ] [ Builder.string "date" (LocalDate.format date) ])
        Goals.decoder
        toMsg


saveGoal : SaveGoalRequest -> (Result Client.ApiError GoalSnapshot -> msg) -> Cmd msg
saveGoal request toMsg =
    Client.put
        (Builder.absolute [ "api", "goal" ] [])
        (saveGoalRequestEncoder request)
        Goals.decoder
        toMsg


saveGoalRequestEncoder : SaveGoalRequest -> Encode.Value
saveGoalRequestEncoder request =
    Encode.object
        [ ( "local_date", Encode.string (LocalDate.format request.localDate) )
        , ( "device_timezone", Encode.string request.deviceTimezone )
        , ( "calorie_target", Encode.float request.targets.calorieTarget )
        , ( "protein_target_g", Encode.float request.targets.proteinTargetG )
        , ( "carbs_target_g", Encode.float request.targets.carbsTargetG )
        , ( "fat_target_g", Encode.float request.targets.fatTargetG )
        ]
