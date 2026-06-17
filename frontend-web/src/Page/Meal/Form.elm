module Page.Meal.Form exposing
    ( CategorySuggestionResult
    , ComponentRow
    , FormFieldMsg(..)
    , FormFieldOutMsg(..)
    , FormFields
    , ProductAndCategoryRequests
    , RowId
    , SubmitState(..)
    , ValidationError(..)
    , emptyComponentRow
    , emptyFormFields
    , isSubmitting
    , submitErrorMessage
    , toMealRequest
    , updateFormField
    , viewFormFields
    )

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( ProductDetail
        , SearchResponse
        , SearchResult
        )
import Api.Meals
    exposing
        ( CreateMealComponentRequest
        , CreateMealRequest
        )
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef exposing (ItemType(..))
import Data.Nutrition exposing (defaultCode)
import Data.Search as Search exposing (Completion, QueryState)
import Element exposing (Device, Element)
import Lib.Loadable exposing (Loadable(..))
import Lib.Text as Text
import Ui
import Ui.Icon as Icon
import Ui.Theme exposing (Theme)
import View.Search as SearchView


type alias RowId =
    Int


type alias ComponentRow =
    { rowId : RowId
    , productId : String
    , productName : String
    , quantity : String
    , unit : String
    , search : QueryState
    , searchResults : Loadable () (List SearchResult)
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
    , submit : SubmitState
    }


type SubmitState
    = Idle
    | Submitting
    | SubmitFailed String


isSubmitting : SubmitState -> Bool
isSubmitting state =
    case state of
        Submitting ->
            True

        _ ->
            False


submitErrorMessage : SubmitState -> Maybe String
submitErrorMessage state =
    case state of
        SubmitFailed message ->
            Just message

        _ ->
            Nothing


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
    , submit = Idle
    }


