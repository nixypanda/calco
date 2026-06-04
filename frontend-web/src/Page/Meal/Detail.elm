module Page.Meal.Detail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , uniqueProductIds
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Meals as Meals exposing (Meal, MealNutritionResponse)
import Api.Result as ApiResult
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Data.Units as Units
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Ui
import View.NutritionPreview
import View.QuantityInput


type alias Model =
    { mealId : String
    , meal : Maybe Meal
    , productNames : ItemNameLookup.Names
    , amount : String
    , unit : String
    , units : List UnitItem
    , unitOpen : Bool
    , nutrients : Maybe (List NutrientAmount)
    , nutritionLoading : Bool
    , nutritionError : Maybe String
    , error : Maybe String
    , confirmDeleteOpen : Bool
    , deleting : Bool
    , deleteError : Maybe String
    }


type Msg
    = MealLoaded (Result Client.ApiError Meal)
    | ProductDetailLoaded String (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | AmountChanged String
    | UnitChanged String
    | ToggleUnitDropdown
    | NutrientPreviewLoaded (Result Client.ApiError MealNutritionResponse)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestNutrientPreview String String String
    | RequestDeleteMeal String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init mealId =
    ( { mealId = mealId
      , meal = Nothing
      , productNames = ItemNameLookup.empty
      , amount = "100"
      , unit = Units.defaultCode
      , units = fallbackUnits
      , unitOpen = False
      , nutrients = Nothing
      , nutritionLoading = True
      , nutritionError = Nothing
      , error = Nothing
      , confirmDeleteOpen = False
      , deleting = False
      , deleteError = Nothing
      }
    , RequestInitialData mealId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded result ->
            case result of
                Ok meal ->
                    ( { model | meal = Just meal, error = Nothing }
                    , Cmd.none
                    , requestProductNames (uniqueProductIds meal)
                    )

                Err error ->
                    failure error model

        ProductDetailLoaded productId result ->
            case result of
                Ok product ->
                    ( { model
                        | productNames =
                            ItemNameLookup.insertProduct productId product.name model.productNames
                      }
                    , Cmd.none
                    , nextProductNameRequest productId model
                    )

                Err _ ->
                    let
                        nextModel : Model
                        nextModel =
                            { model
                                | productNames =
                                    ItemNameLookup.insertProduct
                                        productId
                                        "Unknown food"
                                        model.productNames
                            }
                    in
                    ( nextModel, Cmd.none, nextProductNameRequest productId nextModel )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | units =
                            if List.isEmpty response.items then
                                fallbackUnits

                            else
                                response.items
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err _ ->
                    ( { model | units = fallbackUnits }, Cmd.none, NoOp )

        AmountChanged value ->
            requestNutritionFor
                { model
                    | amount = value
                    , unitOpen = False
                    , nutritionError = Nothing
                }

        UnitChanged value ->
            requestNutritionFor
                { model
                    | unit = value
                    , unitOpen = False
                    , nutritionError = Nothing
                }

        ToggleUnitDropdown ->
            ( { model | unitOpen = not model.unitOpen }, Cmd.none, NoOp )

        NutrientPreviewLoaded result ->
            case result of
                Ok response ->
                    if
                        response.quantity.amount
                            == model.amount
                            && response.quantity.unit
                            == model.unit
                    then
                        ( { model
                            | nutrients = Just response.nutrients
                            , nutritionLoading = False
                            , nutritionError = Nothing
                          }
                        , Cmd.none
                        , NoOp
                        )

                    else
                        ( model, Cmd.none, NoOp )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current
                                    | nutrients = Nothing
                                    , nutritionLoading = False
                                    , nutritionError = Just message
                                }
                        }
                        error
                        model

        DeleteClicked ->
            ( { model | confirmDeleteOpen = True, deleteError = Nothing }, Cmd.none, NoOp )

        CancelDeleteClicked ->
            ( { model | confirmDeleteOpen = False, deleteError = Nothing }, Cmd.none, NoOp )

        ConfirmDeleteClicked ->
            ( { model | deleting = True, deleteError = Nothing }
            , Cmd.none
            , RequestDeleteMeal model.mealId
            )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate Meals )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current
                                    | deleting = False
                                    , confirmDeleteOpen = True
                                    , deleteError = Just message
                                }
                        }
                        error
                        model

        EditClicked ->
            ( model, Cmd.none, Navigate (MealEdit model.mealId) )


uniqueProductIds : Meal -> List String
uniqueProductIds meal =
    meal.components
        |> List.filterMap
            (\component ->
                if component.item.itemType == "product" then
                    Just component.item.id

                else
                    Nothing
            )
        |> ItemNameLookup.uniqueProductIds


