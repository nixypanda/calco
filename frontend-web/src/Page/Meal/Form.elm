module Page.Meal.Form exposing
    ( CategorySuggestionResult
    , ComponentPatch(..)
    , ComponentRow
    , FormModel
    , LoadingEditModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , ProductAndCategoryRequests
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
import Api.Result as ApiResult
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition exposing (NutrientAmount, defaultCode)
import Data.Route exposing (Route(..))
import Data.Search as Search exposing (Completion)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.Text as Text
import Ui
import View.NutritionPreview
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


type Model
    = Creating FormModel
    | LoadingEdit LoadingEditModel
    | EditLoadFailed String
    | Editing String FormModel


type alias LoadingEditModel =
    { mealId : String
    , nutrients : Maybe (List NutrientAmount)
    , nutritionLoading : Bool
    , nutritionError : Maybe String
    }


type alias FormModel =
    { name : String
    , notes : String
    , totalQuantity : String
    , totalUnit : String
    , components : List ComponentRow
    , productNames : ItemNameLookup.Names
    , nextRowId : RowId
    , nextSearchToken : Int
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
    ( Creating
        { name = ""
        , notes = ""
        , totalQuantity = ""
        , totalUnit = defaultCode
        , components = [ emptyComponentRow 1 ]
        , productNames = ItemNameLookup.empty
        , nextRowId = 2
        , nextSearchToken = 1
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
    ( LoadingEdit
        { mealId = mealId
        , nutrients = Nothing
        , nutritionLoading = True
        , nutritionError = Nothing
        }
    , RequestMeal mealId
    )


emptyComponentRow : RowId -> ComponentRow
emptyComponentRow rowId =
    { rowId = rowId
    , productId = ""
    , productName = ""
    , quantity = "100"
    , unit = defaultCode
    , searchQuery = ""
    , searchResults = []
    , searching = False
    , searchToken = 0
    , categoryToken = 0
    , categorySuggestions = []
    }


onComponentSearchChanged : RowId -> String -> FormModel -> ( FormModel, Cmd Msg, OutMsg )
onComponentSearchChanged rowId query form =
    let
        token : Int
        token =
            form.nextSearchToken

        categoryToken : Int
        categoryToken =
            token + 1

        nextModel : FormModel
        nextModel =
            form
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


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded result ->
            case result of
                Ok meal ->
                    loadMeal meal model

                Err error ->
                    failure error model

        ProductNameLoaded productId result ->
            withForm model
                (\maybeMealId form ->
                    let
                        name : String
                        name =
                            case result of
                                Ok product ->
                                    product.name

                                Err _ ->
                                    "Unknown food"

                        nextNames : ItemNameLookup.Names
                        nextNames =
                            ItemNameLookup.insertProduct productId name form.productNames

                        nextForm : FormModel
                        nextForm =
                            { form
                                | components =
                                    List.map (mergeProductName productId name) form.components
                                , productNames = nextNames
                            }
                    in
                    ( wrapForm maybeMealId nextForm
                    , Cmd.none
                    , requestNextMissingProductName (Just productId) form.components nextNames
                    )
                )

        NutrientPreviewLoaded result ->
            case result of
                Ok response ->
                    ( mapNutritionFields
                        { nutrients = Just response.nutrients
                        , nutritionLoading = False
                        , nutritionError = Nothing
                        }
                        model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                mapNutritionFields
                                    { nutrients = Nothing
                                    , nutritionLoading = False
                                    , nutritionError = Just message
                                    }
                                    current
                        }
                        error
                        model

        NameChanged value ->
            ( mapForm (\form -> { form | name = value }) model, Cmd.none, NoOp )

        NotesChanged value ->
            ( mapForm (\form -> { form | notes = value }) model, Cmd.none, NoOp )

        TotalQuantityChanged value ->
            ( mapForm (\form -> { form | totalQuantity = value }) model, Cmd.none, NoOp )

        TotalUnitChanged value ->
            ( mapForm (\form -> { form | totalUnit = value }) model, Cmd.none, NoOp )

        ComponentSearchChanged rowId query ->
            withForm model
                (\maybeMealId form ->
                    let
                        ( nextForm, cmd, outMsg ) =
                            onComponentSearchChanged rowId query form
                    in
                    ( wrapForm maybeMealId nextForm, cmd, outMsg )
                )

        ComponentSearchCompleted rowId token result ->
            case result of
                Ok response ->
                    ( mapForm
                        (updateComponent rowId (SetSearchResults token response.items))
                        model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \_ current ->
                                mapForm (updateComponent rowId (SetSearching False)) current
                        }
                        error
                        model

        ComponentCategoriesCompleted rowId token result ->
            case result of
                Ok response ->
                    ( mapForm
                        (updateComponent rowId (SetCategorySuggestions token response.items))
                        model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \_ current ->
                                mapForm (updateComponent rowId ClearCategorySuggestions) current
                        }
                        error
                        model

        CompleteFirstComponentSuggestion rowId ->
            completeComponentSuggestion rowId model

        ComponentCompletionClicked rowId completion ->
            withForm model
                (\maybeMealId form ->
                    case findRow rowId form.components of
                        Just row ->
                            let
                                ( nextForm, cmd, outMsg ) =
                                    onComponentSearchChanged rowId
                                        (Search.applyCompletion completion row.searchQuery)
                                        form
                            in
                            ( wrapForm maybeMealId nextForm, cmd, outMsg )

                        Nothing ->
                            ( model, Cmd.none, NoOp )
                )

        SelectProduct rowId result ->
            ( mapForm (updateComponent rowId (SetProduct result.id result.name)) model
            , Cmd.none
            , NoOp
            )

        ComponentQuantityChanged rowId value ->
            ( mapForm (updateComponent rowId (SetQuantity value)) model, Cmd.none, NoOp )

        ComponentUnitChanged rowId value ->
            ( mapForm (updateComponent rowId (SetUnit value)) model, Cmd.none, NoOp )

        AddComponentClicked ->
            ( mapForm
                (\form ->
                    { form
                        | components = form.components ++ [ emptyComponentRow form.nextRowId ]
                        , nextRowId = form.nextRowId + 1
                    }
                )
                model
            , Cmd.none
            , NoOp
            )

        RemoveComponentClicked rowId ->
            ( mapForm (\form -> { form | components = removeRow rowId form.components }) model
            , Cmd.none
            , NoOp
            )

        SubmitClicked ->
            submitModel model

        SaveCompleted result ->
            case result of
                Ok meal ->
                    ( mapForm (\form -> { form | submitting = False }) model
                    , Cmd.none
                    , Navigate (MealDetail meal.id)
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                mapForm
                                    (\form ->
                                        { form | submitting = False, error = Just message }
                                    )
                                    current
                        }
                        error
                        model


loadMeal : Meal -> Model -> ( Model, Cmd Msg, OutMsg )
loadMeal meal model =
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

        form : FormModel
        form =
            editFormFromMeal meal loadedRows
    in
    case model of
        LoadingEdit loading ->
            ( Editing loading.mealId
                { form
                    | nutrients = loading.nutrients
                    , nutritionLoading = loading.nutritionLoading
                    , nutritionError = loading.nutritionError
                }
            , Cmd.none
            , requestNextMissingProductName Nothing loadedRows ItemNameLookup.empty
            )

        Editing mealId _ ->
            ( Editing mealId form
            , Cmd.none
            , requestNextMissingProductName Nothing loadedRows ItemNameLookup.empty
            )

        _ ->
            ( model, Cmd.none, NoOp )


editFormFromMeal : Meal -> List ComponentRow -> FormModel
editFormFromMeal meal loadedRows =
    { name = meal.name
    , notes = Maybe.withDefault "" meal.notes
    , totalQuantity =
        Maybe.map .amount meal.totalQuantity
            |> Maybe.withDefault ""
    , totalUnit =
        Maybe.map .unit meal.totalQuantity
            |> Maybe.withDefault defaultCode
    , components = loadedRows
    , productNames = ItemNameLookup.empty
    , nextRowId = List.length loadedRows + 1
    , nextSearchToken = 1
    , submitting = False
    , nutrients = Nothing
    , nutritionLoading = True
    , nutritionError = Nothing
    , error = Nothing
    }


withForm :
    Model
    -> (Maybe String -> FormModel -> ( Model, Cmd Msg, OutMsg ))
    -> ( Model, Cmd Msg, OutMsg )
withForm model transform =
    case model of
        Creating form ->
            transform Nothing form

        Editing mealId form ->
            transform (Just mealId) form

        _ ->
            ( model, Cmd.none, NoOp )


wrapForm : Maybe String -> FormModel -> Model
wrapForm maybeMealId form =
    case maybeMealId of
        Just mealId ->
            Editing mealId form

        Nothing ->
            Creating form


mapForm : (FormModel -> FormModel) -> Model -> Model
mapForm transform model =
    case model of
        Creating form ->
            Creating (transform form)

        Editing mealId form ->
            Editing mealId (transform form)

        _ ->
            model


mapNutritionFields :
    { nutrients : Maybe (List NutrientAmount)
    , nutritionLoading : Bool
    , nutritionError : Maybe String
    }
    -> Model
    -> Model
mapNutritionFields nutrition model =
    case model of
        LoadingEdit loading ->
            LoadingEdit
                { loading
                    | nutrients = nutrition.nutrients
                    , nutritionLoading = nutrition.nutritionLoading
                    , nutritionError = nutrition.nutritionError
                }

        Editing mealId form ->
            Editing mealId
                { form
                    | nutrients = nutrition.nutrients
                    , nutritionLoading = nutrition.nutritionLoading
                    , nutritionError = nutrition.nutritionError
                }

        Creating form ->
            Creating
                { form
                    | nutrients = nutrition.nutrients
                    , nutritionLoading = nutrition.nutritionLoading
                    , nutritionError = nutrition.nutritionError
                }

        EditLoadFailed _ ->
            model


completeComponentSuggestion : RowId -> Model -> ( Model, Cmd Msg, OutMsg )
completeComponentSuggestion rowId model =
    withForm model
        (\maybeMealId form ->
            case findRow rowId form.components of
                Just row ->
                    case List.head (Search.completions row.searchQuery row.categorySuggestions) of
                        Just completion ->
                            let
                                ( nextForm, cmd, outMsg ) =
                                    onComponentSearchChanged rowId
                                        (Search.applyCompletion completion row.searchQuery)
                                        form
                            in
                            ( wrapForm maybeMealId nextForm, cmd, outMsg )

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )
        )


submitModel : Model -> ( Model, Cmd Msg, OutMsg )
submitModel model =
    withForm model
        (\maybeMealId form ->
            case toMealRequestForm form of
                Ok request ->
                    case maybeMealId of
                        Just mealId ->
                            ( Editing mealId { form | submitting = True, error = Nothing }
                            , Cmd.none
                            , RequestUpdateMeal mealId request
                            )

                        Nothing ->
                            ( Creating { form | submitting = True, error = Nothing }
                            , Cmd.none
                            , RequestCreateMeal request
                            )

                Err MealNameRequired ->
                    ( wrapForm maybeMealId
                        { form | error = Just "Name is required", submitting = False }
                    , Cmd.none
                    , NoOp
                    )

                Err ComponentRequired ->
                    ( wrapForm maybeMealId
                        { form
                            | error =
                                Just "At least one component with a selected product is required"
                            , submitting = False
                        }
                    , Cmd.none
                    , NoOp
                    )
        )


requestNextMissingProductName : Maybe String -> List ComponentRow -> ItemNameLookup.Names -> OutMsg
requestNextMissingProductName completedProductId rows productNames =
    rows
        |> List.map .productId
        |> List.filter (String.trim >> String.isEmpty >> not)
        |> (\ids ->
                ItemNameLookup.nextMissingProductId
                    completedProductId
                    ids
                    productNames
           )
        |> Maybe.map RequestProductName
        |> Maybe.withDefault NoOp


mergeProductName : String -> String -> ComponentRow -> ComponentRow
mergeProductName productId name row =
    if row.productId == productId then
        { row | productName = name, searchQuery = name }

    else
        row


toMealRequest : Model -> Result ValidationError CreateMealRequest
toMealRequest model =
    case model of
        Creating form ->
            toMealRequestForm form

        Editing _ form ->
            toMealRequestForm form

        _ ->
            Err ComponentRequired


toMealRequestForm : FormModel -> Result ValidationError CreateMealRequest
toMealRequestForm form =
    let
        trimmedName : String
        trimmedName =
            String.trim form.name
    in
    if String.isEmpty trimmedName then
        Err MealNameRequired

    else
        case selectedComponents form.components of
            [] ->
                Err ComponentRequired

            components ->
                Ok
                    { name = trimmedName
                    , notes = Text.blankToMaybe form.notes
                    , totalQuantity =
                        Text.blankToMaybe form.totalQuantity
                            |> Maybe.map
                                (\amount ->
                                    { amount = amount
                                    , unit = Text.trimOrDefault defaultCode form.totalUnit
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
                    , unit = Text.trimOrDefault defaultCode row.unit
                    }
                }
            )


updateComponent : RowId -> ComponentPatch -> FormModel -> FormModel
updateComponent rowId patch form =
    { form | components = List.map (patchRow rowId patch) form.components }


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
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError =
            \message model ->
                case model of
                    LoadingEdit _ ->
                        EditLoadFailed message

                    _ ->
                        mapForm (\form -> { form | error = Just message }) model
        }


view : Model -> Element Msg
view model =
    case model of
        Creating form ->
            Ui.pageContainer
                [ errorView form
                , formView Nothing form
                ]

        LoadingEdit _ ->
            Ui.pageContainer [ Ui.loading "Loading meal..." ]

        EditLoadFailed message ->
            Ui.pageContainer [ Ui.errorBanner message ]

        Editing mealId form ->
            Ui.pageContainer
                [ errorView form
                , formView (Just mealId) form
                ]


errorView : FormModel -> Element msg
errorView form =
    case form.error of
        Just message ->
            Ui.errorBanner message

        Nothing ->
            Element.none


formView : Maybe String -> FormModel -> Element Msg
formView maybeMealId form =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.input "Name" form.name NameChanged
        , Ui.input "Notes" form.notes NotesChanged
        , quantityTextInput
            { amountLabel = "Total Quantity"
            , amount = form.totalQuantity
            , onAmountChange = TotalQuantityChanged
            , unitLabel = "Total Unit"
            , unit = form.totalUnit
            , onUnitChange = TotalUnitChanged
            }
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 10 ]
            (List.map componentRowView form.components)
        , Ui.ghostButton "+ Add Component" AddComponentClicked
        , nutritionView maybeMealId form
        , Ui.submitButton form.submitting
            (if maybeMealId == Nothing then
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
        , Element.row [ Element.width Element.fill, Element.spacing 8 ]
            [ quantityTextInput
                { amountLabel = "Qty"
                , amount = row.quantity
                , onAmountChange = ComponentQuantityChanged row.rowId
                , unitLabel = "Unit"
                , unit = row.unit
                , onUnitChange = ComponentUnitChanged row.rowId
                }
            , Ui.button "Remove" (RemoveComponentClicked row.rowId)
            ]
        ]


quantityTextInput :
    { amountLabel : String
    , amount : String
    , onAmountChange : String -> msg
    , unitLabel : String
    , unit : String
    , onUnitChange : String -> msg
    }
    -> Element msg
quantityTextInput config =
    Element.row [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.input config.amountLabel config.amount config.onAmountChange
        , Ui.input config.unitLabel config.unit config.onUnitChange
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
            [ Border.rounded 12
            , Background.color Ui.inputFill
            , Element.padding 12
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


nutritionView : Maybe String -> FormModel -> Element Msg
nutritionView maybeMealId form =
    case maybeMealId of
        Just _ ->
            Element.column [ Element.width Element.fill, Element.spacing 10 ]
                [ Ui.sectionHeader "Nutrition"
                , View.NutritionPreview.view
                    { loading = form.nutritionLoading
                    , error = form.nutritionError
                    , nutrients = form.nutrients
                    }
                ]

        Nothing ->
            Element.none
