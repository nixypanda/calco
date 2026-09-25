module Page.CustomFood.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CategorySuggestion, CreateFoodRequest, NutrientItem)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Form
import Data.FoodAssistant exposing (FoodDraftTurn(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Page.CustomFood.Create as CustomFoodCreate
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.CustomFood.Create"
        [ test "typing a category asks for suggestions and ignores a stale result" <|
            \_ ->
                let
                    queried : CustomFoodCreate.Model
                    queried =
                        queryChanged "dai" initialModel

                    stale : CustomFoodCreate.Model
                    stale =
                        step
                            (CustomFoodCreate.CategorySuggestionsLoaded
                                (ticket 0)
                                (Ok { items = [ dairySuggestion ] })
                            )
                            queried

                    fresh : CustomFoodCreate.Model
                    fresh =
                        step
                            (CustomFoodCreate.CategorySuggestionsLoaded
                                (ticket 1)
                                (Ok { items = [ dairySuggestion ] })
                            )
                            queried
                in
                { request =
                    out
                        (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                        initialModel
                , staleSuggestions = toScreen stale |> .suggestions
                , freshSuggestions = toScreen fresh |> .suggestions
                }
                    |> Expect.equal
                        { request =
                            CustomFoodCreate.RequestCategorySuggestions (ticket 1)
                                { query = "dai", limit = 8 }
                        , staleSuggestions = []
                        , freshSuggestions = [ "dairy" ]
                        }
        , test "a nutrient load seeds the catalog while a failure surfaces the banner" <|
            \_ ->
                let
                    seeded : CustomFoodCreate.Model
                    seeded =
                        nutrientsOk initialModel |> nutrientCode "PROTEIN_G"

                    failed : CustomFoodCreate.Model
                    failed =
                        nutrientsFailed initialModel
                in
                { seededUnit = toScreen seeded |> .firstNutrientUnit
                , failedError = toScreen failed |> .error
                }
                    |> Expect.equal
                        { seededUnit = Just "g"
                        , failedError = Just networkErrorMessage
                        }
        , test "an unauthorized load expires the session" <|
            \_ ->
                out
                    (CustomFoodCreate.UnitsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    initialModel
                    |> Expect.equal CustomFoodCreate.SessionExpired
        , test "submitting requests creation and a confirmed save navigates to the detail" <|
            \_ ->
                let
                    invalidSubmit : UpdateResult
                    invalidSubmit =
                        CustomFoodCreate.update CustomFoodCreate.SubmitClicked initialModel

                    validSubmit : UpdateResult
                    validSubmit =
                        CustomFoodCreate.update CustomFoodCreate.SubmitClicked validModel

                    submitting : CustomFoodCreate.Model
                    submitting =
                        first validSubmit

                    saveFailed : CustomFoodCreate.Model
                    saveFailed =
                        step (CustomFoodCreate.SaveCompleted (Err Client.NetworkError)) submitting

                    saved : CustomFoodCreate.OutMsg
                    saved =
                        out (CustomFoodCreate.SaveCompleted (Ok { id = "food-1" })) submitting
                in
                { invalidRequest = third invalidSubmit
                , invalidSubmitState = toScreen (first invalidSubmit) |> .submit
                , validRequest = third validSubmit
                , validSubmitState = toScreen submitting |> .submit
                , failureSubmitState = toScreen saveFailed |> .submit
                , retryRequest = out CustomFoodCreate.SubmitClicked saveFailed
                , saveSuccess = saved
                }
                    |> Expect.equal
                        { invalidRequest = CustomFoodCreate.NoOp
                        , invalidSubmitState = Just (Form.SubmitFailed "Name is required")
                        , validRequest = CustomFoodCreate.RequestCreateFood validRequest
                        , validSubmitState = Just Form.Submitting
                        , failureSubmitState = Just (Form.SubmitFailed networkErrorMessage)
                        , retryRequest = CustomFoodCreate.RequestCreateFood validRequest
                        , saveSuccess = CustomFoodCreate.Navigate (CustomFoodShow "food-1")
                        }
        , test "an assistant draft applies into the create form and submits as a custom food" <|
            \_ ->
                let
                    applied : CustomFoodCreate.Model
                    applied =
                        initialModel
                            |> nutrientsOk
                            |> assistantMsg enabledStatus
                            |> assistantMsg (Assistant.DescriptionChanged "paneer")
                            |> assistantMsg Assistant.SendClicked
                            |> assistantMsg (Assistant.DraftCompleted (Ok readyTurn))
                            |> assistantMsg (Assistant.ApplyDraftClicked False)
                in
                out CustomFoodCreate.SubmitClicked applied
                    |> Expect.equal (CustomFoodCreate.RequestCreateFood draftRequest)
        ]



-- SCREEN PROJECTION


type alias Screen =
    { suggestions : List String
    , firstNutrientUnit : Maybe String
    , submit : Maybe Form.SubmitState
    , error : Maybe String
    }


toScreen : CustomFoodCreate.Model -> Screen
toScreen model =
    { suggestions = List.map .value model.form.categoryInput.suggestions
    , firstNutrientUnit = model.form.nutrients |> List.head |> Maybe.map .unit
    , submit = Just model.form.submit
    , error = model.error
    }


type alias UpdateResult =
    ( CustomFoodCreate.Model, Cmd CustomFoodCreate.Msg, CustomFoodCreate.OutMsg )


step : CustomFoodCreate.Msg -> CustomFoodCreate.Model -> CustomFoodCreate.Model
step msg model =
    first (CustomFoodCreate.update msg model)


out : CustomFoodCreate.Msg -> CustomFoodCreate.Model -> CustomFoodCreate.OutMsg
out msg model =
    third (CustomFoodCreate.update msg model)


queryChanged : String -> CustomFoodCreate.Model -> CustomFoodCreate.Model
queryChanged query model =
    step (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged query)) model


nutrientCode : String -> CustomFoodCreate.Model -> CustomFoodCreate.Model
nutrientCode code model =
    step (CustomFoodCreate.FormMsg (Form.NutrientCodeChanged 0 code)) model


nutrientsOk : CustomFoodCreate.Model -> CustomFoodCreate.Model
nutrientsOk model =
    step (CustomFoodCreate.NutrientsLoaded (Ok { items = nutrientItems })) model


nutrientsFailed : CustomFoodCreate.Model -> CustomFoodCreate.Model
nutrientsFailed model =
    step (CustomFoodCreate.NutrientsLoaded (Err Client.NetworkError)) model


assistantMsg : Assistant.Msg -> CustomFoodCreate.Model -> CustomFoodCreate.Model
assistantMsg msg model =
    step (CustomFoodCreate.AssistantMsg msg) model


enabledStatus : Assistant.Msg
enabledStatus =
    Assistant.StatusLoaded (Ok { enabled = True, supportsImages = False })


initialModel : CustomFoodCreate.Model
initialModel =
    Tuple.first CustomFoodCreate.init


validModel : CustomFoodCreate.Model
validModel =
    let
        base : Form.FormModel
        base =
            Form.emptyForm
    in
    { initialModel
        | form =
            { base
                | name = "Paneer"
                , brand = "Local"
                , categoryInput =
                    { selected = [ "dairy" ]
                    , query = ""
                    , suggestions = []
                    , token = ticket 0
                    }
                , nutrients = [ { code = "PROTEIN_G", amount = "18", unit = "g" } ]
                , defaultQuantity = "2"
                , defaultUnit = "piece"
                , servings = [ { unit = "piece", gramsPerUnit = "50" } ]
            }
    }


validRequest : CreateFoodRequest
validRequest =
    { name = "Paneer"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
    , servings = []
    }


draftRequest : CreateFoodRequest
draftRequest =
    { name = "Paneer"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
    , servings = []
    }


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft =
            { name = "Paneer"
            , brand = Just "Local"
            , categories = [ "dairy" ]
            , defaultQuantity = Just "1"
            , defaultUnit = Just "serving"
            , nutrients = [ { code = "PROTEIN_G", amountPer100g = "18" } ]
            , servings = [ { unit = "serving", gramsPerUnit = "50" } ]
            }
        , suggestedLog = Nothing
        , warnings = []
        }


dairySuggestion : CategorySuggestion
dairySuggestion =
    { value = "dairy", count = 4 }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" } ]


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
