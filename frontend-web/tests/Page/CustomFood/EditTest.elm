module Page.CustomFood.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CreateFoodRequest, NutrientItem, ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Edit as CustomFoodEdit
import Page.CustomFood.Form as Form
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
        , test "form message updates loaded form" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FormMsg (Form.NameChanged "Paneer"))
                    loadedModel
                    |> first
                    |> loadedName
                    |> Expect.equal (Just "Paneer")
        , test "form message in loading state is ignored" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FormMsg (Form.NameChanged "Paneer"))
                    (Tuple.first (CustomFoodEdit.init "food-1"))
                    |> first
                    |> isLoading
                    |> Expect.equal True
        , test "form category query forwards suggestion request" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.FormMsg (Form.CategoryQueryChanged "dai"))
                    loadedModel
                    |> third
                    |> Expect.equal
                        (CustomFoodEdit.RequestCategorySuggestions 1
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
                        1
                        (Ok { items = [ { value = "dairy", count = 3 } ] })
                    )
                    queried
                    |> first
                    |> categorySuggestionsOf
                    |> Expect.equal (Just [ { value = "dairy", count = 3 } ])
        , test "category suggestions in loading state are ignored" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.CategorySuggestionsLoaded
                        1
                        (Ok { items = [ { value = "dairy", count = 3 } ] })
                    )
                    (Tuple.first (CustomFoodEdit.init "food-1"))
                    |> first
                    |> isLoading
                    |> Expect.equal True
        , test "submit with valid form requests update" <|
            \_ ->
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked validLoadedModel
                    |> third
                    |> Expect.equal (CustomFoodEdit.RequestUpdateFood "food-1" validRequest)
        , test "submit marks loaded form as submitting" <|
            \_ ->
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked validLoadedModel
                    |> first
                    |> submitStateOf
                    |> Expect.equal (Just Form.Submitting)
        , test "submit with missing name stores validation error" <|
            \_ ->
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked loadedModel
                    |> first
                    |> submitStateOf
                    |> Expect.equal (Just (Form.SubmitFailed "Name is required"))
        , test "submit with invalid nutrient amount stores validation error" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked
                    (loadedWithForm
                        { base
                            | name = "Paneer"
                            , nutrients =
                                [ { code = "PROTEIN_G"
                                  , amountPer100g = "-1"
                                  , unit = "g"
                                  }
                                ]
                        }
                    )
                    |> first
                    |> submitStateOf
                    |> Expect.equal
                        (Just
                            (Form.SubmitFailed
                                "Nutrient amount must be a non-negative number (got: -1)"
                            )
                        )
        , test "submit with invalid serving quantity stores validation error" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked
                    (loadedWithForm
                        { base
                            | name = "Paneer"
                            , servings =
                                [ { label = "cube"
                                  , quantity = "0"
                                  , unit = "piece"
                                  , grams = "50"
                                  }
                                ]
                        }
                    )
                    |> first
                    |> submitStateOf
                    |> Expect.equal
                        (Just
                            (Form.SubmitFailed
                                "Serving quantity must be a positive number (got: 0)"
                            )
                        )
        , test "submit with invalid serving grams stores validation error" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                CustomFoodEdit.update CustomFoodEdit.SubmitClicked
                    (loadedWithForm
                        { base
                            | name = "Paneer"
                            , servings =
                                [ { label = "cube"
                                  , quantity = "1"
                                  , unit = "piece"
                                  , grams = "0"
                                  }
                                ]
                        }
                    )
                    |> first
                    |> submitStateOf
                    |> Expect.equal
                        (Just
                            (Form.SubmitFailed
                                "Serving grams must be a positive number (got: 0)"
                            )
                        )
        , test "submit in loading state is ignored" <|
            \_ ->
                CustomFoodEdit.update
                    CustomFoodEdit.SubmitClicked
                    (Tuple.first (CustomFoodEdit.init "food-1"))
                    |> third
                    |> Expect.equal CustomFoodEdit.NoOp
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
        , test "save completion in loading state is ignored" <|
            \_ ->
                CustomFoodEdit.update
                    (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" }))
                    (Tuple.first (CustomFoodEdit.init "food-1"))
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


loadedName : CustomFoodEdit.Model -> Maybe String
loadedName model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            Just loaded.form.name

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


isLoading : CustomFoodEdit.Model -> Bool
isLoading model =
    case model of
        CustomFoodEdit.Loading _ ->
            True

        _ ->
            False


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
                , token = 0
                }
            , nutrients = [ { code = "PROTEIN_G", amountPer100g = "18", unit = "g" } ]
            , servings = [ { label = "cube", quantity = "2", unit = "piece", grams = "50" } ]
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
    , servingSizeG = Nothing
    , defaultQuantity = Nothing
    , defaultUnit = Just "g"
    , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
    , servings = [ { label = "cube", quantity = 2, unit = "piece", grams = 50 } ]
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
    , servingSizeG = Just "245"
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
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
