module Page.Meal.Form.Common exposing
    ( CategorySuggestionResult
    , ComponentRow
    , FormFieldMsg(..)
    , FormFieldOutMsg(..)
    , FormFields
    , ProductAndCategoryRequests
    , RowId
    , ValidationError(..)
    , emptyComponentRow
    , emptyFormFields
    , errorView
    , toMealRequest
    , updateFormField
    , viewFormFields
    )

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CategorySuggestion
        , ProductDetail
        , SearchResponse
        , SearchResult
        )
import Api.Meals
    exposing
        ( CreateMealComponentRequest
        , CreateMealRequest
        )
import Api.Result as ApiResult
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition exposing (defaultCode)
import Data.Search as Search exposing (Completion)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.Text as Text
import Ui
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
    , categoryRequest : Foods.CategorySuggestionRequest
    }


type alias FormFields =
    { name : String
    , notes : String
    , totalQuantity : String
    , totalUnit : String
    , components : List ComponentRow
    , productNames : ItemNameLookup.Names
    , nextRowId : RowId
    , nextSearchToken : Int
    , submitting : Bool
    , error : Maybe String
    }


type ValidationError
    = MealNameRequired
    | ComponentRequired


type FormFieldMsg
    = NameChanged String
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
    | ProductNameLoaded String (Result Client.ApiError ProductDetail)


type FormFieldOutMsg
    = RequestProductName String
    | RequestProductSearch RowId Int Foods.SearchRequest
    | RequestCategorySuggestions RowId Int Foods.CategorySuggestionRequest
    | RequestProductAndCats ProductAndCategoryRequests
    | FormSessionExpired


emptyFormFields : FormFields
emptyFormFields =
    { name = ""
    , notes = ""
    , totalQuantity = ""
    , totalUnit = defaultCode
    , components = [ emptyComponentRow 1 ]
    , productNames = ItemNameLookup.empty
    , nextRowId = 2
    , nextSearchToken = 1
    , submitting = False
    , error = Nothing
    }


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


updateFormField :
    FormFieldMsg
    -> FormFields
    -> ( FormFields, Cmd FormFieldMsg, Maybe FormFieldOutMsg )
updateFormField msg form =
    case msg of
        NameChanged value ->
            ( { form | name = value }, Cmd.none, Nothing )

        NotesChanged value ->
            ( { form | notes = value }, Cmd.none, Nothing )

        TotalQuantityChanged value ->
            ( { form | totalQuantity = value }, Cmd.none, Nothing )

        TotalUnitChanged value ->
            ( { form | totalUnit = value }, Cmd.none, Nothing )

        ProductNameLoaded productId result ->
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

                nextForm : FormFields
                nextForm =
                    { form
                        | components =
                            List.map (mergeProductName productId name) form.components
                        , productNames = nextNames
                    }
            in
            ( nextForm
            , Cmd.none
            , requestNextMissingProductName
                (Just productId)
                form.components
                nextNames
            )

        ComponentSearchChanged rowId query ->
            let
                ( nextForm, cmd, outMsg ) =
                    onComponentSearchChanged rowId query form
            in
            ( nextForm, cmd, outMsg )

        ComponentSearchCompleted rowId token result ->
            case result of
                Ok response ->
                    ( updateComponent rowId
                        (SetSearchResults token response.items)
                        form
                    , Cmd.none
                    , Nothing
                    )

                Err error ->
                    let
                        ( nextForm, _, signal ) =
                            ApiResult.failure
                                { noOp = Nothing
                                , sessionExpired = Just FormSessionExpired
                                , applyError =
                                    \_ current -> updateComponent rowId SetSearchingFalse current
                                }
                                error
                                form
                    in
                    ( nextForm, Cmd.none, signal )

        ComponentCategoriesCompleted rowId token result ->
            case result of
                Ok response ->
                    ( updateComponent rowId
                        (SetCategorySuggestions token response.items)
                        form
                    , Cmd.none
                    , Nothing
                    )

                Err error ->
                    let
                        ( nextForm, _, signal ) =
                            ApiResult.failure
                                { noOp = Nothing
                                , sessionExpired = Just FormSessionExpired
                                , applyError =
                                    \_ current ->
                                        updateComponent rowId ClearCategorySuggestions current
                                }
                                error
                                form
                    in
                    ( nextForm, Cmd.none, signal )

        CompleteFirstComponentSuggestion rowId ->
            completeComponentSuggestion rowId form

        ComponentCompletionClicked rowId completion ->
            case findRow rowId form.components of
                Just row ->
                    onComponentSearchChanged rowId
                        (Search.applyCompletion completion row.searchQuery)
                        form

                Nothing ->
                    ( form, Cmd.none, Nothing )

        SelectProduct rowId result ->
            ( updateComponent rowId
                (SetProduct result.id result.name)
                form
            , Cmd.none
            , Nothing
            )

        ComponentQuantityChanged rowId value ->
            ( updateComponent rowId (SetQuantity value) form
            , Cmd.none
            , Nothing
            )

        ComponentUnitChanged rowId value ->
            ( updateComponent rowId (SetUnit value) form
            , Cmd.none
            , Nothing
            )

        AddComponentClicked ->
            ( { form
                | components = form.components ++ [ emptyComponentRow form.nextRowId ]
                , nextRowId = form.nextRowId + 1
              }
            , Cmd.none
            , Nothing
            )

        RemoveComponentClicked rowId ->
            ( { form | components = removeRow rowId form.components }
            , Cmd.none
            , Nothing
            )


errorView : FormFields -> Element msg
errorView form =
    case form.error of
        Just message ->
            Ui.errorBanner message

        Nothing ->
            Element.none


