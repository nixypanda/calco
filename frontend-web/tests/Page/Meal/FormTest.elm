module Page.Meal.FormTest exposing (tests)

import Api.Client as Client
import Api.Foods
    exposing
        ( ProductDetail
        , SearchResponse
        , SearchResult
        , SearchScope(..)
        )
import Api.Meals as Meals
import Data.Nutrition as Nutrition
import Data.Search as Search
import Expect
import Lib.Loadable exposing (Loadable(..))
import Page.Meal.Form as Form
    exposing
        ( FormFieldMsg(..)
        , FormFieldOutMsg(..)
        , FormFields
        , ValidationError(..)
        )
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Form"
        [ describe "ProductNameLoaded"
            [ test "Ok stores product name and merges into matching rows" <|
                \_ ->
                    let
                        formWithProduct : FormFields
                        formWithProduct =
                            setRowProductId 1 "p1" emptyForm

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ProductNameLoaded "p1" (Ok productDetail))
                                formWithProduct
                    in
                    form.components
                        |> List.head
                        |> Maybe.map .productName
                        |> Expect.equal (Just "Milk")
            , test "Err falls back to Unknown food" <|
                \_ ->
                    let
                        formWithProduct : FormFields
                        formWithProduct =
                            setRowProductId 1 "p1" emptyForm

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ProductNameLoaded "p1" (Err Client.NetworkError))
                                formWithProduct
                    in
                    form.components
                        |> List.head
                        |> Maybe.map .productName
                        |> Expect.equal (Just "Unknown food")
            , test "Ok with no other missing products returns no outmsg" <|
                \_ ->
                    let
                        formWithProduct : FormFields
                        formWithProduct =
                            setRowProductId 1 "p1" emptyForm

                        ( _, _, outMsg ) =
                            Form.updateFormField
                                (ProductNameLoaded "p1" (Ok productDetail))
                                formWithProduct
                    in
                    outMsg
                        |> Expect.equal Nothing
            , test "Ok with another missing product requests next name" <|
                \_ ->
                    let
                        formWithProducts : FormFields
                        formWithProducts =
                            emptyForm
                                |> setRowProductId 1 "p1"
                                |> addRowWithId 2
                                |> setRowProductId 2 "p2"

                        ( _, _, outMsg ) =
                            Form.updateFormField
                                (ProductNameLoaded "p1" (Ok productDetail))
                                formWithProducts
                    in
                    case outMsg of
                        Just (RequestProductName "p2") ->
                            Expect.pass

                        _ ->
                            Expect.fail "expected RequestProductName for p2"
            ]
        , describe "ComponentSearchChanged"
            [ test "query >= 2 chars emits RequestProductSearch" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Form.updateFormField
                                (ComponentSearchChanged 1 "milk")
                                emptyForm
                    in
                    case outMsg of
                        Just (RequestProductSearch rowId _ req) ->
                            Expect.all
                                [ \_ -> rowId |> Expect.equal 1
                                , \_ -> req.query |> Expect.equal "milk"
                                , \_ -> req.scope |> Expect.equal SearchAll
                                ]
                                ()

                        Just (RequestProductAndCats _) ->
                            Expect.pass

                        _ ->
                            Expect.fail "expected search out-msg"
            , test "short query clears results and returns no outmsg" <|
                \_ ->
                    let
                        ( form, _, outMsg ) =
                            Form.updateFormField
                                (ComponentSearchChanged 1 "m")
                                emptyForm
                    in
                    Expect.all
                        [ \_ -> outMsg |> Expect.equal Nothing
                        , \_ ->
                            form.components
                                |> List.head
                                |> Maybe.map .searchResults
                                |> Expect.equal (Just (Success []))
                        ]
                        ()
            ]
        , describe "ComponentSearchCompleted"
            [ test "Ok stores results at matching token" <|
                \_ ->
                    let
                        formAfterSearch : FormFields
                        formAfterSearch =
                            emptyForm
                                |> updateComponentSearchToken 1 5

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentSearchCompleted 1 5 (Ok searchResponse))
                                formAfterSearch
                    in
                    form.components
                        |> List.head
                        |> Maybe.map .searchResults
                        |> Expect.equal (Just (Success [ searchResult ]))
            , test "Ok with stale token is ignored" <|
                \_ ->
                    let
                        formAfterSearch : FormFields
                        formAfterSearch =
                            emptyForm
                                |> updateComponentSearchToken 1 3

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentSearchCompleted 1 5 (Ok searchResponse))
                                formAfterSearch
                    in
                    form.components
                        |> List.head
                        |> Maybe.map .searchResults
                        |> Expect.equal (Just NotAsked)
            , test "Err NetworkError sets search failed" <|
                \_ ->
                    let
                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentSearchCompleted 1 1 (Err Client.NetworkError))
                                emptyForm
                    in
                    form.components
                        |> List.head
                        |> Maybe.map .searchResults
                        |> Expect.equal (Just (Failure ()))
            , test "Err 401 returns FormSessionExpired" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Form.updateFormField
                                (ComponentSearchCompleted 1 1 (Err (Client.BadStatus 401 "" "")))
                                emptyForm
                    in
                    outMsg
                        |> Expect.equal (Just FormSessionExpired)
            ]
        , describe "ComponentCategoriesCompleted"
            [ test "Ok stores category suggestions" <|
                \_ ->
                    let
                        formWithToken : FormFields
                        formWithToken =
                            emptyForm
                                |> updateComponentCategoryToken 1 3

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentCategoriesCompleted 1
                                    3
                                    (Ok { items = [ { value = "dairy", count = 5 } ] })
                                )
                                formWithToken
                    in
                    form.components
                        |> List.head
                        |> Maybe.map (.search >> .categorySuggestions)
                        |> Expect.equal (Just [ { value = "dairy", count = 5 } ])
            , test "Ok with stale token is ignored" <|
                \_ ->
                    let
                        formWithToken : FormFields
                        formWithToken =
                            emptyForm
                                |> updateComponentCategoryToken 1 1

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentCategoriesCompleted 1
                                    3
                                    (Ok { items = [ { value = "dairy", count = 5 } ] })
                                )
                                formWithToken
                    in
                    form.components
                        |> List.head
                        |> Maybe.map (.search >> .categorySuggestions)
                        |> Expect.equal (Just [])
            , test "Err clears category suggestions" <|
                \_ ->
                    let
                        formWithSuggestions : FormFields
                        formWithSuggestions =
                            emptyForm
                                |> updateComponentCategoryToken 1 1

                        ( form, _, _ ) =
                            Form.updateFormField
                                (ComponentCategoriesCompleted 1
                                    1
                                    (Err Client.NetworkError)
                                )
                                formWithSuggestions
                    in
                    form.components
                        |> List.head
                        |> Maybe.map (.search >> .categorySuggestions)
                        |> Expect.equal (Just [])
            , test "Err 401 returns FormSessionExpired" <|
                \_ ->
                    let
                        ( _, _, outMsg ) =
                            Form.updateFormField
                                (ComponentCategoriesCompleted 1
                                    1
                                    (Err (Client.BadStatus 401 "" ""))
                                )
                                emptyForm
                    in
                    outMsg
                        |> Expect.equal (Just FormSessionExpired)
            ]
        , describe "CompleteFirstComponentSuggestion"
            [ test "applies first completion when available" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            emptyForm
                                |> updateComponentQuery 1 "category:da"
                                |> updateComponentSearchToken 1 0
                                |> updateComponentCategoryToken 1 0
                                |> updateComponentCategorySuggestions 1
                                    [ { value = "dairy", count = 5 } ]

                        ( form, _, _ ) =
                            Form.updateFormField (CompleteFirstComponentSuggestion 1) base
                    in
                    form.components
                        |> List.head
                        |> Maybe.map (.search >> .query)
                        |> Expect.equal (Just "category:dairy")
            , test "no completion available returns form unchanged" <|
                \_ ->
                    let
                        ( form, _, outMsg ) =
                            Form.updateFormField (CompleteFirstComponentSuggestion 1) emptyForm
                    in
                    Expect.all
                        [ \_ -> form.components |> List.length |> Expect.equal 1
                        , \_ -> outMsg |> Expect.equal Nothing
                        ]
                        ()
            ]
        , describe "ComponentCompletionClicked"
            [ test "applies clicked completion via search change" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            emptyForm
                                |> updateComponentSearchToken 1 0
                                |> updateComponentCategoryToken 1 0

                        completion : Search.Completion
                        completion =
                            Search.CategoryCompletion "category:dairy" 5

                        ( form, _, _ ) =
                            Form.updateFormField (ComponentCompletionClicked 1 completion) base
                    in
                    form.components
                        |> List.head
                        |> Maybe.map (.search >> .query)
                        |> Expect.equal (Just "category:dairy")
            ]
        , describe "AddComponentClicked"
            [ test "appends a new row" <|
                \_ ->
                    let
                        ( form, _, _ ) =
                            Form.updateFormField AddComponentClicked emptyForm
                    in
                    form.components
                        |> List.length
                        |> Expect.equal 2
            ]
        , describe "RemoveComponentClicked"
            [ test "removes the specified row" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            emptyForm
                                |> addRowWithId 2
                                |> addRowWithId 3

                        ( form, _, _ ) =
                            Form.updateFormField (RemoveComponentClicked 2) base
                    in
                    form.components
                        |> List.map .rowId
                        |> Expect.equal [ 1, 3 ]
            , test "keeps at least one row" <|
                \_ ->
                    let
                        ( form, _, _ ) =
                            Form.updateFormField (RemoveComponentClicked 1) emptyForm
                    in
                    form.components
                        |> List.length
                        |> Expect.equal 1
            ]
        , describe "toMealRequest"
            [ test "empty name returns MealNameRequired" <|
                \_ ->
                    Form.toMealRequest emptyForm
                        |> Expect.equal (Err MealNameRequired)
            , test "whitespace-only name returns MealNameRequired" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm | name = "   " }
                    in
                    Form.toMealRequest base
                        |> Expect.equal (Err MealNameRequired)
            , test "no selected components returns ComponentRequired" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm | name = "My Meal" }
                    in
                    Form.toMealRequest base
                        |> Expect.equal (Err ComponentRequired)
            , test "valid form returns Ok request" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm
                                | name = "My Meal"
                                , notes = "notes"
                                , totalQuantity = "500"
                                , totalUnit = "ml"
                            }
                                |> setRowProductId 1 "p1"

                        result : Result ValidationError Meals.CreateMealRequest
                        result =
                            Form.toMealRequest base
                    in
                    case result of
                        Ok req ->
                            Expect.all
                                [ \_ -> req.name |> Expect.equal "My Meal"
                                , \_ -> req.notes |> Expect.equal (Just "notes")
                                , \_ ->
                                    req.totalQuantity
                                        |> Expect.equal
                                            (Just { amount = "500", unit = "ml" })
                                , \_ -> req.components |> List.length |> Expect.equal 1
                                ]
                                ()

                        Err _ ->
                            Expect.fail "expected Ok"
            , test "blank totalQuantity omits totalQuantity" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm | name = "Meal" }
                                |> setRowProductId 1 "p1"
                    in
                    Form.toMealRequest base
                        |> Result.map .totalQuantity
                        |> Expect.equal (Ok Nothing)
            , test "name is trimmed in request" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm | name = "  Meal  " }
                                |> setRowProductId 1 "p1"
                    in
                    Form.toMealRequest base
                        |> Result.map .name
                        |> Expect.equal (Ok "Meal")
            ]
        ]


