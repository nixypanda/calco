module Component.Meal.FormTest exposing (tests)

import Api.Client as Client
import Api.Foods
    exposing
        ( ProductDetail
        , SearchResponse
        , SearchResult
        , SearchScope(..)
        )
import Component.Meal.Form as Form
    exposing
        ( FormFieldMsg(..)
        , FormFieldOutMsg(..)
        , FormFields
        , ValidationError(..)
        )
import Data.Nutrition as Nutrition
import Expect
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket as Ticket exposing (Ticket)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Component.Meal.Form"
        [ describe "product names"
            [ test "names load, fall back when missing, and request the next product" <|
                \_ ->
                    let
                        formWithProducts : FormFields
                        formWithProducts =
                            emptyForm
                                |> setRowProductId 1 "p1"
                                |> addRowWithId 2
                                |> setRowProductId 2 "p2"

                        loaded : FormFields
                        loaded =
                            first
                                (Form.updateFormField
                                    (ProductNameLoaded "p1" (Ok productDetail))
                                    formWithProducts
                                )

                        fallback : FormFields
                        fallback =
                            first
                                (Form.updateFormField
                                    (ProductNameLoaded "p1" (Err Client.NetworkError))
                                    formWithProducts
                                )

                        nextRequest : Maybe FormFieldOutMsg
                        nextRequest =
                            third
                                (Form.updateFormField
                                    (ProductNameLoaded "p1" (Ok productDetail))
                                    formWithProducts
                                )
                    in
                    ( loaded.components |> List.map (.search >> .query)
                    , nextRequest
                    , fallback.components |> List.head |> Maybe.map (.search >> .query)
                    )
                        |> Expect.equal
                            ( [ "Milk", "Product p2" ]
                            , Just (RequestProductName "p2")
                            , Just "Unknown food"
                            )
            ]
        , describe "component search"
            [ test "a completion stores results only for its own token" <|
                \_ ->
                    let
                        ( searching, _, outMsg ) =
                            Form.updateFormField (ComponentSearchChanged 1 "milk") emptyForm

                        token : Ticket
                        token =
                            case outMsg of
                                Just (RequestProductSearch _ searchToken _) ->
                                    searchToken

                                _ ->
                                    Ticket.initial

                        requestSummary : Maybe ( Form.RowId, String, SearchScope )
                        requestSummary =
                            case outMsg of
                                Just (RequestProductSearch rowId _ request) ->
                                    Just ( rowId, request.query, request.scope )

                                _ ->
                                    Nothing

                        loaded : FormFields
                        loaded =
                            first
                                (Form.updateFormField
                                    (ComponentSearchCompleted 1 token (Ok searchResponse))
                                    searching
                                )

                        stale : FormFields
                        stale =
                            first
                                (Form.updateFormField
                                    (ComponentSearchCompleted 1 (ticket 99) (Ok { items = [] }))
                                    loaded
                                )
                    in
                    ( requestSummary
                    , loaded.components |> List.head |> Maybe.map .searchResults
                    , stale.components |> List.head |> Maybe.map .searchResults
                    )
                        |> Expect.equal
                            ( Just ( 1, "milk", SearchAll )
                            , Just (Success [ searchResult ])
                            , Just (Success [ searchResult ])
                            )
            , test "a failed search shows failure and a 401 expires the session" <|
                \_ ->
                    let
                        error : Client.ApiError
                        error =
                            Client.NetworkError

                        failed : FormFields
                        failed =
                            first
                                (Form.updateFormField
                                    (ComponentSearchCompleted 1 (ticket 1) (Err error))
                                    emptyForm
                                )

                        searchAuth : Maybe FormFieldOutMsg
                        searchAuth =
                            third
                                (Form.updateFormField
                                    (ComponentSearchCompleted 1 (ticket 1) (Err unauthorized))
                                    emptyForm
                                )

                        categoryAuth : Maybe FormFieldOutMsg
                        categoryAuth =
                            third
                                (Form.updateFormField
                                    (ComponentCategoriesCompleted 1 (ticket 1) (Err unauthorized))
                                    emptyForm
                                )
                    in
                    ( failed.components |> List.head |> Maybe.map .searchResults
                    , searchAuth
                    , categoryAuth
                    )
                        |> Expect.equal
                            ( Just (Failure ())
                            , Just FormSessionExpired
                            , Just FormSessionExpired
                            )
            ]
        , describe "category suggestions"
            [ test "suggestions are stored only for their own token" <|
                \_ ->
                    let
                        ( searching, _, outMsg ) =
                            Form.updateFormField (ComponentSearchChanged 1 "category:dai") emptyForm
                    in
                    case outMsg of
                        Just (RequestProductAndCats requests) ->
                            let
                                loaded : FormFields
                                loaded =
                                    first
                                        (Form.updateFormField
                                            (ComponentCategoriesCompleted
                                                requests.rowId
                                                requests.categoryToken
                                                (Ok
                                                    { items =
                                                        [ { value = "dairy", count = 5 } ]
                                                    }
                                                )
                                            )
                                            searching
                                        )

                                stale : FormFields
                                stale =
                                    first
                                        (Form.updateFormField
                                            (ComponentCategoriesCompleted
                                                requests.rowId
                                                (ticket 99)
                                                (Ok
                                                    { items =
                                                        [ { value = "other", count = 1 } ]
                                                    }
                                                )
                                            )
                                            loaded
                                        )
                            in
                            ( loaded.components
                                |> List.head
                                |> Maybe.map (.search >> .categorySuggestions)
                            , stale.components
                                |> List.head
                                |> Maybe.map (.search >> .categorySuggestions)
                            )
                                |> Expect.equal
                                    ( Just [ { value = "dairy", count = 5 } ]
                                    , Just [ { value = "dairy", count = 5 } ]
                                    )

                        _ ->
                            Expect.fail "expected RequestProductAndCats"
            ]
        , describe "toMealRequest"
            [ test "empty name returns MealNameRequired" <|
                \_ ->
                    Form.toMealRequest emptyForm
                        |> Expect.equal (Err MealNameRequired)
            , test "no selected components returns ComponentRequired" <|
                \_ ->
                    Form.toMealRequest { emptyForm | name = "My Meal" }
                        |> Expect.equal (Err ComponentRequired)
            , test "valid form trims the name and maps the payload" <|
                \_ ->
                    let
                        base : FormFields
                        base =
                            { emptyForm
                                | name = "  My Meal  "
                                , notes = "notes"
                                , totalQuantity = "500"
                                , totalUnit = "ml"
                            }
                                |> setRowProductId 1 "p1"
                    in
                    case Form.toMealRequest base of
                        Ok request ->
                            { name = request.name
                            , notes = request.notes
                            , totalQuantity = request.totalQuantity
                            , componentCount = List.length request.components
                            }
                                |> Expect.equal
                                    { name = "My Meal"
                                    , notes = Just "notes"
                                    , totalQuantity = Just { amount = "500", unit = "ml" }
                                    , componentCount = 1
                                    }

                        Err _ ->
                            Expect.fail "expected Ok"
            , test "blank totalQuantity omits totalQuantity" <|
                \_ ->
                    Form.toMealRequest ({ emptyForm | name = "Meal" } |> setRowProductId 1 "p1")
                        |> Result.map .totalQuantity
                        |> Expect.equal (Ok Nothing)
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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


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
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
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
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
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
    , nutritionSummary =
        { per100g = Nutrition.emptySummary
        }
    }


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
