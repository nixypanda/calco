module Store exposing (Store, empty, isCurrentRequest, reset)

import Api.Client exposing (ApiError)
import Api.Foods exposing (NutrientListResponse, UnitListResponse)
import Api.Logs exposing (LatestSlotsResponse)
import Data.DiaryPreferences exposing (DiaryPreferences)
import Data.FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot)
import Dict exposing (Dict)
import Lib.Loadable exposing (Loadable(..))


type alias Store =
    { generation : Int
    , nextRequestId : Int
    , diaryLogs : Dict String (Loadable ApiError (List FoodLog))
    , diaryLogRequestIds : Dict String Int
    , diaryGoals : Dict String (Loadable ApiError GoalSnapshot)
    , diaryGoalRequestIds : Dict String Int
    , latestSlots : Dict String (Loadable ApiError LatestSlotsResponse)
    , latestSlotRequestIds : Dict String Int
    , preferences : Loadable ApiError DiaryPreferences
    , units : Loadable ApiError UnitListResponse
    , nutrients : Loadable ApiError NutrientListResponse
    }


empty : Store
empty =
    { generation = 0
    , nextRequestId = 0
    , diaryLogs = Dict.empty
    , diaryLogRequestIds = Dict.empty
    , diaryGoals = Dict.empty
    , diaryGoalRequestIds = Dict.empty
    , latestSlots = Dict.empty
    , latestSlotRequestIds = Dict.empty
    , preferences = NotAsked
    , units = NotAsked
    , nutrients = NotAsked
    }


reset : Store -> Store
reset store =
    { empty | generation = store.generation + 1 }


isCurrentRequest : Int -> Int -> String -> Store -> Dict String Int -> Bool
isCurrentRequest generation requestId key store requestIds =
    generation == store.generation && Dict.get key requestIds == Just requestId