emptyComponentRow : RowId -> ComponentRow
emptyComponentRow rowId =
    { rowId = rowId
    , productId = ""
    , productName = ""
    , quantity = "100"
    , unit = defaultCode
    , search = Search.empty
    , searchResults = NotAsked
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
            onComponentSearchChanged rowId query form

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
                            Client.failure
                                { noOp = Nothing
                                , sessionExpired = Just FormSessionExpired
                                , applyError =
                                    \_ current -> updateComponent rowId SetSearchFailed current
                                }
                                error
                                form
                    in
                    ( nextForm, Cmd.none, signal )

        ComponentCategoriesCompleted rowId token result ->
            case result of
                Ok response ->
                    let
                        priorSearch : QueryState
                        priorSearch =
                            findRow rowId form.components
                                |> Maybe.map .search
                                |> Maybe.withDefault Search.empty
                    in
                    ( updateComponent rowId
                        (SetSearch
                            (Search.setCategorySuggestions
                                token
                                response.items
                                priorSearch
                            )
                        )
                        form
                    , Cmd.none
                    , Nothing
                    )

                Err error ->
                    let
                        ( nextForm, _, signal ) =
                            Client.failure
                                { noOp = Nothing
                                , sessionExpired = Just FormSessionExpired
                                , applyError =
                                    \_ current ->
                                        updateComponent rowId
                                            (SetSearch
                                                (Search.setCategorySuggestions
                                                    token
                                                    []
                                                    (findRow rowId current.components
                                                        |> Maybe.map .search
                                                        |> Maybe.withDefault Search.empty
                                                    )
                                                )
                                            )
                                            current
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
                        (Search.applyCompletion completion row.search.query)
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


viewFormFields :
    Theme
    -> Device
    -> (FormFieldMsg -> msg)
    -> FormFields
    -> Element msg
viewFormFields theme device toMsg form =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ Ui.section theme
            { header = Nothing
            , body =
                [ Ui.input theme
                    { label = "Name"
                    , value = form.name
                    , onChange = toMsg << NameChanged
                    }
                , Ui.input theme
                    { label = "Notes"
                    , value = form.notes
                    , onChange = toMsg << NotesChanged
                    }
                , quantityTextInput theme
                    device
                    { amountLabel = "Total Quantity"
                    , amount = form.totalQuantity
                    , onAmountChange = toMsg << TotalQuantityChanged
                    , unitLabel = "Total Unit"
                    , unit = form.totalUnit
                    , onUnitChange = toMsg << TotalUnitChanged
                    }
                ]
            , footer = Nothing
            }
        , Ui.section theme
            { header = Just (Ui.subsectionTitle theme "Components")
            , body =
                List.intersperse (Ui.hairline theme)
                    (List.map (componentRowView theme device toMsg) form.components)
            , footer =
                Just
                    (Ui.fullWidthGhostButton device
                        theme
                        "+ Add Component"
                        (toMsg AddComponentClicked)
                    )
            }
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
                { item = { itemType = Product, id = String.trim row.productId }
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
        priorSearch : QueryState
        priorSearch =
            findRow rowId form.components
                |> Maybe.map .search
                |> Maybe.withDefault Search.empty

        ( transitionedSearch, _, categoryReq ) =
            Search.onQueryChanged query priorSearch Nothing

        token : Int
        token =
            form.nextSearchToken

        categoryToken : Int
        categoryToken =
            token + 1

        nextSearch : QueryState
        nextSearch =
            { transitionedSearch
                | searchToken = token
                , categoryToken = categoryToken
            }

        nextForm : FormFields
        nextForm =
            form |> updateComponent rowId (SetSearch nextSearch)

        searchRequest : Maybe Foods.SearchRequest
        searchRequest =
            if String.length (String.trim query) < 2 then
                Nothing

            else
                Just { query = query }
    in
    case ( searchRequest, categoryReq ) of
        ( Just productRequest, Just cat ) ->
            ( { nextForm | nextSearchToken = token + 2 }
                |> updateComponent rowId SetSearchLoading
            , Cmd.none
            , Just
                (RequestProductAndCats
                    { rowId = rowId
                    , searchToken = token
                    , searchRequest = productRequest
                    , categoryToken = categoryToken
                    , categoryRequest = { query = cat.query, limit = 8 }
                    }
                )
            )

        ( Just productRequest, Nothing ) ->
            ( { nextForm | nextSearchToken = token + 1 }
                |> updateComponent rowId SetSearchLoading
            , Cmd.none
            , Just (RequestProductSearch rowId token productRequest)
            )

        ( Nothing, Just cat ) ->
            ( { nextForm | nextSearchToken = token + 2 }
                |> updateComponent rowId (SetSearchResults token [])
            , Cmd.none
            , Just
                (RequestCategorySuggestions
                    rowId
                    categoryToken
                    { query = cat.query, limit = 8 }
                )
            )

        _ ->
            ( nextForm |> updateComponent rowId (SetSearchResults token [])
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
            case List.head (Search.completions row.search.query row.search.categorySuggestions) of
                Just completion ->
                    onComponentSearchChanged rowId
                        (Search.applyCompletion completion row.search.query)
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
        { row | productName = name, search = Search.withQuery name row.search }

    else
        row


updateComponent : RowId -> ComponentPatch -> FormFields -> FormFields
updateComponent rowId patch form =
    { form | components = List.map (patchRow rowId patch) form.components }


type ComponentPatch
    = SetProduct String String
    | SetQuantity String
    | SetUnit String
    | SetSearch QueryState
    | SetSearchResults Int (List SearchResult)
    | SetSearchLoading
    | SetSearchFailed


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
                    , search =
                        { query = name
                        , searchToken = 0
                        , categoryToken = 0
                        , categorySuggestions = []
                        }
                    , searchResults = NotAsked
                }

            SetQuantity value ->
                { row | quantity = value }

            SetUnit value ->
                { row | unit = value }

            SetSearch queryState ->
                { row | search = queryState }

            SetSearchResults token results ->
                if row.search.searchToken == token then
                    { row | searchResults = Success results }

                else
                    row

            SetSearchLoading ->
                { row | searchResults = Loading }

            SetSearchFailed ->
                { row | searchResults = Failure () }


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


componentRowView : Theme -> Device -> (FormFieldMsg -> msg) -> ComponentRow -> Element msg
componentRowView theme device toMsg row =
    Element.column
        [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ SearchView.searchInput theme
            device
            { onChange = toMsg << ComponentSearchChanged row.rowId
            , text = row.search.query
            , label = "Search Product"
            , completions = Search.completions row.search.query row.search.categorySuggestions
            , onTabComplete = toMsg (CompleteFirstComponentSuggestion row.rowId)
            , onCompletionClick = toMsg << ComponentCompletionClicked row.rowId
            }
        , case row.searchResults of
            Loading ->
                Ui.loading theme "Searching foods..."

            Success results ->
                if List.isEmpty results then
                    Element.none

                else
                    Element.column
                        [ Element.width Element.fill
                        , Element.spacing 0
                        ]
                        (List.map
                            (\result ->
                                searchResultView theme
                                    device
                                    toMsg
                                    { rowId = row.rowId, query = row.search.query, result = result }
                            )
                            results
                        )

            Failure () ->
                Element.none

            NotAsked ->
                Element.none
        , Element.row [ Element.width Element.fill, Element.spacing Ui.space8 ]
            [ quantityTextInput theme
                device
                { amountLabel = "Qty"
                , amount = row.quantity
                , onAmountChange = toMsg << ComponentQuantityChanged row.rowId
                , unitLabel = "Unit"
                , unit = row.unit
                , onUnitChange = toMsg << ComponentUnitChanged row.rowId
                }
            , Element.el [ Element.centerY ]
                (Ui.dangerIconButton device
                    theme
                    { icon = Icon.Close
                    , title = "Remove"
                    , onPress = toMsg (RemoveComponentClicked row.rowId)
                    }
                )
            ]
        ]


quantityTextInput :
    Theme
    -> Device
    ->
        { amountLabel : String
        , amount : String
        , onAmountChange : String -> msg
        , unitLabel : String
        , unit : String
        , onUnitChange : String -> msg
        }
    -> Element msg
quantityTextInput theme device config =
    (if Ui.isSmall device then
        Element.column

     else
        Element.row
    )
        [ Element.width Element.fill, Element.spacing Ui.space8 ]
        [ Ui.input theme
            { label = config.amountLabel
            , value = config.amount
            , onChange = config.onAmountChange
            }
        , Ui.input theme
            { label = config.unitLabel
            , value = config.unit
            , onChange = config.onUnitChange
            }
        ]


type alias RowHit =
    { rowId : RowId
    , query : String
    , result : SearchResult
    }


searchResultView :
    Theme
    -> Device
    -> (FormFieldMsg -> msg)
    -> RowHit
    -> Element msg
searchResultView theme device toMsg hit =
    SearchView.resultRow theme
        device
        { query = hit.query
        , item = hit.result
        , onSelect = \_ -> toMsg (SelectProduct hit.rowId hit.result)
        }