requestProductNames : List String -> OutMsg
requestProductNames ids =
    ItemNameLookup.nextMissingProductId Nothing ids ItemNameLookup.empty
        |> Maybe.map RequestProductDetail
        |> Maybe.withDefault NoOp


nextProductNameRequest : String -> Model -> OutMsg
nextProductNameRequest completedId model =
    case model.meal of
        Just meal ->
            uniqueProductIds meal
                |> (\ids ->
                        ItemNameLookup.nextMissingProductId
                            (Just completedId)
                            ids
                            model.productNames
                   )
                |> Maybe.map RequestProductDetail
                |> Maybe.withDefault NoOp

        Nothing ->
            NoOp


nameFor : String -> Model -> String
nameFor id model =
    ItemNameLookup.nameFor "Loading..." (ItemNameLookup.productRef id) model.productNames


requestNutritionFor : Model -> ( Model, Cmd Msg, OutMsg )
requestNutritionFor model =
    case String.toFloat model.amount of
        Just amount ->
            if amount > 0 then
                ( { model | nutritionLoading = True }
                , Cmd.none
                , RequestNutrientPreview model.mealId model.amount model.unit
                )

            else
                clearNutritionPreview model

        Nothing ->
            clearNutritionPreview model


clearNutritionPreview : Model -> ( Model, Cmd Msg, OutMsg )
clearNutritionPreview model =
    ( { model
        | nutrients = Nothing
        , nutritionLoading = False
        , nutritionError = Nothing
      }
    , Cmd.none
    , NoOp
    )


fallbackUnits : List UnitItem
fallbackUnits =
    [ { code = Units.defaultCode, name = Units.defaultCode, kind = "mass" } ]


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | error = Just message }
        }


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ Element.row [ Element.width Element.fill, Element.spacing 12 ]
            [ Element.el
                [ Ui.heading1, Font.bold ]
                (Element.text (Maybe.map .name model.meal |> Maybe.withDefault "Meal"))
            , Ui.button "Edit" EditClicked
            , Ui.button "Delete" DeleteClicked
            ]
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case model.meal of
            Just meal ->
                loadedView model meal

            Nothing ->
                Ui.loading "Loading meal..."
        ]


loadedView : Model -> Meal -> Element Msg
loadedView model meal =
    Element.column [ Element.width Element.fill, Element.spacing 16 ]
        [ case meal.notes of
            Just notes ->
                Ui.mutedText notes

            Nothing ->
                Element.none
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 8 ]
            (List.map (componentView model) meal.components)
        , nutritionView model
        , confirmDeleteView model
        ]


componentView : Model -> Meals.MealComponent -> Element Msg
componentView model component =
    Element.row
        [ Element.width Element.fill
        , Element.spacing 12
        , Element.padding 12
        , Background.color Ui.cardBg
        , Border.rounded 8
        , Border.width 1
        , Border.color Ui.borderGray
        ]
        [ Element.el [ Font.bold ] (Element.text (nameFor component.item.id model))
        , Element.el
            [ Font.color Ui.mutedColor ]
            (Element.text (component.quantity.amount ++ " " ++ component.quantity.unit))
        ]


nutritionView : Model -> Element Msg
nutritionView model =
    Element.column [ Element.width Element.fill, Element.spacing 10 ]
        [ Ui.sectionHeader "Nutrition"
        , Ui.card
            [ View.QuantityInput.dropdown
                { amountLabel = "Amount"
                , amount = model.amount
                , onAmountChange = AmountChanged
                , unitLabel = "Unit"
                , unit = model.unit
                , units = model.units
                , onUnitChange = UnitChanged
                , unitOpen = model.unitOpen
                , onUnitToggle = ToggleUnitDropdown
                }
            ]
        , View.NutritionPreview.view
            { loading = model.nutritionLoading
            , error = model.nutritionError
            , nutrients = model.nutrients
            }
        ]


confirmDeleteView : Model -> Element Msg
confirmDeleteView model =
    if model.confirmDeleteOpen then
        Element.column
            [ Element.spacing 8
            , Element.padding 12
            , Background.color Ui.dangerBg
            , Border.rounded 8
            ]
            [ Element.el [ Font.bold ] (Element.text "Delete meal?")
            , case model.deleteError of
                Just message ->
                    Ui.errorBanner message

                Nothing ->
                    Element.none
            , Element.row [ Element.spacing 8 ]
                [ Ui.button "Cancel" CancelDeleteClicked
                , Ui.dangerButton
                    (if model.deleting then
                        "Deleting..."

                     else
                        "Confirm Delete"
                    )
                    ConfirmDeleteClicked
                ]
            ]

    else
        Element.none
