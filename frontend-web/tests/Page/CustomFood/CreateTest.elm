module Page.CustomFood.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CategorySuggestion, CreateFoodRequest, NutrientItem, UnitItem)
import Component.FoodEditor as Form
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Page.CustomFood.Create as CustomFoodCreate
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.Theme as Theme


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.CustomFood.Create"
        [ test "manual init does not request assistant status" <|
            \_ ->
                CustomFoodCreate.init
                    |> Tuple.second
                    |> Expect.equal CustomFoodCreate.NoOp
        , test "AI init requests assistant status" <|
            \_ ->
                CustomFoodCreate.initWithAssistant
                    |> Tuple.second
                    |> Expect.equal CustomFoodCreate.RequestInitialData
        , test "nutrient load stores items and seeds form catalog" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.NutrientsLoaded (Ok { items = nutrientItems }))
                    initialModel
                    |> first
                    |> .form
                    |> Form.update (Form.NutrientCodeChanged 0 "PROTEIN_G")
                    |> first
                    |> .nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "g")
        , test "unit load stores units and clears prior error" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.UnitsLoaded (Ok { items = [ gram ] }))
                    { initialModel | error = Just "old error" }
                    |> first
                    |> (\model -> ( model.units, model.error ))
                    |> Expect.equal ( [ gram ], Nothing )
        , test "load failure stores display error" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.NutrientsLoaded (Err Client.NetworkError))
                    initialModel
                    |> first
                    |> .error
                    |> Expect.equal (Just networkErrorMessage)
        , test "load unauthorized emits session expired" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.UnitsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    initialModel
                    |> third
                    |> Expect.equal CustomFoodCreate.SessionExpired
        , test "form category query forwards suggestion request" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                    initialModel
                    |> third
                    |> Expect.equal
                        (CustomFoodCreate.RequestCategorySuggestions (ticket 1)
                            { query = "dai", limit = 8 }
                        )
        , test "category suggestions update matching form token" <|
            \_ ->
                let
                    queried : CustomFoodCreate.Model
                    queried =
                        CustomFoodCreate.update
                            (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                            initialModel
                            |> first
                in
                CustomFoodCreate.update
                    (CustomFoodCreate.CategorySuggestionsLoaded
                        (ticket 1)
                        (Ok { items = [ dairySuggestion ] })
                    )
                    queried
                    |> first
                    |> .form
                    |> .categoryInput
                    |> .suggestions
                    |> Expect.equal [ dairySuggestion ]
        , test "stale category suggestions are ignored" <|
            \_ ->
                let
                    queried : CustomFoodCreate.Model
                    queried =
                        CustomFoodCreate.update
                            (CustomFoodCreate.FormMsg (Form.CategoryQueryChanged "dai"))
                            initialModel
                            |> first
                in
                CustomFoodCreate.update
                    (CustomFoodCreate.CategorySuggestionsLoaded
                        (ticket 0)
                        (Ok { items = [ dairySuggestion ] })
                    )
                    queried
                    |> first
                    |> .form
                    |> .categoryInput
                    |> .suggestions
                    |> Expect.equal []
        , test "submit with valid form requests create food" <|
            \_ ->
                CustomFoodCreate.update CustomFoodCreate.SubmitClicked validModel
                    |> (\( model, _, outMsg ) ->
                            ( model.form.submit, outMsg )
                       )
                    |> Expect.equal
                        ( Form.Submitting
                        , CustomFoodCreate.RequestCreateFood validRequest
                        )
        , test "create view only asks for per-100 g food data" <|
            \_ ->
                CustomFoodCreate.view
                    { theme = Theme.light
                    , device = { class = Phone, orientation = Portrait }
                    , language = Util.EN_US
                    }
                    validModel
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Nutrients" ]
                        , Query.hasNot
                            [ Selector.text "Servings"
                            , Selector.text "Default Portion"
                            ]
                        ]
        , test "save success navigates to detail" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.SaveCompleted (Ok { id = "food-1" }))
                    validModel
                    |> third
                    |> Expect.equal (CustomFoodCreate.Navigate (CustomFoodShow "food-1"))
        , test "save failure stores submit error" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.SaveCompleted (Err Client.NetworkError))
                    validModel
                    |> first
                    |> .form
                    |> .submit
                    |> Expect.equal (Form.SubmitFailed networkErrorMessage)
        , test "save unauthorized emits session expired" <|
            \_ ->
                CustomFoodCreate.update
                    (CustomFoodCreate.SaveCompleted
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    validModel
                    |> third
                    |> Expect.equal CustomFoodCreate.SessionExpired
        ]


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
                , nutrients =
                    [ { code = "PROTEIN_G", amount = "18", unit = "g" } ]
                , defaultQuantity = "2"
                , defaultUnit = "piece"
                , servings =
                    [ { unit = "piece", gramsPerUnit = "50" } ]
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


dairySuggestion : CategorySuggestion
dairySuggestion =
    { value = "dairy", count = 4 }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "PROTEIN_G", name = "Protein", unit = "g", category = "macros" } ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
