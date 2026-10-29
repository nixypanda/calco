module Page.Settings.ApiKeyPaneJourney exposing
    ( CopyInfo
    , CreateRef
    , Journey
    , apiKeysScreenOf
    , apply
    , completeCreate
    , completeCurrentCopy
    , completePreviousCopy
    , completePreviousCreate
    , createScreenOf
    , keysLoaded
    , sendCreate
    , sendKeys
    , staleOldList
    , start
    , startCopy
    , submitCreate
    )

{-| A small journey harness for the one allowed api-key pane generation race.
The fields hold IDs only so a completion can be addressed; the page test never
asserts them. Required messages and missing IDs are recorded as a failure that
the story asserts is `Nothing`, so a silent no-op cannot pass.
-}

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, CreatedApiKey)
import Data.Route exposing (Route(..))
import Page
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeyProjection as Projection
import Page.Settings.ApiKeys as ApiKeys
import Support.Fixtures as Fixtures


type alias CreateRef =
    { generation : Int, requestId : Int }


type alias CopyInfo =
    { generation : Int, copyId : Int, token : String }


type alias Journey =
    { model : Page.Model
    , lastOut : Page.OutMsg
    , failure : Maybe String
    , previousListGeneration : Maybe Int
    , listGeneration : Maybe Int
    , previousCreate : Maybe CreateRef
    , create : Maybe CreateRef
    , previousCopy : Maybe CopyInfo
    , copy : Maybe CopyInfo
    }


start : Page.Model -> Journey
start model =
    { model = model
    , lastOut = Page.NoOutMsg
    , failure = Nothing
    , previousListGeneration = Nothing
    , listGeneration = Nothing
    , previousCreate = Nothing
    , create = Nothing
    , previousCopy = Nothing
    , copy = Nothing
    }


send : Page.Msg -> Journey -> Journey
send msg journey =
    case Page.update ctx msg journey.model of
        Just ( model, _, outMsg ) ->
            { journey | model = model, lastOut = outMsg }

        Nothing ->
            fail "a required api-key pane message was ignored" journey


fail : String -> Journey -> Journey
fail message journey =
    { journey | failure = Just message }


{-| An intentionally stale completion. It must not change the visible pane;
the story's final screen assertions prove that. The old generation/copy ID only
addresses the simulated server response.
-}
stale : Page.Msg -> Journey -> Journey
stale msg journey =
    case Page.update ctx msg journey.model of
        Nothing ->
            journey

        Just ( model, _, _ ) ->
            { journey | model = model }


apply : Route -> Journey -> Journey
apply route journey =
    { journey
        | model =
            Page.initPreserving { route = route, today = Just Fixtures.today } journey.model
                |> Fixtures.tupleFirst
    }


keysLoaded : List ApiKey -> Journey -> Journey
keysLoaded keys journey =
    case keysGeneration journey.model of
        Ok generation ->
            send (keysLoadedMsg generation keys)
                { journey
                    | previousListGeneration = journey.listGeneration
                    , listGeneration = Just generation
                }

        Err message ->
            fail message journey


staleOldList : List ApiKey -> Journey -> Journey
staleOldList keys journey =
    case journey.previousListGeneration of
        Just generation ->
            stale (keysLoadedMsg generation keys) journey

        Nothing ->
            fail "the previous list generation is missing" journey


sendKeys : ApiKeys.Msg -> Journey -> Journey
sendKeys msg journey =
    case keysGeneration journey.model of
        Ok generation ->
            send (Page.GotApiKeysMsg generation msg) journey

        Err message ->
            fail message journey


sendCreate : ApiKeyCreate.Msg -> Journey -> Journey
sendCreate msg journey =
    case createGeneration journey.model of
        Ok generation ->
            send (Page.GotApiKeyCreateMsg generation msg) journey

        Err message ->
            fail message journey


submitCreate : Journey -> Journey
submitCreate journey =
    let
        next : Journey
        next =
            sendCreate ApiKeyCreate.Submitted journey
    in
    case ( createGeneration journey.model, pendingCreateRequest next.model ) of
        ( Ok generation, Ok requestId ) ->
            { next
                | previousCreate = journey.create
                , create = Just { generation = generation, requestId = requestId }
            }

        ( Err message, _ ) ->
            fail message next

        ( _, Err message ) ->
            fail message next


