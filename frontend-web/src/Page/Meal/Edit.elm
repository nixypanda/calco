module Page.Meal.Edit exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Meals exposing (CreateMealRequest, Meal, MealNutritionResponse)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef
import Data.Nutrition exposing (NutrientAmount, defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Page.Meal.Form as Common
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients
    exposing
        ( NutritionState(..)
        , defaultNutritionInput
        , nutritionInput
        )


type alias LoadingModel =
    { mealId : String
    , nutrition : NutritionState
    }


type alias LoadedModel =
    { mealId : String
    , meal : Meal
    , fields : Common.FormFields
    , productNames : ItemNameLookup.Names
    , nutrition : NutritionState
    }


type Model
    = LoadingEdit LoadingModel
    | EditLoadFailed String
    | Editing LoadedModel


type Msg
    = FormMsg Common.FormFieldMsg
    | MealLoaded (Result Client.ApiError Meal)
    | NutrientPreviewLoaded (Result Client.ApiError MealNutritionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)


type OutMsg
    = NoOp
    | FormOutMsg Common.FormFieldOutMsg
    | RequestMeal String
    | RequestUpdateMeal String CreateMealRequest
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init mealId =
    ( LoadingEdit
        { mealId = mealId
        , nutrition = NutritionLoading defaultNutritionInput
        }
    , RequestMeal mealId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FormMsg formMsg ->
            case model of
                Editing loaded ->
                    let
                        ( nextFields, cmd, formOutMsg ) =
                            Common.updateFormField formMsg loaded.fields
                    in
                    ( Editing { loaded | fields = nextFields }
                    , Cmd.map FormMsg cmd
                    , mapFormOutMsg formOutMsg
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        MealLoaded result ->
            case result of
                Ok meal ->
                    let
                        loaded : LoadedModel
                        loaded =
                            case model of
                                LoadingEdit loading ->
                                    loadedFromMeal meal loading

                                _ ->
                                    loadedFromMealFresh meal
                    in
                    ( Editing loaded
                    , Cmd.none
                    , requestProductNames (uniqueProductIds meal)
                    )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message _ -> EditLoadFailed message
                        }
                        error
                        model

        NutrientPreviewLoaded result ->
            case result of
                Ok response ->
                    ( applyNutritionOk response.nutrients model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message current -> applyNutritionError message current
                        }
                        error
                        model

        SubmitClicked ->
            case model of
                Editing loaded ->
                    case Common.toMealRequest loaded.fields of
                        Ok request ->
                            ( Editing
                                { loaded
                                    | fields = withSubmit Common.Submitting loaded.fields
                                }
                            , Cmd.none
                            , RequestUpdateMeal loaded.mealId request
                            )

                        Err Common.MealNameRequired ->
                            ( Editing
                                { loaded
                                    | fields =
                                        withSubmit
                                            (Common.SubmitFailed "Name is required")
                                            loaded.fields
                                }
                            , Cmd.none
                            , NoOp
                            )

                        Err Common.ComponentRequired ->
                            ( Editing
                                { loaded
                                    | fields =
                                        withSubmit
                                            (Common.SubmitFailed componentRequiredMessage)
                                            loaded.fields
                                }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case model of
                Editing loaded ->
                    case result of
                        Ok meal ->
                            ( Editing
                                { loaded
                                    | fields = withSubmit Common.Idle loaded.fields
                                    , meal = meal
                                }
                            , Cmd.none
                            , Navigate (MealShow meal.id)
                            )

                        Err error ->
                            let
                                ( newLoaded, _, outMsg ) =
                                    Client.failure
                                        { noOp = NoOp
                                        , sessionExpired = SessionExpired
                                        , applyError =
                                            \message current ->
                                                { current
                                                    | fields =
                                                        withSubmit
                                                            (Common.SubmitFailed message)
                                                            current.fields
                                                }
                                        }
                                        error
                                        loaded
                            in
                            ( Editing newLoaded
                            , Cmd.none
                            , outMsg
                            )

                _ ->
                    ( model, Cmd.none, NoOp )


withSubmit : Common.SubmitState -> Common.FormFields -> Common.FormFields
withSubmit state fields =
    { fields | submit = state }


componentRequiredMessage : String
componentRequiredMessage =
    "At least one component with a selected product is required"


applyNutritionOk : List NutrientAmount -> Model -> Model
applyNutritionOk nutrients model =
    case model of
        Editing loaded ->
            Editing
                { loaded
                    | nutrition =
                        NutritionLoaded (nutritionInput loaded.nutrition) nutrients
                }

        LoadingEdit loading ->
            LoadingEdit
                { loading
                    | nutrition =
                        NutritionLoaded (nutritionInput loading.nutrition) nutrients
                }

        EditLoadFailed _ ->
            model


applyNutritionError : String -> Model -> Model
applyNutritionError message model =
    case model of
        Editing loaded ->
            Editing
                { loaded
                    | nutrition =
                        NutritionFailed (nutritionInput loaded.nutrition) message
                }

        LoadingEdit loading ->
            LoadingEdit
                { loading
                    | nutrition =
                        NutritionFailed (nutritionInput loading.nutrition) message
                }

        EditLoadFailed _ ->
            model


loadedFromMeal : Meal -> LoadingModel -> LoadedModel
loadedFromMeal meal loading =
    { mealId = loading.mealId
    , meal = meal
    , fields = editFormFromMeal meal
    , productNames = ItemNameLookup.empty
    , nutrition = loading.nutrition
    }


loadedFromMealFresh : Meal -> LoadedModel
loadedFromMealFresh meal =
    { mealId = meal.id
    , meal = meal
    , fields = editFormFromMeal meal
    , productNames = ItemNameLookup.empty
    , nutrition = NutritionLoading defaultNutritionInput
    }


editFormFromMeal : Meal -> Common.FormFields
editFormFromMeal meal =
    let
        rows : List Common.ComponentRow
        rows =
            List.indexedMap
                (\index component ->
                    let
                        row : Common.ComponentRow
                        row =
                            Common.emptyComponentRow (index + 1)
                    in
                    { row
                        | productId = component.item.id
                        , quantity = component.quantity.amount
                        , unit = component.quantity.unit
                    }
                )
                meal.components
    in
    { name = meal.name
    , notes = Maybe.withDefault "" meal.notes
    , totalQuantity =
        Maybe.map .amount meal.totalQuantity
            |> Maybe.withDefault ""
    , totalUnit =
        Maybe.map .unit meal.totalQuantity
            |> Maybe.withDefault defaultCode
    , components =
        if List.isEmpty rows then
            [ Common.emptyComponentRow 1 ]

        else
            rows
    , productNames = ItemNameLookup.empty
    , nextRowId = List.length rows + 1
    , nextSearchToken = 1
    , submit = Common.Idle
    }


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
        |> List.filter (String.trim >> String.isEmpty >> not)
        |> ItemNameLookup.uniqueProductIds


requestProductNames : List String -> OutMsg
requestProductNames ids =
    ItemNameLookup.nextMissingProductId Nothing ids ItemNameLookup.empty
        |> Maybe.map (FormOutMsg << Common.RequestProductName)
        |> Maybe.withDefault NoOp


mapFormOutMsg : Maybe Common.FormFieldOutMsg -> OutMsg
mapFormOutMsg maybeOutMsg =
    case maybeOutMsg of
        Nothing ->
            NoOp

        Just (Common.RequestProductName productId) ->
            FormOutMsg (Common.RequestProductName productId)

        Just (Common.RequestProductSearch rowId token request) ->
            FormOutMsg (Common.RequestProductSearch rowId token request)

        Just (Common.RequestCategorySuggestions rowId token request) ->
            FormOutMsg (Common.RequestCategorySuggestions rowId token request)

        Just (Common.RequestProductAndCats requests) ->
            FormOutMsg (Common.RequestProductAndCats requests)

        Just Common.FormSessionExpired ->
            SessionExpired


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    case model of
        LoadingEdit _ ->
            Ui.pageContainer device [ Ui.skeletonLoading theme ]

        EditLoadFailed message ->
            Ui.pageContainer device [ Ui.errorBanner theme message ]

        Editing loaded ->
            Ui.pageContainer device
                [ Ui.maybeErrorBanner theme (Common.submitErrorMessage loaded.fields.submit)
                , Common.viewFormFields theme device FormMsg loaded.fields
                , nutritionView theme device loaded
                , Ui.primarySubmitButton theme
                    { state = Ui.submittingOrIdle (Common.isSubmitting loaded.fields.submit)
                    , idleLabel = "Update Meal"
                    , submittingLabel = "Saving..."
                    , onPress = SubmitClicked
                    }
                ]


nutritionView : Theme -> Device -> LoadedModel -> Element Msg
nutritionView theme device loaded =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ View.Nutrients.preview theme device loaded.nutrition
        ]
