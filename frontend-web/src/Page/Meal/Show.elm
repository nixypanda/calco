module Page.Meal.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , loadId
    , modalView
    , modelId
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
import Element exposing (Element)
import Element.Font as Font
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients exposing (NutritionInput, NutritionState(..), defaultNutritionInput)
import View.QuantityInput



-- MODEL


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



-- UPDATE


type Msg
    = MealLoaded String (Result Client.ApiError Meal)
    | ProductDetailLoaded String (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | AmountChanged String
    | UnitChanged String
    | ToggleUnitDropdown
    | NutrientPreviewLoaded String (Result Client.ApiError MealNutritionResponse)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditClicked


modelId : Model -> Maybe String
modelId model =
    case model of
        Loading loading ->
            Just loading.mealId

        Loaded loaded ->
            Just loaded.mealId

        LoadFailed _ ->
            Nothing


loadId : Msg -> Maybe String
loadId msg =
    case msg of
        MealLoaded mealId _ ->
            Just mealId

        NutrientPreviewLoaded mealId _ ->
            Just mealId

        _ ->
            Nothing


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded incomingId result ->
            if modelId model /= Just incomingId then
                ( model, Cmd.none, NoOp )

            else
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
                                    I18n.en TidMealUnknownFood

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

        NutrientPreviewLoaded incomingId result ->
            if modelId model /= Just incomingId then
                ( model, Cmd.none, NoOp )

            else
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
        Element.el
            [ Typography.body
            , Font.color theme.textPrimary
            ]
            (Element.text
                (ItemNameLookup.nameFor "" (ItemNameLookup.productRef id) loaded.productNames)
            )

    else
        Skeleton.bar theme


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



-- VIEW


view : { model : Model, env : Env } -> Element Msg
view { model, env } =
    UiPage.pageContainer
        (case model of
            Loaded loaded ->
                [ Surface.section env.theme
                    { header = Just (headerView env model)
                    , body =
                        [ case loaded.meal.notes of
                            Just notes ->
                                Typography.mutedParagraph env.theme notes

                            Nothing ->
                                Element.none
                        ]
                    , footer = Nothing
                    }
                , loadedView env loaded
                ]

            LoadFailed message ->
                [ Surface.section env.theme
                    { header = Just (headerView env model)
                    , body = [ Feedback.errorBanner env.theme message ]
                    , footer = Nothing
                    }
                ]

            Loading _ ->
                [ mealShowSkeleton env.theme ]
        )


modalView :
    { model : Model, env : Env }
    -> Maybe (Element Msg)
modalView { model, env } =
    case model of
        Loaded loaded ->
            deleteModalView env loaded

        _ ->
            Nothing


headerView : Env -> Model -> Element Msg
headerView env model =
    case model of
        Loaded loaded ->
            UiPage.pageHeader env.theme
                { leading =
                    loaded.meal.nutritionSummary
                        |> Maybe.map
                            (View.Nutrients.macroDot env << Nutrition.summaryToNutrients)
                , title = Typography.truncatedHeader env.theme loaded.meal.name
                , subtitle = Nothing
                , actions = []
                }

        _ ->
            Typography.truncatedHeader env.theme (I18n.t env.language TidTitleMeal)


loadedView : Env -> LoadedModel -> Element Msg
loadedView env loaded =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Surface.section env.theme
            { header =
                Just
                    (Typography.subsectionTitle env.theme
                        (I18n.t env.language TidMealComponents)
                    )
            , body =
                List.intersperse (Surface.hairline env.theme)
                    (List.map (componentView env loaded) loaded.meal.components)
            , footer = Nothing
            }
        , nutritionView env loaded
        , bottomActionsView env
        ]


componentView : Env -> LoadedModel -> MealsApi.MealComponent -> Element Msg
componentView env loaded component =
    let
        summaryText : String
        summaryText =
            component.nutritionSummary
                |> Maybe.andThen .energyKcal
                |> Maybe.map
                    (\kcal ->
                        " ⋅ "
                            ++ I18n.t env.language
                                (TidDiaryKcal
                                    (String.fromInt (round (Nutrition.safeAmount kcal)))
                                )
                    )
                |> Maybe.withDefault ""

        macroDot : Element msg
        macroDot =
            Maybe.withDefault Element.none
                (Maybe.map
                    (View.Nutrients.macroDot env << Nutrition.summaryToNutrients)
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
        , Element.spacing DesignTokens.space12
        ]
        [ Element.el
            [ Element.width (Element.px 12)
            , Element.paddingEach { top = DesignTokens.space2, right = 0, bottom = 0, left = 0 }
            , Element.alignTop
            ]
            macroDot
        , Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space4
            , Element.alignTop
            ]
            [ componentNameView env.theme loaded component.item.id
            , Element.el
                [ Font.color env.theme.textMuted ]
                (Element.text quantityText)
            ]
        ]


nutritionView : Env -> LoadedModel -> Element Msg
nutritionView env loaded =
    let
        input : NutritionInput
        input =
            nutritionInput loaded.nutrition
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Surface.formSection env.theme
            (I18n.t env.language TidFoodShowPortion)
            [ View.QuantityInput.dropdown env
                { amountLabel = I18n.t env.language TidNutrientTableAmount
                , amount = input.amount
                , onAmountChange = AmountChanged
                , unitLabel = I18n.t env.language TidNutrientTableUnit
                , unit = input.unit
                , units = loaded.units
                , onUnitChange = UnitChanged
                , unitOpen = input.unitOpen
                , onUnitToggle = ToggleUnitDropdown
                }
            ]
        , View.Nutrients.preview env loaded.nutrition
        ]


bottomActionsView : Env -> Element Msg
bottomActionsView env =
    Button.bottomActionButtons env.device
        env.theme
        [ { label = I18n.t env.language TidTitleEditMeal
          , onPress = EditClicked
          , tone = Button.Primary
          }
        , { label = I18n.t env.language TidMealDelete
          , onPress = DeleteClicked
          , tone = Button.Danger
          }
        ]


deleteModalView : Env -> LoadedModel -> Maybe (Element Msg)
deleteModalView env loaded =
    View.DeleteModal.deleteModalView env
        { title = I18n.t env.language TidMealDeleteConfirmTitle
        , description = I18n.t env.language TidMealDeleteConfirmDescription
        , confirmLabel = I18n.t env.language TidCustomFoodConfirmDelete
        , pendingLabel = I18n.t env.language TidCustomFoodDeleting
        , onCancel = CancelDeleteClicked
        , onConfirm = ConfirmDeleteClicked
        }
        loaded.delete


mealShowSkeleton : Theme -> Element msg
mealShowSkeleton theme =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.card theme { rows = 2 }
        , Surface.section theme
            { header =
                Just
                    (Skeleton.barCustom theme
                        { width = Element.fillPortion 1, height = 16 }
                    )
            , body = List.map (\_ -> Skeleton.listRow theme) (List.range 1 3)
            , footer = Nothing
            }
        , Skeleton.card theme { rows = 2 }
        , Skeleton.card theme { rows = 3 }
        , Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ Element.el [ Element.width Element.fill ] (Skeleton.button theme)
            , Element.el [ Element.width Element.fill ] (Skeleton.button theme)
            ]
        ]
