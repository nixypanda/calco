module Page.Meal.Detail exposing
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
import Api.Meals as Meals exposing (Meal, MealNutritionResponse)
import Api.Result as ApiResult
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition as Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Ui
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
                                ( model, Cmd.none, Navigate Meals )

                            Err error ->
                                ApiResult.failure
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


nameFor : String -> LoadedModel -> String
nameFor id loaded =
    ItemNameLookup.nameFor "Loading..." (ItemNameLookup.productRef id) loaded.productNames


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
            ApiResult.failure
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
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ headerView device model
        , case model of
            Loaded loaded ->
                loadedView device loaded

            LoadFailed message ->
                Ui.errorBanner message

            Loading _ ->
                Ui.loading "Loading meal..."
        ]


headerView : Device -> Model -> Element Msg
headerView device model =
    case model of
        Loaded loaded ->
            Element.wrappedRow [ Element.width Element.fill, Element.spacing 16 ]
                [ Ui.truncatedHeader device loaded.meal.name
                , Ui.iconButton { label = "✎", title = "Edit", onPress = EditClicked }
                , Ui.dangerIconButton { label = "×", title = "Delete", onPress = DeleteClicked }
                ]

        _ ->
            Element.el [ Ui.heading1, Font.bold ] (Element.text "Meal")


loadedView : Device -> LoadedModel -> Element Msg
loadedView device loaded =
    Element.column [ Element.width Element.fill, Element.spacing 16 ]
        [ case loaded.meal.notes of
            Just notes ->
                Ui.mutedParagraph notes

            Nothing ->
                Element.none
        , case loaded.meal.nutritionSummary of
            Just summary ->
                let
                    summaryNutrients : List Nutrition.NutrientAmount
                    summaryNutrients =
                        Nutrition.summaryToNutrients summary
                in
                Ui.card
                    [ Ui.sectionHeader "Macro Breakdown"
                    , View.Nutrients.macroBreakdownView device summaryNutrients
                    ]

            Nothing ->
                Element.none
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 8 ]
            (List.map (componentView loaded) loaded.meal.components)
        , nutritionView device loaded
        , confirmDeleteView loaded
        ]


componentView : LoadedModel -> Meals.MealComponent -> Element Msg
componentView loaded component =
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

        macroAccent : Maybe Element.Color
        macroAccent =
            component.nutritionSummary
                |> Maybe.map Nutrition.summaryToNutrients
                |> Maybe.andThen Nutrition.dominantMacro
                |> Maybe.map Ui.macroColor

        dot : List (Element Msg)
        dot =
            case macroAccent of
                Just c ->
                    [ Ui.accentDot c ]

                Nothing ->
                    []

        compactBar : Element Msg
        compactBar =
            case component.nutritionSummary of
                Just summary ->
                    View.Nutrients.macroBreakdownCompact (Nutrition.summaryToNutrients summary)

                Nothing ->
                    Element.none

        quantityText : String
        quantityText =
            component.quantity.amount
                ++ " "
                ++ component.quantity.unit
                ++ summaryText
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing 8
        , Element.padding 14
        , Background.color Ui.cardBg
        , Border.rounded 16
        , Ui.cardShadow
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing 12
            ]
            (dot
                ++ [ Element.el [ Font.bold ] (Element.text (nameFor component.item.id loaded))
                   , Element.el
                        [ Font.color Ui.mutedColor ]
                        (Element.text quantityText)
                   ]
            )
        , compactBar
        ]


nutritionView : Device -> LoadedModel -> Element Msg
nutritionView device loaded =
    let
        input : NutritionInput
        input =
            nutritionInput loaded.nutrition
    in
    Element.column [ Element.width Element.fill, Element.spacing 10 ]
        [ Ui.sectionHeader "Nutrition"
        , Ui.card
            [ View.QuantityInput.dropdown
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
        , View.Nutrients.preview device loaded.nutrition
        ]


confirmDeleteView : LoadedModel -> Element Msg
confirmDeleteView loaded =
    case loaded.delete of
        DeleteConfirming ->
            confirmDeleteContent Nothing False

        Deleting ->
            confirmDeleteContent Nothing True

        DeleteFailed message ->
            confirmDeleteContent (Just message) False

        DeleteIdle ->
            Element.none


confirmDeleteContent : Maybe String -> Bool -> Element Msg
confirmDeleteContent maybeError deleting =
    Element.column
        [ Element.spacing 8
        , Element.padding 12
        , Background.color Ui.dangerBg
        , Border.rounded 16
        ]
        [ Element.el [ Font.bold ] (Element.text "Delete meal?")
        , case maybeError of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , Element.row [ Element.spacing 8 ]
            [ Ui.button "Cancel" CancelDeleteClicked
            , Ui.dangerButton
                (if deleting then
                    "Deleting..."

                 else
                    "Confirm Delete"
                )
                ConfirmDeleteClicked
            ]
        ]
