module Store exposing
    ( Access
    , RequestToken
    , Store
    , cached
    , clearGoals
    , clearLatestSlots
    , diaryGoalAt
    , diaryLogsAt
    , empty
    , invalidate
    , latestSlotsAt
    , nutrients
    , prefs
    , request
    , reset
    , seed
    , settle
    , units
    )

import Api.Client exposing (ApiError)
import Api.Foods exposing (NutrientListResponse, UnitListResponse)
import Api.Logs exposing (LatestSlotsResponse)
import Data.DiaryPrefs exposing (DiaryPrefs)
import Data.FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot)
import Dict exposing (Dict)
import Lib.Date as LocalDate exposing (LocalDate)


{-| Opaque so that every write either redeems the token of the request that
asked for the value, or says outright that it is seeding one the caller already
has.
-}
type Store
    = Store Fields


type alias Fields =
    { generation : Int
    , nextRequestId : Int
    , diaryLogs : Dict String (Entry (List FoodLog))
    , diaryGoals : Dict String (Entry GoalSnapshot)
    , latestSlots : Dict String (Entry LatestSlotsResponse)
    , prefs : Entry DiaryPrefs
    , units : Entry UnitListResponse
    , nutrients : Entry NutrientListResponse
    }


{-| A cached resource and the identity of the request currently filling it are
one value, not two collections every writer has to remember to keep in step. A
request id that can drift away from the entry it guards is how a stale response
ends up overwriting fresh data.
-}
type Entry a
    = NotRequested
    | InFlight Int
    | Settled (Result ApiError a)


{-| Opaque and indivisible so that a caller can neither pair one resource's
session generation with another's request id, nor mint a token for a request
that was never made.
-}
type RequestToken
    = RequestToken { generation : Int, requestId : Int }


{-| Callers name a resource and get its operations; which field or dictionary
key backs it stays in here.
-}
type Access a
    = Access { get : Store -> Entry a, set : Entry a -> Store -> Store }


empty : Store
empty =
    Store
        { generation = 0
        , nextRequestId = 0
        , diaryLogs = Dict.empty
        , diaryGoals = Dict.empty
        , latestSlots = Dict.empty
        , prefs = NotRequested
        , units = NotRequested
        , nutrients = NotRequested
        }


{-| Moving the generation on means a response still in flight is redeemed
against a session that no longer exists, and so is discarded.
-}
reset : Store -> Store
reset (Store fields) =
    let
        (Store fresh) =
            empty
    in
    Store { fresh | generation = fields.generation + 1 }



-- RESOURCES


diaryLogsAt : LocalDate -> Access (List FoodLog)
diaryLogsAt date =
    dictAccess (LocalDate.format date)
        .diaryLogs
        (\entries fields -> { fields | diaryLogs = entries })


diaryGoalAt : LocalDate -> Access GoalSnapshot
diaryGoalAt date =
    dictAccess (LocalDate.format date)
        .diaryGoals
        (\entries fields -> { fields | diaryGoals = entries })


latestSlotsAt : LocalDate -> Access LatestSlotsResponse
latestSlotsAt date =
    dictAccess (LocalDate.format date)
        .latestSlots
        (\entries fields -> { fields | latestSlots = entries })


prefs : Access DiaryPrefs
prefs =
    slotAccess .prefs (\entry fields -> { fields | prefs = entry })


units : Access UnitListResponse
units =
    slotAccess .units (\entry fields -> { fields | units = entry })


nutrients : Access NutrientListResponse
nutrients =
    slotAccess .nutrients (\entry fields -> { fields | nutrients = entry })


dictAccess :
    String
    -> (Fields -> Dict String (Entry a))
    -> (Dict String (Entry a) -> Fields -> Fields)
    -> Access a
dictAccess key get set =
    Access
        { get =
            \(Store fields) ->
                Dict.get key (get fields) |> Maybe.withDefault NotRequested
        , set =
            \entry (Store fields) ->
                Store (set (Dict.insert key entry (get fields)) fields)
        }


slotAccess : (Fields -> Entry a) -> (Entry a -> Fields -> Fields) -> Access a
slotAccess get set =
    Access
        { get = \(Store fields) -> get fields
        , set = \entry (Store fields) -> Store (set entry fields)
        }



-- OPERATIONS


{-| What keeps a second pane wanting the same data from issuing a second
request.
-}
request : Access a -> Store -> Maybe ( Store, RequestToken )
request (Access access) store =
    case access.get store of
        NotRequested ->
            let
                (Store fields) =
                    store

                requestId : Int
                requestId =
                    fields.nextRequestId + 1
            in
            Just
                ( access.set (InFlight requestId) (Store { fields | nextRequestId = requestId })
                , RequestToken { generation = fields.generation, requestId = requestId }
                )

        _ ->
            Nothing


{-| Recording a result is only possible by redeeming its token, so no call site
can forget to reject a superseded response.
-}
settle : Access a -> RequestToken -> Result ApiError a -> Store -> Maybe Store
settle (Access access) (RequestToken token) result store =
    let
        (Store fields) =
            store
    in
    case access.get store of
        InFlight requestId ->
            if requestId == token.requestId && token.generation == fields.generation then
                Just (access.set (Settled result) store)

            else
                Nothing

        _ ->
            Nothing


cached : Access a -> Store -> Maybe (Result ApiError a)
cached (Access access) store =
    case access.get store of
        Settled result ->
            Just result

        _ ->
            Nothing


{-| Any response in flight for this resource is superseded, since its token no
longer matches.
-}
seed : Access a -> a -> Store -> Store
seed (Access access) value store =
    access.set (Settled (Ok value)) store


invalidate : Access a -> Store -> Store
invalidate (Access access) store =
    access.set NotRequested store


clearGoals : Store -> Store
clearGoals (Store fields) =
    Store { fields | diaryGoals = Dict.empty }


clearLatestSlots : Store -> Store
clearLatestSlots (Store fields) =
    Store { fields | latestSlots = Dict.empty }
