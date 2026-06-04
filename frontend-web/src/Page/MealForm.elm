module Page.MealForm exposing
    ( ComponentPatch(..)
    , ComponentRow
    , Model
    , Msg(..)
    , OutMsg(..)
    , RowId
    , ValidationError(..)
    , emptyComponentRow
    , initCreate
    , initEdit
    , selectedComponents
    , toMealRequest
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CategorySuggestion
        , CategorySuggestionRequest
        , ProductDetail
        , SearchResponse
        , SearchResult
        )
import Api.Meals
    exposing
        ( CreateMealComponentRequest
        , CreateMealRequest
        , Meal
        , MealNutritionResponse
        )
import Data.Nutrition exposing (NutrientAmount)
import Data.Search as Search exposing (Completion)
import Data.Text as Text
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Route exposing (Route(..))
import Ui
import View.Nutrients
import View.Search as SearchView


type alias RowId =
    Int


type alias ComponentRow =
    { rowId : RowId
    , productId : String
    , productName : String
    , quantity : String
    , unit : String
    , searchQuery : String
    , searchResults : List SearchResult
    , searching : Bool
    , searchToken : Int
    , categoryToken : Int
    , categorySuggestions : List CategorySuggestion
    }


type alias CategorySuggestionResult =
    Result Client.ApiError Foods.CategorySuggestionResponse


type alias ProductAndCategoryRequests =
    { rowId : RowId
    , searchToken : Int
    , searchRequest : Foods.SearchRequest
    , categoryToken : Int
    , categoryRequest : CategorySuggestionRequest
    }


type alias Model =
    { mealId : Maybe String
    , name : String
    , notes : String
    , totalQuantity : String
    , totalUnit : String
    , components : List ComponentRow
    , nextRowId : RowId
    , nextSearchToken : Int
    , fetching : Bool
    , submitting : Bool
    , nutrients : Maybe (List NutrientAmount)
    , nutritionLoading : Bool
    , nutritionError : Maybe String
    , error : Maybe String
    }


type ValidationError
    = MealNameRequired
    | ComponentRequired


type ComponentPatch
    = SetProduct String String
    | SetQuantity String
    | SetUnit String
    | SetSearchQuery String
    | SetSearchStarted Int
    | SetSearchResults Int (List SearchResult)
    | SetSearching Bool
    | SetCategorySuggestionsStarted Int
    | SetCategorySuggestions Int (List CategorySuggestion)
    | ClearCategorySuggestions


type Msg
    = MealLoaded (Result Client.ApiError Meal)
    | ProductNameLoaded String (Result Client.ApiError ProductDetail)
    | NutrientPreviewLoaded (Result Client.ApiError MealNutritionResponse)
    | NameChanged String
    | NotesChanged String
    | TotalQuantityChanged String
    | TotalUnitChanged String
    | ComponentSearchChanged RowId String
    | ComponentSearchCompleted RowId Int (Result Client.ApiError SearchResponse)
    | ComponentCategoriesCompleted RowId Int CategorySuggestionResult
    | CompleteFirstComponentSuggestion RowId
    | ComponentCompletionClicked RowId Completion
    | SelectProduct RowId SearchResult
    | ComponentQuantityChanged RowId String
    | ComponentUnitChanged RowId String
    | AddComponentClicked
    | RemoveComponentClicked RowId
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)


type OutMsg
    = NoOp
    | RequestMeal String
    | RequestProductName String
    | RequestProductSearch RowId Int Foods.SearchRequest
    | RequestCategorySuggestions RowId Int CategorySuggestionRequest
    | RequestProductAndCats ProductAndCategoryRequests
    | RequestCreateMeal CreateMealRequest
    | RequestUpdateMeal String CreateMealRequest
    | Navigate Route
    | SessionExpired


initCreate : ( Model, OutMsg )
initCreate =
    ( { mealId = Nothing
      , name = ""
      , notes = ""
      , totalQuantity = ""
      , totalUnit = "g"
      , components = [ emptyComponentRow 1 ]
      , nextRowId = 2
      , nextSearchToken = 1
      , fetching = False
      , submitting = False
      , nutrients = Nothing
      , nutritionLoading = False
      , nutritionError = Nothing
      , error = Nothing
      }
    , NoOp
    )


initEdit : String -> ( Model, OutMsg )
initEdit mealId =
    let
        ( model, _ ) =
            initCreate
    in
    ( { model | mealId = Just mealId, fetching = True, nutritionLoading = True }
    , RequestMeal mealId
    )