emptyForm : FormFields
emptyForm =
    Form.emptyFormFields


setRowProductId : Form.RowId -> String -> FormFields -> FormFields
setRowProductId rowId productId form =
    Form.updateFormField (SelectProduct rowId (searchResultForId productId)) form
        |> first


addRowWithId : Form.RowId -> FormFields -> FormFields
addRowWithId rowId form =
    { form | components = form.components ++ [ Form.emptyComponentRow rowId ] }


updateSearchOnRow :
    Form.RowId
    ->
        ({ query : String
         , searchToken : Int
         , categoryToken : Int
         , categorySuggestions : List Search.CategorySuggestion
         }
         ->
            { query : String
            , searchToken : Int
            , categoryToken : Int
            , categorySuggestions : List Search.CategorySuggestion
            }
        )
    -> FormFields
    -> FormFields
updateSearchOnRow rowId fn form =
    { form
        | components =
            List.map
                (\row ->
                    if row.rowId == rowId then
                        { row | search = fn row.search }

                    else
                        row
                )
                form.components
    }


updateComponentSearchToken : Form.RowId -> Int -> FormFields -> FormFields
updateComponentSearchToken rowId token form =
    updateSearchOnRow rowId
        (\s -> { s | searchToken = token })
        form


updateComponentCategoryToken : Form.RowId -> Int -> FormFields -> FormFields
updateComponentCategoryToken rowId token form =
    updateSearchOnRow rowId
        (\s -> { s | categoryToken = token })
        form


