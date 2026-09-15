module Page.CustomFood.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CreateFoodRequest, NutrientItem, ProductDetail, UnitItem)
import Component.FoodEditor as Form
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Page.CustomFood.Edit as CustomFoodEdit
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Edit"
        [ test "loaded form keeps nutrient unit when food arrives before nutrients" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Tuple.first
                    |> CustomFoodEdit.update (CustomFoodEdit.FoodLoaded (Ok food))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.FormMsg
                            (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                        )
                    |> first
                    |> firstNutrientUnit
                    |> Expect.equal (Just "g")
        , test "loaded form keeps nutrient unit when food arrives last" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Tuple.first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.FoodLoaded (Ok food))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.FormMsg
                            (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                        )
                    |> first
                    |> firstNutrientUnit
                    |> Expect.equal (Just "g")
        , test "init requests initial data for the product" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Tuple.second
                    |> Expect.equal (CustomFoodEdit.RequestInitialData "food-1")
        , test "food load failure moves to load failed" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FoodLoaded (Err Client.NetworkError))
                    (Tuple.first (CustomFoodEdit.init "food-1"))
                    |> first
                    |> Expect.equal (CustomFoodEdit.LoadFailed "Network error")
        , test "load failure unauthorized expires session" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.NutrientsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    (Tuple.first (CustomFoodEdit.init "food-1"))
                    |> third
                    |> Expect.equal CustomFoodEdit.SessionExpired
        , test "successful unit load updates loaded units" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.UnitsLoaded (Ok { items = [ ounce ] }))
                    loadedModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ ounce ])
        , test "successful nutrient load updates loaded nutrient catalog" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                    loadedModel
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.FormMsg
                            (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                        )
                    |> first
                    |> firstNutrientUnit
                    |> Expect.equal (Just "g")
        , test "load success is ignored after load failed" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FoodLoaded (Ok food))
                    (CustomFoodEdit.LoadFailed "old")
                    |> first
                    |> Expect.equal (CustomFoodEdit.LoadFailed "old")
        , test "form category query forwards suggestion request" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FormMsg (Form.CategoryQueryChanged "dai"))
                    loadedModel
                    |> third
                    |> Expect.equal
                        (CustomFoodEdit.RequestCategorySuggestions (ticket 1)
                            { query = "dai", limit = 8 }
                        )
        , test "category suggestions update loaded form" <|
            \_ ->
                let
                    queried : CustomFoodEdit.Model
                    queried =
                        CustomFoodEdit.update
                            (CustomFoodEdit.FormMsg (Form.CategoryQueryChanged "dai"))
                            loadedModel
                            |> first
                in
                CustomFoodEdit.update
                    (CustomFoodEdit.CategorySuggestionsLoaded
                        (ticket 1)
                        (Ok { items = [ { value = "dairy", count = 3 } ] })
                    )
                    queried
                    |> first
                    |> categorySuggestionsOf
                    |> Expect.equal (Just [ { value = "dairy", count = 3 } ])
        , test "submit with valid form requests update" <|
            \_ ->
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked validLoadedModel
                    |> (\( model, _, outMsg ) ->
                            ( submitStateOf model, outMsg )
                       )
                    |> Expect.equal
                        ( Just Form.Submitting
                        , CustomFoodEdit.RequestUpdateFood "food-1" validRequest
                        )
        , test "save success while submitting navigates to detail" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                    submittingModel
                    |> third
                    |> Expect.equal (CustomFoodEdit.Navigate (CustomFoodShow "food-1"))
        , test "save failure while submitting stores submit error" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.SaveCompleted (Err Client.NetworkError))
                    submittingModel
                    |> first
                    |> submitStateOf
                    |> Expect.equal (Just (Form.SubmitFailed "Network error"))
        , test "save unauthorized while submitting expires session" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.SaveCompleted
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    submittingModel
                    |> third
                    |> Expect.equal CustomFoodEdit.SessionExpired
        , test "save completion is ignored unless submitting" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                    validLoadedModel
                    |> third
                    |> Expect.equal CustomFoodEdit.NoOp
        ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


firstNutrientUnit : CustomFoodEdit.Model -> Maybe String
firstNutrientUnit model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            loaded.form.nutrients
                |> List.head
                |> Maybe.map .unit

        _ ->
            Nothing


unitsOf : CustomFoodEdit.Model -> Maybe (List UnitItem)
unitsOf model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            Just loaded.units

        _ ->
            Nothing


categorySuggestionsOf :
    CustomFoodEdit.Model
    -> Maybe (List { value : String, count : Int })
categorySuggestionsOf model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            Just loaded.form.categoryInput.suggestions

        _ ->
            Nothing


submitStateOf : CustomFoodEdit.Model -> Maybe Form.SubmitState
submitStateOf model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            Just loaded.form.submit

        _ ->
            Nothing


loadedModel : CustomFoodEdit.Model
loadedModel =
    loadedWithForm Form.emptyForm


validLoadedModel : CustomFoodEdit.Model
validLoadedModel =
    let
        base : Form.FormModel
        base =
            Form.emptyForm
    in
    loadedWithForm
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
            , servings = [ { unit = "piece", gramsPerUnit = "50" } ]
        }


submittingModel : CustomFoodEdit.Model
submittingModel =
    case validLoadedModel of
        CustomFoodEdit.Loaded loaded ->
            let
                form : Form.FormModel
                form =
                    loaded.form
            in
            CustomFoodEdit.Loaded
                { loaded | form = { form | submit = Form.Submitting } }

        _ ->
            validLoadedModel


loadedWithForm : Form.FormModel -> CustomFoodEdit.Model
loadedWithForm form =
    CustomFoodEdit.Loaded
        { productId = "food-1"
        , form = form
        , nutrients = nutrientItems
        , units = [ gram ]
        }


validRequest : CreateFoodRequest
validRequest =
    { name = "Paneer"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
    , servings = [ { unit = "piece", gramsPerUnit = 50 } ]
    }


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Curd"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "cup"
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


ounce : UnitItem
ounce =
    { code = "oz", name = "Ounce", kind = "mass" }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "ENERGY_KCAL"
      , name = "Energy"
      , unit = "kcal"
      , category = "energy"
      }
    , { code = "MONOUNSATURATED_FAT_G"
      , name = "Monounsaturated Fat"
      , unit = "g"
      , category = "macros"
      }
    ]


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
