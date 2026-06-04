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
    , updateComponent
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, SearchResponse, SearchResult)
import Api.Meals as Meals exposing (CreateMealComponentRequest, CreateMealRequest, Meal)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Route exposing (Route(..))
import Ui


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


type Msg
    = MealLoaded (Result Client.ApiError Meal)
    | ProductNameLoaded String (Result Client.ApiError ProductDetail)
    | NameChanged String
    | NotesChanged String
    | TotalQuantityChanged String
    | TotalUnitChanged String
    | ComponentSearchChanged RowId String
    | ComponentSearchCompleted RowId Int (Result Client.ApiError SearchResponse)
    | SelectProduct RowId SearchResult
    | ComponentQuantityChanged RowId String
    | ComponentUnitChanged RowId String
    | AddComponentClicked
    | RemoveComponentClicked RowId
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)
    | BackClicked


type OutMsg
    = NoOp
    | RequestMeal String
    | RequestProductName String
    | RequestProductSearch RowId Int Foods.SearchRequest
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
    ( { model | mealId = Just mealId, fetching = True }, RequestMeal mealId )


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
                        , totalQuantity = Maybe.map .amount meal.totalQuantity |> Maybe.withDefault ""
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
                    ( { model | components = List.map (mergeProductName productId product.name) model.components }, Cmd.none, requestNextMissingProductName productId model.components )

                Err _ ->
                    ( model, Cmd.none, requestNextMissingProductName productId model.components )

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

                nextModel : Model
                nextModel =
                    model
                        |> updateComponent rowId (SetSearchQuery query)
                        |> updateComponent rowId (SetSearchStarted token)
            in
            if String.length (String.trim query) < 2 then
                ( nextModel |> updateComponent rowId (SetSearchResults token []), Cmd.none, NoOp )

            else
                ( { nextModel | nextSearchToken = token + 1 }, Cmd.none, RequestProductSearch rowId token { query = query } )

        ComponentSearchCompleted rowId token result ->
            case result of
                Ok response ->
                    ( updateComponent rowId (SetSearchResults token response.items) model, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( updateComponent rowId (SetSearching False) model, Cmd.none, SessionExpired )

                    else
                        ( updateComponent rowId (SetSearching False) model, Cmd.none, NoOp )

        SelectProduct rowId result ->
            ( updateComponent rowId (SetProduct result.id result.name) model, Cmd.none, NoOp )

        ComponentQuantityChanged rowId value ->
            ( updateComponent rowId (SetQuantity value) model, Cmd.none, NoOp )

        ComponentUnitChanged rowId value ->
            ( updateComponent rowId (SetUnit value) model, Cmd.none, NoOp )

        AddComponentClicked ->
            ( { model | components = model.components ++ [ emptyComponentRow model.nextRowId ], nextRowId = model.nextRowId + 1 }, Cmd.none, NoOp )

        RemoveComponentClicked rowId ->
            ( { model | components = removeRow rowId model.components }, Cmd.none, NoOp )

        SubmitClicked ->
            case toMealRequest model of
                Ok request ->
                    case model.mealId of
                        Just mealId ->
                            ( { model | submitting = True, error = Nothing }, Cmd.none, RequestUpdateMeal mealId request )

                        Nothing ->
                            ( { model | submitting = True, error = Nothing }, Cmd.none, RequestCreateMeal request )

                Err MealNameRequired ->
                    ( { model | error = Just "Name is required", submitting = False }, Cmd.none, NoOp )

                Err ComponentRequired ->
                    ( { model | error = Just "At least one component with a selected product is required", submitting = False }, Cmd.none, NoOp )

        SaveCompleted result ->
            case result of
                Ok meal ->
                    ( { model | submitting = False }, Cmd.none, Navigate (MealDetail meal.id) )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | submitting = False, error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

                    else
                        ( { model | submitting = False, error = Just (Client.displayError error) }, Cmd.none, NoOp )

        BackClicked ->
            ( model, Cmd.none, Navigate Meals )


requestNextProductName : List ComponentRow -> OutMsg
requestNextProductName rows =
    rows
        |> List.filter (\row -> not (String.isEmpty row.productId) && String.isEmpty row.productName)
        |> List.head
        |> Maybe.map (.productId >> RequestProductName)
        |> Maybe.withDefault NoOp


requestNextMissingProductName : String -> List ComponentRow -> OutMsg
requestNextMissingProductName completedProductId rows =
    rows
        |> List.filter (\row -> row.productId /= completedProductId && not (String.isEmpty row.productId) && String.isEmpty row.productName)
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
                    , notes = blankToMaybe model.notes
                    , totalQuantity =
                        blankToMaybe model.totalQuantity
                            |> Maybe.map (\amount -> { amount = amount, unit = defaultString "g" model.totalUnit })
                    , components = components
                    }