emptyComponentRow : RowId -> ComponentRow
emptyComponentRow rowId =
    { rowId = rowId
    , productId = ""
    , productName = ""
    , quantity = "100"
    , unit = "g"
    , searchQuery = ""
    , searchResults = []
    , searching = False
    , searchToken = 0
    , categoryToken = 0
    , categorySuggestions = []
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded result ->
            case result of
                Ok meal ->
                    let
                        rows : List ComponentRow
                        rows =
                            List.indexedMap
                                (\index component ->
                                    let
                                        row : ComponentRow
                                        row =
                                            emptyComponentRow (index + 1)
                                    in
                                    { row
                                        | productId = component.item.id
                                        , quantity = component.quantity.amount
                                        , unit = component.quantity.unit
                                    }
                                )
                                meal.components

                        loadedRows : List ComponentRow
                        loadedRows =
                            if List.isEmpty rows then
                                [ emptyComponentRow 1 ]

                            else
                                rows
                    in
                    ( { model
                        | name = meal.name
                        , notes = Maybe.withDefault "" meal.notes
                        , totalQuantity =
                            Maybe.map .amount meal.totalQuantity
                                |> Maybe.withDefault ""
                        , totalUnit = Maybe.map .unit meal.totalQuantity |> Maybe.withDefault "g"
                        , components = loadedRows
                        , nextRowId = List.length loadedRows + 1
                        , fetching = False
                        , error = Nothing
                      }
                    , Cmd.none
                    , requestNextProductName loadedRows
                    )

                Err error ->
                    failure error { model | fetching = False }

        ProductNameLoaded productId result ->
            case result of
                Ok product ->
                    ( { model
                        | components =
                            List.map
                                (mergeProductName productId product.name)
                                model.components
                      }
                    , Cmd.none
                    , requestNextMissingProductName productId model.components
                    )

                Err _ ->
                    ( model, Cmd.none, requestNextMissingProductName productId model.components )

        NutrientPreviewLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | nutrients = Just response.nutrients
                        , nutritionLoading = False
                        , nutritionError = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | nutrients = Nothing
                            , nutritionLoading = False
                            , nutritionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | nutrients = Nothing
                            , nutritionLoading = False
                            , nutritionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        NameChanged value ->
            ( { model | name = value }, Cmd.none, NoOp )

        NotesChanged value ->
            ( { model | notes = value }, Cmd.none, NoOp )

        TotalQuantityChanged value ->
            ( { model | totalQuantity = value }, Cmd.none, NoOp )

        TotalUnitChanged value ->
            ( { model | totalUnit = value }, Cmd.none, NoOp )

        ComponentSearchChanged rowId query ->
            let
                token : Int
                token =
                    model.nextSearchToken

                categoryToken : Int
                categoryToken =
                    token + 1

                nextModel : Model
                nextModel =
                    model
                        |> updateComponent rowId (SetSearchQuery query)
                        |> updateComponent rowId (SetSearchStarted token)
                        |> updateComponent rowId
                            (case Search.categoryQuery query of
                                Just _ ->
                                    SetCategorySuggestionsStarted categoryToken

                                Nothing ->
                                    ClearCategorySuggestions
                            )

                searchRequest : Maybe Foods.SearchRequest
                searchRequest =
                    if String.length (String.trim query) < 2 then
                        Nothing

                    else
                        Just { query = query }

                categoryRequest : Maybe CategorySuggestionRequest
                categoryRequest =
                    Search.categoryQuery query
                        |> Maybe.map
                            (\value ->
                                { query = value, limit = 8 }
                            )
            in
            case ( searchRequest, categoryRequest ) of
                ( Just productRequest, Just categorySuggestionRequest ) ->
                    ( { nextModel | nextSearchToken = token + 2 }
                    , Cmd.none
                    , RequestProductAndCats
                        { rowId = rowId
                        , searchToken = token
                        , searchRequest = productRequest
                        , categoryToken = categoryToken
                        , categoryRequest = categorySuggestionRequest
                        }
                    )

                ( Just productRequest, Nothing ) ->
                    ( { nextModel | nextSearchToken = token + 1 }
                    , Cmd.none
                    , RequestProductSearch rowId token productRequest
                    )

                ( Nothing, Just categorySuggestionRequest ) ->
                    ( { nextModel
                        | nextSearchToken = token + 2
                      }
                        |> updateComponent rowId (SetSearchResults token [])
                    , Cmd.none
                    , RequestCategorySuggestions rowId categoryToken categorySuggestionRequest
                    )

                _ ->
                    ( nextModel |> updateComponent rowId (SetSearchResults token [])
                    , Cmd.none
                    , NoOp
                    )

        ComponentSearchCompleted rowId token result ->
            case result of
                Ok response ->
                    ( updateComponent rowId (SetSearchResults token response.items) model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( updateComponent rowId (SetSearching False) model
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( updateComponent rowId (SetSearching False) model, Cmd.none, NoOp )

        ComponentCategoriesCompleted rowId token result ->
            case result of
                Ok response ->
                    ( updateComponent rowId (SetCategorySuggestions token response.items) model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( updateComponent rowId ClearCategorySuggestions model
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( updateComponent rowId ClearCategorySuggestions model
                        , Cmd.none
                        , NoOp
                        )

        CompleteFirstComponentSuggestion rowId ->
            case findRow rowId model.components of
                Just row ->
                    case List.head (Search.completions row.searchQuery row.categorySuggestions) of
                        Just completion ->
                            update
                                (ComponentSearchChanged
                                    rowId
                                    (Search.applyCompletion completion row.searchQuery)
                                )
                                model

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        ComponentCompletionClicked rowId completion ->
            case findRow rowId model.components of
                Just row ->
                    update
                        (ComponentSearchChanged
                            rowId
                            (Search.applyCompletion completion row.searchQuery)
                        )
                        model

                Nothing ->
                    ( model, Cmd.none, NoOp )

        SelectProduct rowId result ->
            ( updateComponent rowId (SetProduct result.id result.name) model, Cmd.none, NoOp )

        ComponentQuantityChanged rowId value ->
            ( updateComponent rowId (SetQuantity value) model, Cmd.none, NoOp )

        ComponentUnitChanged rowId value ->
            ( updateComponent rowId (SetUnit value) model, Cmd.none, NoOp )

        AddComponentClicked ->
            ( { model
                | components = model.components ++ [ emptyComponentRow model.nextRowId ]
                , nextRowId = model.nextRowId + 1
              }
            , Cmd.none
            , NoOp
            )

        RemoveComponentClicked rowId ->
            ( { model | components = removeRow rowId model.components }, Cmd.none, NoOp )

        SubmitClicked ->
            case toMealRequest model of
                Ok request ->
                    case model.mealId of
                        Just mealId ->
                            ( { model | submitting = True, error = Nothing }
                            , Cmd.none
                            , RequestUpdateMeal mealId request
                            )

                        Nothing ->
                            ( { model | submitting = True, error = Nothing }
                            , Cmd.none
                            , RequestCreateMeal request
                            )

                Err MealNameRequired ->
                    ( { model | error = Just "Name is required", submitting = False }
                    , Cmd.none
                    , NoOp
                    )

                Err ComponentRequired ->
                    ( { model
                        | error = Just "At least one component with a selected product is required"
                        , submitting = False
                      }
                    , Cmd.none
                    , NoOp
                    )

        SaveCompleted result ->
            case result of
                Ok meal ->
                    ( { model | submitting = False }, Cmd.none, Navigate (MealDetail meal.id) )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | submitting = False
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | submitting = False
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )


requestNextProductName : List ComponentRow -> OutMsg
requestNextProductName rows =
    rows
        |> List.filter
            (\row ->
                not (String.isEmpty row.productId)
                    && String.isEmpty row.productName
            )
        |> List.head
        |> Maybe.map (.productId >> RequestProductName)
        |> Maybe.withDefault NoOp


requestNextMissingProductName : String -> List ComponentRow -> OutMsg
requestNextMissingProductName completedProductId rows =
    rows
        |> List.filter
            (\row ->
                row.productId
                    /= completedProductId
                    && not (String.isEmpty row.productId)
                    && String.isEmpty row.productName
            )
        |> List.head
        |> Maybe.map (.productId >> RequestProductName)
        |> Maybe.withDefault NoOp


mergeProductName : String -> String -> ComponentRow -> ComponentRow
mergeProductName productId name row =
    if row.productId == productId then
        { row | productName = name, searchQuery = name }

    else
        row


toMealRequest : Model -> Result ValidationError CreateMealRequest
toMealRequest model =
    let
        trimmedName : String
        trimmedName =
            String.trim model.name
    in
    if String.isEmpty trimmedName then
        Err MealNameRequired

    else
        case selectedComponents model.components of
            [] ->
                Err ComponentRequired

            components ->
                Ok
                    { name = trimmedName
                    , notes = Text.blankToMaybe model.notes
                    , totalQuantity =
                        Text.blankToMaybe model.totalQuantity
                            |> Maybe.map
                                (\amount ->
                                    { amount = amount
                                    , unit = Text.trimOrDefault "g" model.totalUnit
                                    }
                                )
                    , components = components
                    }


selectedComponents : List ComponentRow -> List CreateMealComponentRequest
selectedComponents rows =
    rows
        |> List.filter (\row -> not (String.isEmpty (String.trim row.productId)))
        |> List.map
            (\row ->
                { item = { itemType = "product", id = String.trim row.productId }
                , quantity =
                    { amount = Text.trimOrDefault "100" row.quantity
                    , unit = Text.trimOrDefault "g" row.unit
                    }
                }
            )


updateComponent : RowId -> ComponentPatch -> Model -> Model
updateComponent rowId patch model =
    { model | components = List.map (patchRow rowId patch) model.components }


patchRow : RowId -> ComponentPatch -> ComponentRow -> ComponentRow
patchRow rowId patch row =
    if row.rowId /= rowId then
        row

    else
        case patch of
            SetProduct id name ->
                { row
                    | productId = id
                    , productName = name
                    , searchQuery = name
                    , searchResults = []
                    , searching = False
                    , categorySuggestions = []
                }

            SetQuantity value ->
                { row | quantity = value }

            SetUnit value ->
                { row | unit = value }

            SetSearchQuery value ->
                { row | searchQuery = value }

            SetSearchStarted token ->
                { row | searchToken = token, searching = True }

            SetSearchResults token results ->
                if row.searchToken == token then
                    { row | searchResults = results, searching = False }

                else
                    row

            SetSearching value ->
                { row | searching = value }

            SetCategorySuggestionsStarted token ->
                { row | categoryToken = token }

            SetCategorySuggestions token suggestions ->
                if row.categoryToken == token then
                    { row | categorySuggestions = suggestions }

                else
                    row

            ClearCategorySuggestions ->
                { row | categorySuggestions = [] }


findRow : RowId -> List ComponentRow -> Maybe ComponentRow
findRow rowId rows =
    rows
        |> List.filter (\row -> row.rowId == rowId)
        |> List.head


removeRow : RowId -> List ComponentRow -> List ComponentRow
removeRow rowId rows =
    if List.length rows <= 1 then
        rows

    else
        List.filter (\row -> row.rowId /= rowId) rows


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , if model.fetching then
            Ui.loading "Loading meal..."

          else
            formView model
        ]


formView : Model -> Element Msg
formView model =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.input "Name" model.name NameChanged
        , Ui.input "Notes" model.notes NotesChanged
        , Element.row [ Element.spacing 8 ]
            [ Ui.input "Total Quantity" model.totalQuantity TotalQuantityChanged
            , Ui.input "Total Unit" model.totalUnit TotalUnitChanged
            ]
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 10 ]
            (List.map componentRowView model.components)
        , Ui.button "+ Add Component" AddComponentClicked
        , nutritionView model
        , Ui.submitButton model.submitting
            (if model.mealId == Nothing then
                "Create Meal"

             else
                "Update Meal"
            )
            "Saving..."
            SubmitClicked
        ]


componentRowView : ComponentRow -> Element Msg
componentRowView row =
    Ui.card
        [ componentSearchInput row
        , if row.searching then
            Ui.loading "Searching foods..."

          else if List.isEmpty row.searchResults then
            Element.none

          else
            Element.column
                [ Element.width Element.fill
                , Element.spacing 0
                ]
                (List.map (searchResultView row.searchQuery row.rowId) row.searchResults)
        , Element.row [ Element.spacing 8 ]
            [ Ui.input "Qty" row.quantity (ComponentQuantityChanged row.rowId)
            , Ui.input "Unit" row.unit (ComponentUnitChanged row.rowId)
            , Ui.button "Remove" (RemoveComponentClicked row.rowId)
            ]
        ]


componentSearchInput : ComponentRow -> Element Msg
componentSearchInput row =
    let
        options : List Completion
        options =
            Search.completions row.searchQuery row.categorySuggestions
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Input.text
            [ Border.rounded 6
            , Border.width 1
            , Border.color (Element.rgb255 209 213 219)
            , Element.padding 10
            , Element.htmlAttribute
                (SearchView.tabCompletionHandler
                    (CompleteFirstComponentSuggestion row.rowId)
                    options
                )
            ]
            { onChange = ComponentSearchChanged row.rowId
            , text = row.searchQuery
            , placeholder = Nothing
            , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Search Product")
            }
        , SearchView.completionDropdown
            { onSelect = ComponentCompletionClicked row.rowId }
            options
        ]


searchResultView : String -> RowId -> SearchResult -> Element Msg
searchResultView query rowId result =
    SearchView.resultRow
        { query = query
        , item = result
        , onSelect = \_ -> SelectProduct rowId result
        }


nutritionView : Model -> Element Msg
nutritionView model =
    case model.mealId of
        Just _ ->
            Element.column [ Element.width Element.fill, Element.spacing 10 ]
                [ Ui.sectionHeader "Nutrition"
                , if model.nutritionLoading then
                    Ui.loading "Loading nutrition..."

                  else
                    Element.none
                , case model.nutritionError of
                    Just message ->
                        Ui.errorBanner message

                    Nothing ->
                        Element.none
                , case model.nutrients of
                    Just nutrients ->
                        Element.column [ Element.width Element.fill, Element.spacing 8 ]
                            [ View.Nutrients.nutrientsTable nutrients
                            , Ui.card
                                [ Ui.sectionHeader "Macro Breakdown"
                                , View.Nutrients.macroBreakdownView nutrients
                                ]
                            ]

                    Nothing ->
                        Element.none
                ]

        Nothing ->
            Element.none