viewFormFields :
    (FormFieldMsg -> msg)
    -> FormFields
    -> Element msg
viewFormFields toMsg form =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.input "Name" form.name (toMsg << NameChanged)
        , Ui.input "Notes" form.notes (toMsg << NotesChanged)
        , quantityTextInput
            { amountLabel = "Total Quantity"
            , amount = form.totalQuantity
            , onAmountChange = toMsg << TotalQuantityChanged
            , unitLabel = "Total Unit"
            , unit = form.totalUnit
            , onUnitChange = toMsg << TotalUnitChanged
            }
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 10 ]
            (List.map (componentRowView toMsg) form.components)
        , Ui.ghostButton "+ Add Component" (toMsg AddComponentClicked)
        ]


toMealRequest : FormFields -> Result ValidationError CreateMealRequest
toMealRequest form =
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


onComponentSearchChanged :
    RowId
    -> String
    -> FormFields
    -> ( FormFields, Cmd FormFieldMsg, Maybe FormFieldOutMsg )
onComponentSearchChanged rowId query form =
    let
        token : Int
        token =
            form.nextSearchToken

        categoryToken : Int
        categoryToken =
            token + 1

        nextModel : FormFields
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

        categoryRequest : Maybe Foods.CategorySuggestionRequest
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
            , Just
                (RequestProductAndCats
                    { rowId = rowId
                    , searchToken = token
                    , searchRequest = productRequest
                    , categoryToken = categoryToken
                    , categoryRequest = categorySuggestionRequest
                    }
                )
            )

        ( Just productRequest, Nothing ) ->
            ( { nextModel | nextSearchToken = token + 1 }
            , Cmd.none
            , Just (RequestProductSearch rowId token productRequest)
            )

        ( Nothing, Just categorySuggestionRequest ) ->
            ( { nextModel | nextSearchToken = token + 2 }
                |> updateComponent rowId (SetSearchResults token [])
            , Cmd.none
            , Just
                (RequestCategorySuggestions
                    rowId
                    categoryToken
                    categorySuggestionRequest
                )
            )

        _ ->
            ( nextModel |> updateComponent rowId (SetSearchResults token [])
            , Cmd.none
            , Nothing
            )


completeComponentSuggestion :
    RowId
    -> FormFields
    -> ( FormFields, Cmd FormFieldMsg, Maybe FormFieldOutMsg )
completeComponentSuggestion rowId form =
    case findRow rowId form.components of
        Just row ->
            case List.head (Search.completions row.searchQuery row.categorySuggestions) of
                Just completion ->
                    onComponentSearchChanged rowId
                        (Search.applyCompletion completion row.searchQuery)
                        form

                Nothing ->
                    ( form, Cmd.none, Nothing )

        Nothing ->
            ( form, Cmd.none, Nothing )


requestNextMissingProductName :
    Maybe String
    -> List ComponentRow
    -> ItemNameLookup.Names
    -> Maybe FormFieldOutMsg
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


mergeProductName : String -> String -> ComponentRow -> ComponentRow
mergeProductName productId name row =
    if row.productId == productId then
        { row | productName = name, searchQuery = name }

    else
        row


updateComponent : RowId -> ComponentPatch -> FormFields -> FormFields
updateComponent rowId patch form =
    { form | components = List.map (patchRow rowId patch) form.components }


type ComponentPatch
    = SetProduct String String
    | SetQuantity String
    | SetUnit String
    | SetSearchQuery String
    | SetSearchStarted Int
    | SetSearchResults Int (List SearchResult)
    | SetSearchingFalse
    | SetCategorySuggestionsStarted Int
    | SetCategorySuggestions Int (List CategorySuggestion)
    | ClearCategorySuggestions


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

            SetSearchingFalse ->
                { row | searching = False }

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


componentRowView : (FormFieldMsg -> msg) -> ComponentRow -> Element msg
componentRowView toMsg row =
    Ui.card
        [ componentSearchInput toMsg row
        , if row.searching then
            Ui.loading "Searching foods..."

          else if List.isEmpty row.searchResults then
            Element.none

          else
            Element.column
                [ Element.width Element.fill
                , Element.spacing 0
                ]
                (List.map (searchResultView toMsg row.searchQuery row.rowId) row.searchResults)
        , Element.row [ Element.width Element.fill, Element.spacing 8 ]
            [ quantityTextInput
                { amountLabel = "Qty"
                , amount = row.quantity
                , onAmountChange = toMsg << ComponentQuantityChanged row.rowId
                , unitLabel = "Unit"
                , unit = row.unit
                , onUnitChange = toMsg << ComponentUnitChanged row.rowId
                }
            , Element.el [ Element.centerY ]
                (Ui.dangerIconButton
                    { label = "×"
                    , title = "Remove"
                    , onPress = toMsg (RemoveComponentClicked row.rowId)
                    }
                )
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


componentSearchInput : (FormFieldMsg -> msg) -> ComponentRow -> Element msg
componentSearchInput toMsg row =
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
                    (toMsg (CompleteFirstComponentSuggestion row.rowId))
                    options
                )
            ]
            { onChange = toMsg << ComponentSearchChanged row.rowId
            , text = row.searchQuery
            , placeholder = Nothing
            , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Search Product")
            }
        , SearchView.completionDropdown
            { onSelect = toMsg << ComponentCompletionClicked row.rowId }
            options
        ]


searchResultView : (FormFieldMsg -> msg) -> String -> RowId -> SearchResult -> Element msg
searchResultView toMsg query rowId result =
    SearchView.resultRow
        { query = query
        , item = result
        , onSelect = \_ -> toMsg (SelectProduct rowId result)
        }