completeCreate : Result Client.ApiError CreatedApiKey -> Journey -> Journey
completeCreate result journey =
    case journey.create of
        Just ref ->
            sendCreate (ApiKeyCreate.CreateCompleted ref.requestId result) journey

        Nothing ->
            fail "the pending create request is missing" journey


completePreviousCreate : Result Client.ApiError CreatedApiKey -> Journey -> Journey
completePreviousCreate result journey =
    case journey.previousCreate of
        Just ref ->
            stale
                (Page.GotApiKeyCreateMsg ref.generation
                    (ApiKeyCreate.CreateCompleted ref.requestId result)
                )
                journey

        Nothing ->
            fail "the previous create request is missing" journey


startCopy : Journey -> Journey
startCopy journey =
    let
        next : Journey
        next =
            sendCreate ApiKeyCreate.CopyClicked journey
    in
    case copyInfo next.lastOut of
        Ok info ->
            { next | previousCopy = journey.copy, copy = Just info }

        Err message ->
            fail message next


completeCurrentCopy : Bool -> Journey -> Journey
completeCurrentCopy succeeded journey =
    case journey.copy of
        Just info ->
            send (Page.CopyTextResult info.generation info.copyId succeeded) journey

        Nothing ->
            fail "the pending copy request is missing" journey


completePreviousCopy : Bool -> Journey -> Journey
completePreviousCopy succeeded journey =
    case journey.previousCopy of
        Just info ->
            stale (Page.CopyTextResult info.generation info.copyId succeeded) journey

        Nothing ->
            fail "the previous copy request is missing" journey



-- PANE ACCESS


copyInfo : Page.OutMsg -> Result String CopyInfo
copyInfo outMsg =
    case outMsg of
        Page.CopyText generation copyId token ->
            Ok { generation = generation, copyId = copyId, token = token }

        _ ->
            Err "the create pane did not emit CopyText"


pendingCreateRequest : Page.Model -> Result String Int
pendingCreateRequest model =
    case apiKeyCreatePane model of
        Just ( _, pane ) ->
            case pane of
                ApiKeyCreate.Form form ->
                    case form.form.state of
                        ApiKeyCreate.Submitting requestId ->
                            Ok requestId

                        _ ->
                            Err "the create pane has no pending request"

                ApiKeyCreate.Created _ ->
                    Err "the create pane already shows a created key"

        Nothing ->
            Err "the create pane is absent"


keysGeneration : Page.Model -> Result String Int
keysGeneration model =
    case apiKeysPane model of
        Just ( generation, _ ) ->
            Ok generation

        Nothing ->
            Err "the api-key list pane is absent"


createGeneration : Page.Model -> Result String Int
createGeneration model =
    case apiKeyCreatePane model of
        Just ( generation, _ ) ->
            Ok generation

        Nothing ->
            Err "the api-key create pane is absent"


apiKeysPane : Page.Model -> Maybe ( Int, ApiKeys.Model )
apiKeysPane model =
    model.panes
        |> List.filterMap
            (\pane ->
                case pane of
                    Page.ApiKeysPane generation sub ->
                        Just ( generation, sub )

                    _ ->
                        Nothing
            )
        |> List.head


apiKeyCreatePane : Page.Model -> Maybe ( Int, ApiKeyCreate.Model )
apiKeyCreatePane model =
    model.panes
        |> List.filterMap
            (\pane ->
                case pane of
                    Page.ApiKeyCreatePane generation sub ->
                        Just ( generation, sub )

                    _ ->
                        Nothing
            )
        |> List.head



-- PROJECTIONS


apiKeysScreenOf : Page.Model -> Projection.ApiKeysScreen
apiKeysScreenOf model =
    apiKeysPane model
        |> Maybe.map (Tuple.second >> Projection.apiKeysScreen)
        |> Maybe.withDefault { names = [], error = Nothing, dialog = Nothing }


createScreenOf : Page.Model -> Projection.CreateScreen
createScreenOf model =
    apiKeyCreatePane model
        |> Maybe.map (Tuple.second >> Projection.createScreen)
        |> Maybe.withDefault { form = Nothing, created = Nothing }


keysLoadedMsg : Int -> List ApiKey -> Page.Msg
keysLoadedMsg generation keys =
    Page.GotApiKeysMsg generation (ApiKeys.ApiKeysLoaded (Ok keys))


ctx : Page.InitCtx
ctx =
    { route = SettingsApiKeys, today = Just Fixtures.today }
