module Component.Meal.Form exposing
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
import Data.ItemRef exposing (ItemType(..))
import Data.Nutrition exposing (defaultCode)
import Data.Search as Search exposing (Completion, QueryState)
import Element exposing (Device, Element)
import I18n
import Lib.Loadable exposing (Loadable(..))
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Set exposing (Set)
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Icon as Icon
import Ui.Input as UiInput
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.QuantityInput as QuantityInput
import View.Search as SearchView



-- MODEL


type alias RowId =
    Int


type alias ComponentRow =
    { rowId : RowId
    , productId : String
    , quantity : String
    , unit : String
    , unitOpen : Bool
    , search : QueryState
    , searchResults : Loadable () (List SearchResult)
    , completionIndex : Int
    }


type alias CategorySuggestionResult =
    Result Client.ApiError Foods.CategorySuggestionResponse


type alias ProductAndCategoryRequests =
    { rowId : RowId
    , searchToken : Ticket
    , searchRequest : Foods.SearchRequest
    , categoryToken : Ticket
    , categoryRequest : Foods.CategorySuggestionRequest
    }


type alias FormFields =
    { name : String
    , notes : String
    , totalQuantity : String
    , totalUnit : String
    , totalUnitOpen : Bool
    , components : List ComponentRow
    , namedProductIds : Set String
    , nextRowId : RowId
    , nextSearchToken : Ticket
    , submit : SubmitState
    , units : List Foods.UnitItem
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


type FormFieldOutMsg
    = RequestProductName String
    | RequestProductSearch RowId Ticket Foods.SearchRequest
    | RequestCategorySuggestions RowId Ticket Foods.CategorySuggestionRequest
    | RequestProductAndCats ProductAndCategoryRequests
    | FormSessionExpired


emptyFormFields : FormFields
emptyFormFields =
    { name = ""
    , notes = ""
    , totalQuantity = ""
    , totalUnit = defaultCode
    , totalUnitOpen = False
    , components = [ emptyComponentRow 1 ]
    , namedProductIds = Set.empty
    , nextRowId = 2
    , nextSearchToken = Ticket.next Ticket.initial
    , submit = Idle
    , units = []
    }


emptyComponentRow : RowId -> ComponentRow
emptyComponentRow rowId =
    { rowId = rowId
    , productId = ""
    , quantity = "100"
    , unit = defaultCode
    , unitOpen = False
    , search = Search.empty
    , searchResults = NotAsked
    , completionIndex = -1
    }



-- UPDATE


type FormFieldMsg
    = NameChanged String
    | NotesChanged String
    | TotalQuantityChanged String
    | TotalUnitChanged String
    | TotalUnitToggled
    | ComponentSearchChanged RowId String
    | ComponentSearchCompleted RowId Ticket (Result Client.ApiError SearchResponse)
    | ComponentCategoriesCompleted RowId Ticket CategorySuggestionResult
    | CompleteFirstComponentSuggestion RowId
    | ComponentCompletionClicked RowId Completion
    | ComponentCompletionActiveChanged RowId Int
    | SelectProduct RowId SearchResult
    | ComponentQuantityChanged RowId String
    | ComponentUnitChanged RowId String
    | ComponentUnitToggled RowId
    | AddComponentClicked
    | RemoveComponentClicked RowId
    | ProductNameLoaded String (Result Client.ApiError ProductDetail)


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
            ( { form | totalUnit = value, totalUnitOpen = False }, Cmd.none, Nothing )

        TotalUnitToggled ->
            ( { form | totalUnitOpen = not form.totalUnitOpen }, Cmd.none, Nothing )

        ProductNameLoaded productId result ->
            let
                name : String
                name =
                    case result of
                        Ok product ->
                            product.name

                        Err _ ->
                            I18n.t TidMealUnknownFood

                named : Set String
                named =
                    Set.insert productId form.namedProductIds
            in
            ( { form
                | components = List.map (applyProductName productId name) form.components
                , namedProductIds = named
              }
            , Cmd.none
            , requestNextMissingProductName form.components named
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

        ComponentCompletionActiveChanged rowId index ->
            ( updateComponent rowId (SetCompletionIndex index) form
            , Cmd.none
            , Nothing
            )

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

        ComponentUnitToggled rowId ->
            ( { form | components = List.map (toggleUnitOpen rowId) form.components }
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



-- VIEW


viewFormFields :
    Theme
    -> Device
    -> (FormFieldMsg -> msg)
    -> FormFields
    -> Element msg
viewFormFields theme device toMsg form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Surface.formSection theme
            (I18n.t TidFoodEditorBasicInfo)
            [ UiInput.input theme
                { label = I18n.t TidFoodEditorName
                , value = form.name
                , onChange = toMsg << NameChanged
                }
            , UiInput.input theme
                { label = I18n.t TidMealNotes
                , value = form.notes
                , onChange = toMsg << NotesChanged
                }
            ]
        , Surface.formSection theme
            (I18n.t TidMealTotal)
            [ UiInput.numericInput theme
                { label = I18n.t TidMealTotalQuantity
                , value = form.totalQuantity
                , onChange = toMsg << TotalQuantityChanged
                }
            , UiInput.selectDropdown device
                theme
                { label = I18n.t TidMealTotalUnit
                , selected = form.totalUnit
                , options = QuantityInput.unitOptions form.totalUnit form.units
                , onChange = toMsg << TotalUnitChanged
                , isOpen = form.totalUnitOpen
                , onToggle = toMsg TotalUnitToggled
                }
            ]
        , Surface.section theme
            { header = Just (Typography.subsectionTitle theme (I18n.t TidMealComponents))
            , body =
                List.intersperse (Surface.hairline theme)
                    (List.map (componentRowView theme device toMsg form.units) form.components)
            , footer =
                Just
                    (Button.textButton device
                        theme
                        { tone = Button.Ghost
                        , width = Button.FullWidth
                        , label = I18n.t TidMealAddComponent
                        , onPress = toMsg AddComponentClicked
                        , submitState = Nothing
                        , submittingLabel = Nothing
                        , trailing = Nothing
                        }
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

        ( transitionedSearch, categoryReq ) =
            Search.onQueryChanged query priorSearch

        token : Ticket
        token =
            form.nextSearchToken

        categoryToken : Ticket
        categoryToken =
            Ticket.next token

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
                Just { query = query, scope = Foods.SearchAll }
    in
    case ( searchRequest, categoryReq ) of
        ( Just productRequest, Just cat ) ->
            ( { nextForm | nextSearchToken = Ticket.next categoryToken }
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
            ( { nextForm | nextSearchToken = categoryToken }
                |> updateComponent rowId SetSearchLoading
            , Cmd.none
            , Just (RequestProductSearch rowId token productRequest)
            )

        ( Nothing, Just cat ) ->
            ( { nextForm | nextSearchToken = Ticket.next categoryToken }
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


requestNextMissingProductName : List ComponentRow -> Set String -> Maybe FormFieldOutMsg
requestNextMissingProductName rows namedProductIds =
    rows
        |> List.map .productId
        |> List.filter (String.trim >> String.isEmpty >> not)
        |> List.filter (\id -> not (Set.member id namedProductIds))
        |> List.head
        |> Maybe.map RequestProductName


applyProductName : String -> String -> ComponentRow -> ComponentRow
applyProductName productId name row =
    if row.productId == productId then
        { row | search = Search.withQuery name row.search }

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
    | SetSearchResults Ticket (List SearchResult)
    | SetSearchLoading
    | SetSearchFailed
    | SetCompletionIndex Int


patchRow : RowId -> ComponentPatch -> ComponentRow -> ComponentRow
patchRow rowId patch row =
    if row.rowId /= rowId then
        row

    else
        case patch of
            SetProduct id name ->
                { row
                    | productId = id
                    , search = Search.withQuery name Search.empty
                    , searchResults = NotAsked
                    , completionIndex = -1
                }

            SetQuantity value ->
                { row | quantity = value }

            SetUnit value ->
                { row | unit = value, unitOpen = False }

            SetSearch queryState ->
                { row | search = queryState, completionIndex = -1 }

            SetSearchResults token results ->
                if row.search.searchToken == token then
                    { row | searchResults = Success results }

                else
                    row

            SetSearchLoading ->
                { row | searchResults = Loading }

            SetSearchFailed ->
                { row | searchResults = Failure () }

            SetCompletionIndex index ->
                { row | completionIndex = index }


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


toggleUnitOpen : RowId -> ComponentRow -> ComponentRow
toggleUnitOpen rowId row =
    if row.rowId == rowId then
        { row | unitOpen = not row.unitOpen }

    else
        { row | unitOpen = False }


componentRowView :
    Theme
    -> Device
    -> (FormFieldMsg -> msg)
    -> List Foods.UnitItem
    -> ComponentRow
    -> Element msg
componentRowView theme device toMsg units row =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ SearchView.searchInput theme
            device
            { id = "meal-component-completions-" ++ String.fromInt row.rowId
            , onChange = toMsg << ComponentSearchChanged row.rowId
            , text = row.search.query
            , label = UiInput.LabelAbove (I18n.t TidMealSearchProduct)
            , completions = Search.completions row.search.query row.search.categorySuggestions
            , activeIndex = row.completionIndex
            , onActiveChanged = toMsg << ComponentCompletionActiveChanged row.rowId
            , onTabComplete = toMsg (CompleteFirstComponentSuggestion row.rowId)
            , onCompletionClick = toMsg << ComponentCompletionClicked row.rowId
            }
        , case row.searchResults of
            Loading ->
                Feedback.loading theme (I18n.t TidMealSearchingFoods)

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
        , Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ UiInput.numericInput theme
                { label = I18n.t TidMealQty
                , value = row.quantity
                , onChange = toMsg << ComponentQuantityChanged row.rowId
                }
            , UiInput.selectDropdown device
                theme
                { label = I18n.t TidNutrientTableUnit
                , selected = row.unit
                , options = QuantityInput.unitOptions row.unit units
                , onChange = toMsg << ComponentUnitChanged row.rowId
                , isOpen = row.unitOpen
                , onToggle = toMsg (ComponentUnitToggled row.rowId)
                }
            , Element.el [ Element.centerY ]
                (Button.iconButton device
                    theme
                    { icon = Icon.Close
                    , title = I18n.t TidFoodEditorRemove
                    , onPress = Just (toMsg (RemoveComponentClicked row.rowId))
                    , tone = Button.Danger
                    }
                )
            ]
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
