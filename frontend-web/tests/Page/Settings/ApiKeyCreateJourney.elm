module Page.Settings.ApiKeyCreateJourney exposing
    ( CopyRef
    , CreateRef
    , Journey
    , completeCopy
    , completeCreate
    , completePreviousCopy
    , completePreviousCreate
    , createdFeedback
    , createdToken
    , formError
    , send
    , staleSubmitDisabled
    , start
    , startCopy
    , submit
    , validationError
    )

{-| A flat journey for the api-key create story. IDs are stored only to address
simulated completions; a missing effect becomes an asserted `Just failure`, so
a broken story cannot silently keep going.
-}

import Api.Client as Client
import Data.ApiKey exposing (CreateRequest, CreatedApiKey)
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeyProjection as Projection


type alias CreateRef =
    { requestId : Int, request : CreateRequest }


type alias CopyRef =
    { copyId : Int, token : String }


type alias Journey =
    { model : ApiKeyCreate.Model
    , lastOut : ApiKeyCreate.OutMsg
    , failure : Maybe String
    , previousCreate : Maybe CreateRef
    , create : Maybe CreateRef
    , previousCopy : Maybe CopyRef
    , copy : Maybe CopyRef
    }


start : ( ApiKeyCreate.Model, ApiKeyCreate.OutMsg ) -> Journey
start ( model, outMsg ) =
    { model = model
    , lastOut = outMsg
    , failure = Nothing
    , previousCreate = Nothing
    , create = Nothing
    , previousCopy = Nothing
    , copy = Nothing
    }


send : ApiKeyCreate.Msg -> Journey -> Journey
send msg journey =
    let
        ( model, _, outMsg ) =
            ApiKeyCreate.update msg journey.model
    in
    { journey | model = model, lastOut = outMsg }


fail : String -> Journey -> Journey
fail message journey =
    { journey | failure = Just message }


submit : Journey -> Journey
submit journey =
    let
        next : Journey
        next =
            send ApiKeyCreate.Submitted journey
    in
    case next.lastOut of
        ApiKeyCreate.RequestCreate requestId request ->
            { next
                | previousCreate = journey.create
                , create = Just { requestId = requestId, request = request }
            }

        _ ->
            fail "the create form did not emit RequestCreate" next


completeCreate : Result Client.ApiError CreatedApiKey -> Journey -> Journey
completeCreate result journey =
    case journey.create of
        Just ref ->
            send (ApiKeyCreate.CreateCompleted ref.requestId result) journey

        Nothing ->
            fail "the pending create request is missing" journey


completePreviousCreate : Result Client.ApiError CreatedApiKey -> Journey -> Journey
completePreviousCreate result journey =
    case journey.previousCreate of
        Just ref ->
            send (ApiKeyCreate.CreateCompleted ref.requestId result) journey

        Nothing ->
            fail "the previous create request is missing" journey


startCopy : Journey -> Journey
startCopy journey =
    let
        next : Journey
        next =
            send ApiKeyCreate.CopyClicked journey
    in
    case next.lastOut of
        ApiKeyCreate.CopyText copyId token ->
            { next
                | previousCopy = journey.copy
                , copy = Just { copyId = copyId, token = token }
            }

        _ ->
            fail "the created key did not emit CopyText" next


completeCopy : Bool -> Journey -> Journey
completeCopy succeeded journey =
    case journey.copy of
        Just ref ->
            send (ApiKeyCreate.CopyCompleted ref.copyId succeeded) journey

        Nothing ->
            fail "the pending copy request is missing" journey


completePreviousCopy : Bool -> Journey -> Journey
completePreviousCopy succeeded journey =
    case journey.previousCopy of
        Just ref ->
            send (ApiKeyCreate.CopyCompleted ref.copyId succeeded) journey

        Nothing ->
            fail "the previous copy request is missing" journey



-- PROJECTIONS


formError : ApiKeyCreate.Model -> Maybe String
formError model =
    Projection.createScreen model
        |> .form
        |> Maybe.andThen .error


staleSubmitDisabled : ApiKeyCreate.Model -> Maybe Bool
staleSubmitDisabled model =
    Projection.createScreen model
        |> .form
        |> Maybe.map .submitDisabled


createdFeedback : ApiKeyCreate.Model -> Maybe String
createdFeedback model =
    Projection.createScreen model
        |> .created
        |> Maybe.andThen .copyFeedback


createdToken : ApiKeyCreate.Model -> Maybe String
createdToken model =
    Projection.createScreen model
        |> .created
        |> Maybe.map .token


validationError : String -> Maybe String
validationError name =
    let
        submitted : Journey
        submitted =
            start ApiKeyCreate.init
                |> send (ApiKeyCreate.NameChanged name)
                |> send ApiKeyCreate.Submitted
    in
    formError submitted.model