updateComponentCategorySuggestions :
    Form.RowId
    -> List Search.CategorySuggestion
    -> FormFields
    -> FormFields
updateComponentCategorySuggestions rowId suggestions form =
    updateSearchOnRow rowId
        (\s -> { s | categorySuggestions = suggestions })
        form


updateComponentQuery : Form.RowId -> String -> FormFields -> FormFields
updateComponentQuery rowId query form =
    updateSearchOnRow rowId
        (\s -> { s | query = query })
        form


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


productDetail : ProductDetail
productDetail =
    { id = "food-1"
    , source = "OPEN_FOOD_FACTS"
    , sourceId = Nothing
    , visibility = "public"
    , barcode = Nothing
    , name = "Milk"
    , brand = Nothing
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , servingSizeG = Nothing
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
        , perServing = Nothing
        }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


searchResult : SearchResult
searchResult =
    { id = "food-1"
    , source = "OPEN_FOOD_FACTS"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Milk"
    , brand = Nothing
    , categories = [ "dairy" ]
    , servingSizeG = Nothing
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
        , perServing = Nothing
        }
    }


searchResponse : SearchResponse
searchResponse =
    { items = [ searchResult ] }


searchResultForId : String -> SearchResult
searchResultForId productId =
    { id = productId
    , source = "OPEN_FOOD_FACTS"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Product " ++ productId
    , brand = Nothing
    , categories = []
    , servingSizeG = Nothing
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
        , perServing = Nothing
        }
    }
