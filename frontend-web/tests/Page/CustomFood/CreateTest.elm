module Page.CustomFood.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CategorySuggestion, NutrientItem, UnitItem)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Form
import Data.FoodAssistant as FoodAssistant exposing (FoodDraftTurn(..))
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Ticket exposing (Ticket)
import Page.CustomFood.Create as CustomFoodCreate
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.CustomFood.Create"
        [ test "units clear a catalog error, then a categorized food is validated and saved" <|
            \_ ->
                let
                    started : CustomFoodCreate.Model
                    started =
                        Tuple.first CustomFoodCreate.init

                    catalogFailed : CustomFoodCreate.Model
                    catalogFailed =
                        step
                            (CustomFoodCreate.NutrientsLoaded (Err Client.NetworkError))
                            started

                    ( catalogCleared, _ ) =
                        stepWithOut
                            (CustomFoodCreate.UnitsLoaded (Ok { items = [ gram ] }))
                            catalogFailed

                    loaded : CustomFoodCreate.Model
                    loaded =
                        step
                            (CustomFoodCreate.NutrientsLoaded (Ok { items = nutrientItems }))
                            catalogCleared

                    invalid : CustomFoodCreate.Model
                    invalid =
                        step CustomFoodCreate.SubmitClicked loaded

                    ( named, _ ) =
                        stepWithOut
                            (CustomFoodCreate.FormMsg (Form.NameChanged "Paneer"))
                            invalid

                    ( querying, categoryOut ) =
                        stepWithOut
                            (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                            named
                in
                case categoryRequest categoryOut of
                    Just category ->
                        let
                            suggesting : CustomFoodCreate.Model
                            suggesting =
                                step
                                    (CustomFoodCreate.CategorySuggestionsLoaded
                                        category.token
                                        (Ok { items = [ dairySuggestion ] })
                                    )
                                    querying

                            categorized : CustomFoodCreate.Model
                            categorized =
                                step
                                    (CustomFoodCreate.FormMsg
                                        (Form.AcceptCategorySuggestion "dairy")
                                    )
                                    suggesting

                            ( submitting, createOut ) =
                                stepWithOut CustomFoodCreate.SubmitClicked categorized

                            ( failed, _ ) =
                                stepWithOut
                                    (CustomFoodCreate.SaveCompleted (Err Client.NetworkError))
                                    submitting

                            ( retrying, _ ) =
                                stepWithOut CustomFoodCreate.SubmitClicked failed

                            ( saved, completionOut ) =
                                stepWithOut
                                    (CustomFoodCreate.SaveCompleted (Ok { id = "food-1" }))
                                    retrying
                        in
                        { errorTransition =
                            ( (toScreen catalogFailed).error
                            , (toScreen catalogCleared).error
                            )
                        , validation = (toScreen invalid).error
                        , categoryRequest =
                            Just { query = category.query, limit = category.limit }
                        , request = createRequest createOut
                        , failure = (toScreen failed).error
                        , screen = toScreen saved
                        , finalOut = completionOut
                        }
                            |> Expect.equal
                                { errorTransition =
                                    ( Just Fixtures.networkErrorMessage, Nothing )
                                , validation = Just nameRequired
                                , categoryRequest = Just { query = "dai", limit = 8 }
                                , request = Just categorizedRequest
                                , failure = Just Fixtures.networkErrorMessage
                                , screen =
                                    { name = "Paneer"
                                    , categories = [ "dairy" ]
                                    , nutrients = []
                                    , disabled = True
                                    , error = Nothing
                                    }
                                , finalOut =
                                    CustomFoodCreate.Navigate (CustomFoodShow "food-1")
                                }

                    Nothing ->
                        Expect.fail "the category query produced no request"
        , test "an assistant draft applies, a stale category token is ignored, and a 401 expires" <|
            \_ ->
                let
                    started : CustomFoodCreate.Model
                    started =
                        Tuple.first CustomFoodCreate.initWithAssistant
                            |> runSteps step
                                [ CustomFoodCreate.NutrientsLoaded
                                    (Ok { items = nutrientItems })
                                , CustomFoodCreate.UnitsLoaded (Ok { items = [ gram ] })
                                , CustomFoodCreate.AssistantMsg
                                    (Assistant.StatusLoaded
                                        (Ok { enabled = True, supportsImages = False })
                                    )
                                ]

                    describing : CustomFoodCreate.Model
                    describing =
                        step
                            (CustomFoodCreate.AssistantMsg
                                (Assistant.DescriptionChanged "paneer")
                            )
                            started

                    ( sending, sendOut ) =
                        stepWithOut
                            (CustomFoodCreate.AssistantMsg Assistant.SendClicked)
                            describing

                    applied : CustomFoodCreate.Model
                    applied =
                        sending
                            |> step
                                (CustomFoodCreate.AssistantMsg
                                    (Assistant.DraftCompleted (Ok readyTurn))
                                )
                            |> step
                                (CustomFoodCreate.AssistantMsg
                                    (Assistant.ApplyDraftClicked False)
                                )

                    ( firstQuery, firstOut ) =
                        stepWithOut
                            (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "da"))
                            applied

                    ( secondQuery, secondOut ) =
                        stepWithOut
                            (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                            firstQuery
                in
                case ( assistantRequest sendOut, categoryTokens firstOut secondOut ) of
                    ( Just request, Just ( staleToken, currentToken ) ) ->
                        let
                            stale : CustomFoodCreate.Model
                            stale =
                                step
                                    (CustomFoodCreate.CategorySuggestionsLoaded
                                        staleToken
                                        (Ok { items = [ otherSuggestion ] })
                                    )
                                    secondQuery

                            suggested : CustomFoodCreate.Model
                            suggested =
                                step
                                    (CustomFoodCreate.CategorySuggestionsLoaded
                                        currentToken
                                        (Ok { items = [ dairySuggestion ] })
                                    )
                                    stale

                            ( submitting, createOut ) =
                                stepWithOut CustomFoodCreate.SubmitClicked suggested

                            ( final, completionOut ) =
                                stepWithOut
                                    (CustomFoodCreate.SaveCompleted (Err Fixtures.unauthorized))
                                    submitting
                        in
                        { request = request
                        , applied = toScreen applied
                        , staleSuggestions = suggestions stale
                        , suggestions = suggestions suggested
                        , createRequest = createRequest createOut
                        , screen = toScreen final
                        , finalOut = completionOut
                        }
                            |> Expect.equal
                                { request = assistantRequestValue
                                , applied = draftScreen
                                , staleSuggestions = []
                                , suggestions = [ "dairy" ]
                                , createRequest = Just draftCreateRequest
                                , screen =
                                    { name = "Paneer"
                                    , categories = [ "dairy" ]
                                    , nutrients = [ "PROTEIN_G:18" ]
                                    , disabled = False
                                    , error = Just "Sign in again"
                                    }
                                , finalOut = CustomFoodCreate.SessionExpired
                                }

                    _ ->
                        Expect.fail "the assistant send or category typing produced no request"
        ]


type alias Screen =
    { name : String
    , categories : List String
    , nutrients : List String
    , disabled : Bool
    , error : Maybe String
    }


toScreen : CustomFoodCreate.Model -> Screen
toScreen model =
    { name = model.form.name
    , categories = model.form.categoryInput.selected
    , nutrients = List.filterMap nutrientRow model.form.nutrients
    , disabled = Form.isSubmitting model.form.submit
    , error = firstError model.error model.form.submit
    }


firstError : Maybe String -> Form.SubmitState -> Maybe String
firstError loadError submit =
    case loadError of
        Just message ->
            Just message

        Nothing ->
            case submit of
                Form.SubmitFailed message ->
                    Just message

                _ ->
                    Nothing


nutrientRow : Form.NutrientRow -> Maybe String
nutrientRow row =
    if String.isEmpty row.code && String.isEmpty row.amount then
        Nothing

    else
        Just (row.code ++ ":" ++ row.amount)


suggestions : CustomFoodCreate.Model -> List String
suggestions model =
    List.map .value model.form.categoryInput.suggestions


draftScreen : Screen
draftScreen =
    { name = "Paneer"
    , categories = [ "dairy" ]
    , nutrients = [ "PROTEIN_G:18" ]
    , disabled = False
    , error = Nothing
    }


createRequest : CustomFoodCreate.OutMsg -> Maybe Api.Foods.CreateFoodRequest
createRequest outMsg =
    case outMsg of
        CustomFoodCreate.RequestCreateFood request ->
            Just request

        _ ->
            Nothing


type alias CategoryRequest =
    { token : Ticket, query : String, limit : Int }


categoryRequest : CustomFoodCreate.OutMsg -> Maybe CategoryRequest
categoryRequest outMsg =
    case outMsg of
        CustomFoodCreate.RequestCategorySuggestions token request ->
            Just { token = token, query = request.query, limit = request.limit }

        _ ->
            Nothing


categoryTokens : CustomFoodCreate.OutMsg -> CustomFoodCreate.OutMsg -> Maybe ( Ticket, Ticket )
categoryTokens first second =
    case ( categoryRequest first, categoryRequest second ) of
        ( Just firstRequest, Just secondRequest ) ->
            Just ( firstRequest.token, secondRequest.token )

        _ ->
            Nothing


assistantRequest : CustomFoodCreate.OutMsg -> Maybe CustomFoodCreate.OutMsg
assistantRequest outMsg =
    case outMsg of
        CustomFoodCreate.RequestFoodDraft _ _ _ ->
            Just outMsg

        _ ->
            Nothing


step : CustomFoodCreate.Msg -> CustomFoodCreate.Model -> CustomFoodCreate.Model
step msg model =
    Fixtures.tupleFirst (CustomFoodCreate.update msg model)


stepWithOut :
    CustomFoodCreate.Msg
    -> CustomFoodCreate.Model
    -> ( CustomFoodCreate.Model, CustomFoodCreate.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            CustomFoodCreate.update msg model
    in
    ( next, outMsg )


assistantRequestValue : CustomFoodCreate.OutMsg
assistantRequestValue =
    case
        FoodAssistant.userTurn "paneer"
            |> Result.andThen (\turn -> FoodAssistant.conversation [ turn ])
    of
        Ok conversation ->
            CustomFoodCreate.RequestFoodDraft FoodAssistant.CustomFood conversation []

        Err _ ->
            CustomFoodCreate.NoOp


nameRequired : String
nameRequired =
    I18n.en TidCustomFoodNameRequired


baseFoodRequest : Api.Foods.CreateFoodRequest
baseFoodRequest =
    { name = "Paneer"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = []
    , servings = []
    }


categorizedRequest : Api.Foods.CreateFoodRequest
categorizedRequest =
    { baseFoodRequest | categories = [ "dairy" ] }


draftCreateRequest : Api.Foods.CreateFoodRequest
draftCreateRequest =
    { baseFoodRequest
        | brand = Just "Local"
        , categories = [ "dairy" ]
        , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
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


otherSuggestion : CategorySuggestion
otherSuggestion =
    { value = "other", count = 1 }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" }
    , { code = "ENERGY_KCAL", name = "Energy", unit = "kcal", category = "energy" }
    ]


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
