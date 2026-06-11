module Page.Meal.Show exposing
    ( DeleteState(..)
    , LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , uniqueProductIds
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Meals as MealsApi exposing (Meal, MealNutritionResponse)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients exposing (NutritionInput, NutritionState(..), defaultNutritionInput)
import View.QuantityInput


type Model
    = Loading LoadingModel
    | LoadFailed String
    | Loaded LoadedModel


type alias LoadingModel =
    { mealId : String
    , units : List UnitItem
    , nutrition : NutritionState
    }


type alias LoadedModel =
    { mealId : String
    , meal : Meal
    , productNames : ItemNameLookup.Names
    , units : List UnitItem
    , nutrition : NutritionState
    , delete : DeleteState
    }


type DeleteState
    = DeleteIdle
    | DeleteConfirming
    | Deleting
    | DeleteFailed String


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
    ( Loading
        { mealId = mealId
        , units = fallbackUnits
        , nutrition = NutritionLoading defaultNutritionInput
        }
    , RequestInitialData mealId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded result ->
            case result of
                Ok meal ->
                    let
                        loaded : LoadedModel
                        loaded =
                            loadedFromMeal meal model
                    in
                    ( Loaded loaded, Cmd.none, requestProductNames (uniqueProductIds meal) )

                Err error ->
                    failure error model

        ProductDetailLoaded productId result ->
            case model of
                Loaded loaded ->
                    let
                        name : String
                        name =
                            case result of
                                Ok product ->
                                    product.name

                                Err _ ->
                                    "Unknown food"

                        nextLoaded : LoadedModel
                        nextLoaded =
                            { loaded
                                | productNames =
                                    ItemNameLookup.insertProduct
                                        productId
                                        name
                                        loaded.productNames
                            }
                    in
                    ( Loaded nextLoaded
                    , Cmd.none
                    , nextProductNameRequest productId nextLoaded
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( mapUnits (unitsOrFallback response.items) model, Cmd.none, NoOp )

                Err _ ->
                    ( mapUnits fallbackUnits model, Cmd.none, NoOp )

        AmountChanged value ->
            case model of
                Loaded loaded ->
                    requestNutritionFor
                        { loaded
                            | nutrition =
                                mapNutritionInput
                                    (\input -> { input | amount = value, unitOpen = False })
                                    loaded.nutrition
                        }

                _ ->
                    ( model, Cmd.none, NoOp )

        UnitChanged value ->
            case model of
                Loaded loaded ->
                    requestNutritionFor
                        { loaded
                            | nutrition =
                                mapNutritionInput
                                    (\input -> { input | unit = value, unitOpen = False })
                                    loaded.nutrition
                        }

                _ ->
                    ( model, Cmd.none, NoOp )

        ToggleUnitDropdown ->
            case model of
                Loaded loaded ->
                    ( Loaded
                        { loaded
                            | nutrition =
                                mapNutritionInput
                                    (\input -> { input | unitOpen = not input.unitOpen })
                                    loaded.nutrition
                        }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        NutrientPreviewLoaded result ->
            applyNutritionResult result model

        DeleteClicked ->
            case model of
                Loaded loaded ->
                    ( Loaded { loaded | delete = DeleteConfirming }, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CancelDeleteClicked ->
            case model of
                Loaded loaded ->
                    ( Loaded { loaded | delete = DeleteIdle }, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        ConfirmDeleteClicked ->
            case model of
                Loaded loaded ->
                    case loaded.delete of
                        DeleteConfirming ->
                            ( Loaded { loaded | delete = Deleting }
                            , Cmd.none
                            , RequestDeleteMeal loaded.mealId
                            )

                        DeleteFailed _ ->
                            ( Loaded { loaded | delete = Deleting }
                            , Cmd.none
                            , RequestDeleteMeal loaded.mealId
                            )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted result ->
            case model of
                Loaded loaded ->
                    if loaded.delete == Deleting then
                        case result of
                            Ok _ ->
                                ( model, Cmd.none, Navigate MealList )

                            Err error ->
                                Client.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyDeleteError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        EditClicked ->
            case model of
                Loaded loaded ->
                    ( model, Cmd.none, Navigate (MealEdit loaded.mealId) )

                _ ->
                    ( model, Cmd.none, NoOp )


uniqueProductIds : Meal -> List String
uniqueProductIds meal =
    meal.components
        |> List.filterMap
            (\component ->
                case component.item.itemType of
                    ItemRef.Product ->
                        Just component.item.id

                    ItemRef.Meal ->
                        Nothing
            )
        |> ItemNameLookup.uniqueProductIds


requestProductNames : List String -> OutMsg
requestProductNames ids =
    ItemNameLookup.nextMissingProductId Nothing ids ItemNameLookup.empty
        |> Maybe.map RequestProductDetail
        |> Maybe.withDefault NoOp


nextProductNameRequest : String -> LoadedModel -> OutMsg
nextProductNameRequest completedId loaded =
    uniqueProductIds loaded.meal
        |> (\ids ->
                ItemNameLookup.nextMissingProductId
                    (Just completedId)
                    ids
                    loaded.productNames
           )
        |> Maybe.map RequestProductDetail
        |> Maybe.withDefault NoOp


componentNameView : Theme -> LoadedModel -> String -> Element Msg
componentNameView theme loaded id =
    if ItemNameLookup.isLoaded (ItemNameLookup.productRef id) loaded.productNames then
        Ui.listItemTitle theme
            (Element.text
                (ItemNameLookup.nameFor "" (ItemNameLookup.productRef id) loaded.productNames)
            )

    else
        Ui.skeletonBar theme


requestNutritionFor : LoadedModel -> ( Model, Cmd Msg, OutMsg )
requestNutritionFor loaded =
    let
        input : NutritionInput
        input =
            nutritionInput loaded.nutrition
    in
    case String.toFloat input.amount of
        Just amount ->
            if amount > 0 then
                ( Loaded { loaded | nutrition = NutritionLoading input }
                , Cmd.none
                , RequestNutrientPreview loaded.mealId input.amount input.unit
                )

            else
                clearNutritionPreview loaded

        Nothing ->
            clearNutritionPreview loaded


clearNutritionPreview : LoadedModel -> ( Model, Cmd Msg, OutMsg )
clearNutritionPreview loaded =
    ( Loaded { loaded | nutrition = NutritionUnavailable (nutritionInput loaded.nutrition) }
    , Cmd.none
    , NoOp
    )


nutritionInput : NutritionState -> NutritionInput
nutritionInput =
    View.Nutrients.nutritionInput


mapNutritionInput : (NutritionInput -> NutritionInput) -> NutritionState -> NutritionState
mapNutritionInput =
    View.Nutrients.mapNutritionInput


loadedFromMeal : Meal -> Model -> LoadedModel
loadedFromMeal meal model =
    case model of
        Loading loading ->
            { mealId = loading.mealId
            , meal = meal
            , productNames = ItemNameLookup.empty
            , units = loading.units
            , nutrition = loading.nutrition
            , delete = DeleteIdle
            }

        Loaded loaded ->
            { loaded | meal = meal, productNames = ItemNameLookup.empty, delete = DeleteIdle }

        LoadFailed _ ->
            { mealId = meal.id
            , meal = meal
            , productNames = ItemNameLookup.empty
            , units = fallbackUnits
            , nutrition = NutritionLoading defaultNutritionInput
            , delete = DeleteIdle
            }


mapUnits : List UnitItem -> Model -> Model
mapUnits units model =
    case model of
        Loading loading ->
            Loading { loading | units = units }

        Loaded loaded ->
            Loaded { loaded | units = units }

        LoadFailed _ ->
            model


unitsOrFallback : List UnitItem -> List UnitItem
unitsOrFallback units =
    if List.isEmpty units then
        fallbackUnits

    else
        units


applyNutritionResult :
    Result Client.ApiError MealNutritionResponse
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
applyNutritionResult result model =
    case result of
        Ok response ->
            ( mapNutrition
                (\nutrition ->
                    let
                        input : NutritionInput
                        input =
                            nutritionInput nutrition
                    in
                    if
                        response.quantity.amount
                            == input.amount
                            && response.quantity.unit
                            == input.unit
                    then
                        NutritionLoaded input response.nutrients

                    else
                        nutrition
                )
                model
            , Cmd.none
            , NoOp
            )

        Err error ->
            Client.failure
                { noOp = NoOp
                , sessionExpired = SessionExpired
                , applyError =
                    \message current ->
                        mapNutrition
                            (\nutrition -> NutritionFailed (nutritionInput nutrition) message)
                            current
                }
                error
                model


mapNutrition : (NutritionState -> NutritionState) -> Model -> Model
mapNutrition transform model =
    case model of
        Loading loading ->
            Loading { loading | nutrition = transform loading.nutrition }

        Loaded loaded ->
            Loaded { loaded | nutrition = transform loaded.nutrition }

        LoadFailed _ ->
            model


applyDeleteError : String -> Model -> Model
applyDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | delete = DeleteFailed message }

        _ ->
            model


fallbackUnits : List UnitItem
fallbackUnits =
    [ { code = defaultCode, name = defaultCode, kind = "mass" } ]


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ Ui.section theme
            { header = Just (headerView theme device model)
            , body =
                [ case model of
                    Loaded loaded ->
                        case loaded.meal.notes of
                            Just notes ->
                                Ui.mutedParagraph theme notes

                            Nothing ->
                                Element.none

                    LoadFailed message ->
                        Ui.errorBanner theme message

                    Loading _ ->
                        Ui.skeletonLoading theme
                ]
            , footer = Nothing
            }
        , case model of
            Loaded loaded ->
                loadedView theme device loaded

            LoadFailed message ->
                Ui.errorBanner theme message

            Loading _ ->
                Ui.skeletonLoading theme
        ]


headerView : Theme -> Device -> Model -> Element Msg
headerView theme device model =
    case model of
        Loaded loaded ->
            Ui.pageHeader theme
                { leading =
                    loaded.meal.nutritionSummary
                        |> Maybe.map
                            (View.Nutrients.macroDot << Nutrition.summaryToNutrients)
                , title = Ui.truncatedHeader theme device loaded.meal.name
                , subtitle = Nothing
                , actions =
                    [ Ui.iconButton theme
                        { label = "✎", title = "Edit", onPress = EditClicked }
                    , Ui.dangerIconButton theme
                        { label = "×", title = "Delete", onPress = DeleteClicked }
                    ]
                }

        _ ->
            Ui.pageTitle theme "Meal"


loadedView : Theme -> Device -> LoadedModel -> Element Msg
loadedView theme device loaded =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space16 ]
        [ Ui.section theme
            { header = Just (Ui.subsectionTitle theme "Components")
            , body = List.map (componentView theme loaded) loaded.meal.components
            , footer = Nothing
            }
        , nutritionView theme device loaded
        , confirmDeleteView theme loaded
        ]


componentView : Theme -> LoadedModel -> MealsApi.MealComponent -> Element Msg
componentView theme loaded component =
    let
        summaryText : String
        summaryText =
            component.nutritionSummary
                |> Maybe.andThen .energyKcal
                |> Maybe.map
                    (\kcal ->
                        " ⋅ "
                            ++ String.fromInt (round (Nutrition.safeAmount kcal))
                            ++ " kcal"
                    )
                |> Maybe.withDefault ""

        macroDot : Element msg
        macroDot =
            Maybe.withDefault Element.none
                (Maybe.map
                    (View.Nutrients.macroDot << Nutrition.summaryToNutrients)
                    component.nutritionSummary
                )

        quantityText : String
        quantityText =
            component.quantity.amount
                ++ " "
                ++ component.quantity.unit
                ++ summaryText
    in
    Element.row
        [ Element.width Element.fill
        , Element.spacing Ui.space12
        ]
        [ Element.el
            [ Element.width (Element.px 12)
            , Element.paddingEach { top = 2, right = 0, bottom = 0, left = 0 }
            , Element.alignTop
            ]
            macroDot
        , Element.column
            [ Element.width Element.fill
            , Element.spacing Ui.space4
            , Element.alignTop
            ]
            [ componentNameView theme loaded component.item.id
            , Element.el
                [ Font.color theme.textMuted ]
                (Element.text quantityText)
            ]
        ]


nutritionView : Theme -> Device -> LoadedModel -> Element Msg
nutritionView theme device loaded =
    let
        input : NutritionInput
        input =
            nutritionInput loaded.nutrition
    in
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ Ui.card theme
            [ View.QuantityInput.dropdown theme
                { amountLabel = "Amount"
                , amount = input.amount
                , onAmountChange = AmountChanged
                , unitLabel = "Unit"
                , unit = input.unit
                , units = loaded.units
                , onUnitChange = UnitChanged
                , unitOpen = input.unitOpen
                , onUnitToggle = ToggleUnitDropdown
                }
            ]
        , View.Nutrients.preview theme device loaded.nutrition
        ]


confirmDeleteView : Theme -> LoadedModel -> Element Msg
confirmDeleteView theme loaded =
    case loaded.delete of
        DeleteConfirming ->
            confirmDeleteContent theme Nothing False

        Deleting ->
            confirmDeleteContent theme Nothing True

        DeleteFailed message ->
            confirmDeleteContent theme (Just message) False

        DeleteIdle ->
            Element.none


confirmDeleteContent : Theme -> Maybe String -> Bool -> Element Msg
confirmDeleteContent theme maybeError deleting =
    Element.column
        [ Element.spacing Ui.space8
        , Element.padding Ui.space12
        , Background.color theme.dangerBg
        , Border.rounded 16
        ]
        [ Ui.sectionTitle theme "Delete meal?"
        , Ui.maybeErrorBanner theme maybeError
        , Element.row [ Element.spacing Ui.space8 ]
            [ Ui.button theme "Cancel" CancelDeleteClicked
            , Ui.dangerButton theme
                (if deleting then
                    "Deleting..."

                 else
                    "Confirm Delete"
                )
                ConfirmDeleteClicked
            ]
        ]
