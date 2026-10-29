module Page.CustomFood.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CategorySuggestion, NutrientItem, UnitItem)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Form
import Data.FoodAssistant exposing (FoodDraftTurn(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Ticket exposing (Ticket)
import Page.CustomFood.Create as CustomFoodCreate
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Create"
        [ test "a user creates a food manually" <|
            \_ ->
                preparedManualFood
                    |> step CustomFoodCreate.SubmitClicked
                    |> step (CustomFoodCreate.SaveCompleted (Ok { id = "food-1" }))
                    |> finish
                        (\( saved, completionOut ) ->
                            { screen = toScreen saved
                            , finalOut = completionOut
                            }
                                |> Expect.equal
                                    { screen =
                                        { name = "Paneer"
                                        , categories = [ "dairy" ]
                                        , nutrients = []
                                        , error = Nothing
                                        }
                                    , finalOut =
                                        CustomFoodCreate.Navigate (CustomFoodShow "food-1")
                                    }
                        )
        , test "a user creates a food from an AI draft" <|
            \_ ->
                preparedDraft
                    |> step CustomFoodCreate.SubmitClicked
                    |> step (CustomFoodCreate.SaveCompleted (Ok { id = "food-1" }))
                    |> finish
                        (\( saved, completionOut ) ->
                            { screen = toScreen saved
                            , finalOut = completionOut
                            }
                                |> Expect.equal
                                    { screen =
                                        { name = "Paneer"
                                        , categories = [ "dairy" ]
                                        , nutrients = [ "PROTEIN_G:18" ]
                                        , error = Nothing
                                        }
                                    , finalOut =
                                        CustomFoodCreate.Navigate (CustomFoodShow "food-1")
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                preparedManualFood
                    |> step CustomFoodCreate.SubmitClicked
                    |> step
                        (CustomFoodCreate.SaveCompleted (Err Client.NetworkError))
                    |> step CustomFoodCreate.SubmitClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { request = createRequest outMsg
                            , disabled = Form.isSubmitting model.form.submit
                            }
                                |> Expect.equal
                                    { request = Just categorizedRequest
                                    , disabled = True
                                    }
                        )
        ]


type alias Screen =
    { name : String
    , categories : List String
    , nutrients : List String
    , error : Maybe String
    }


toScreen : CustomFoodCreate.Model -> Screen
toScreen model =
    { name = model.form.name
    , categories = model.form.categoryInput.selected
    , nutrients = List.filterMap nutrientRow model.form.nutrients
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


createRequest : CustomFoodCreate.OutMsg -> Maybe Api.Foods.CreateFoodRequest
createRequest outMsg =
    case outMsg of
        CustomFoodCreate.RequestCreateFood request ->
            Just request

        _ ->
            Nothing


categoryRequest : CustomFoodCreate.OutMsg -> Maybe Ticket
categoryRequest outMsg =
    case outMsg of
        CustomFoodCreate.RequestCategorySuggestions token _ ->
            Just token

        _ ->
            Nothing



-- STORY PIPELINE


type alias Journey =
    Story.Journey CustomFoodCreate.Model CustomFoodCreate.OutMsg


step : CustomFoodCreate.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CustomFoodCreate.update)


bind :
    (CustomFoodCreate.OutMsg -> Result String CustomFoodCreate.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind (Story.ignoreCmd CustomFoodCreate.update)


finish :
    (( CustomFoodCreate.Model, CustomFoodCreate.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


preparedManualFood : Journey
preparedManualFood =
    CustomFoodCreate.init
        |> Story.start
        |> step (CustomFoodCreate.NutrientsLoaded (Ok { items = nutrientItems }))
        |> step (CustomFoodCreate.UnitsLoaded (Ok { items = [ gram ] }))
        |> step (CustomFoodCreate.FormMsg (Form.NameChanged "Paneer"))
        |> step (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
        |> bind
            (\out ->
                case categoryRequest out of
                    Just token ->
                        Ok
                            (CustomFoodCreate.CategorySuggestionsLoaded token
                                (Ok { items = [ dairySuggestion ] })
                            )

                    Nothing ->
                        Err "the category query produced no request"
            )
        |> step (CustomFoodCreate.FormMsg (Form.AcceptCategorySuggestion "dairy"))


preparedDraft : Journey
preparedDraft =
    CustomFoodCreate.initWithAssistant
        |> Story.start
        |> step (CustomFoodCreate.NutrientsLoaded (Ok { items = nutrientItems }))
        |> step (CustomFoodCreate.UnitsLoaded (Ok { items = [ gram ] }))
        |> step
            (CustomFoodCreate.AssistantMsg
                (Assistant.StatusLoaded
                    (Ok { enabled = True, supportsImages = False })
                )
            )
        |> step (CustomFoodCreate.AssistantMsg (Assistant.DescriptionChanged "paneer"))
        |> step (CustomFoodCreate.AssistantMsg Assistant.SendClicked)
        |> bind
            (\out ->
                case out of
                    CustomFoodCreate.RequestFoodDraft _ _ _ ->
                        Ok
                            (CustomFoodCreate.AssistantMsg
                                (Assistant.DraftCompleted (Ok readyTurn))
                            )

                    _ ->
                        Err "the assistant send produced no draft request"
            )
        |> step (CustomFoodCreate.AssistantMsg (Assistant.ApplyDraftClicked False))


categorizedRequest : Api.Foods.CreateFoodRequest
categorizedRequest =
    { name = "Paneer"
    , brand = Nothing
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = []
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
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" }
    , { code = "ENERGY_KCAL", name = "Energy", unit = "kcal", category = "energy" }
    ]


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