selectedComponents : List ComponentRow -> List CreateMealComponentRequest
selectedComponents rows =
    rows
        |> List.filter (\row -> not (String.isEmpty (String.trim row.productId)))
        |> List.map
            (\row ->
                { item = { itemType = "product", id = String.trim row.productId }
                , quantity = { amount = defaultString "100" row.quantity, unit = defaultString "g" row.unit }
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
                { row | productId = id, productName = name, searchQuery = name, searchResults = [], searching = False }

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


removeRow : RowId -> List ComponentRow -> List ComponentRow
removeRow rowId rows =
    if List.length rows <= 1 then
        rows

    else
        List.filter (\row -> row.rowId /= rowId) rows


blankToMaybe : String -> Maybe String
blankToMaybe raw =
    let
        trimmed : String
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just trimmed


defaultString : String -> String -> String
defaultString fallback raw =
    case blankToMaybe raw of
        Just value ->
            value

        Nothing ->
            fallback


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Element.column [ Element.width Element.fill, Element.spacing 16, Element.padding 24 ]
        [ Element.row [ Element.spacing 12 ]
            [ Ui.button "Back" BackClicked
            , Element.el [ Font.size 22, Font.bold ] (Element.text (pageTitle model))
            ]
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , if model.fetching then
            Element.text "Loading meal..."

          else
            formView model
        ]


pageTitle : Model -> String
pageTitle model =
    case model.mealId of
        Just _ ->
            "Edit Meal"

        Nothing ->
            "Create Meal"


formView : Model -> Element Msg
formView model =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.input "Name" model.name NameChanged
        , Ui.input "Notes" model.notes NotesChanged
        , Element.row [ Element.spacing 8 ]
            [ Ui.input "Total Quantity" model.totalQuantity TotalQuantityChanged
            , Ui.input "Total Unit" model.totalUnit TotalUnitChanged
            ]
        , Element.el [ Font.size 18, Font.bold ] (Element.text "Components")
        , Element.column [ Element.width Element.fill, Element.spacing 10 ] (List.map componentRowView model.components)
        , Ui.button "+ Add Component" AddComponentClicked
        , Ui.button
            (if model.submitting then
                "Saving..."

             else if model.mealId == Nothing then
                "Create Meal"

             else
                "Update Meal"
            )
            SubmitClicked
        ]


componentRowView : ComponentRow -> Element Msg
componentRowView row =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 8
        , Element.padding 12
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Ui.input "Search Product" row.searchQuery (ComponentSearchChanged row.rowId)
        , if List.isEmpty row.searchResults then
            Element.none

          else
            Element.column [ Element.spacing 4 ] (List.map (searchResultView row.rowId) row.searchResults)
        , Element.row [ Element.spacing 8 ]
            [ Ui.input "Qty" row.quantity (ComponentQuantityChanged row.rowId)
            , Ui.input "Unit" row.unit (ComponentUnitChanged row.rowId)
            , Ui.button "Remove" (RemoveComponentClicked row.rowId)
            ]
        ]


searchResultView : RowId -> SearchResult -> Element Msg
searchResultView rowId result =
    Ui.button result.name (SelectProduct rowId result)
