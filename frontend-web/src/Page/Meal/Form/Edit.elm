module Page.Meal.Form.Edit exposing
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
import Api.Result as ApiResult
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition exposing (NutrientAmount, defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Page.Meal.Form.Common as Common
import Ui
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
                    ApiResult.failure
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
                    ApiResult.failure
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
                                    | fields = setSubmitting loaded.fields True
                                }
                            , Cmd.none
                            , RequestUpdateMeal loaded.mealId request
                            )

                        Err Common.MealNameRequired ->
                            ( Editing
                                { loaded
                                    | fields = setError loaded.fields "Name is required"
                                }
                            , Cmd.none
                            , NoOp
                            )

                        Err Common.ComponentRequired ->
                            ( Editing
                                { loaded
                                    | fields =
                                        setError
                                            loaded.fields
                                            componentRequiredMessage
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
                                    | fields = setSubmitting loaded.fields False
                                    , meal = meal
                                }
                            , Cmd.none
                            , Navigate (MealDetail meal.id)
                            )

                        Err error ->
                            let
                                ( newLoaded, _, outMsg ) =
                                    ApiResult.failure
                                        { noOp = NoOp
                                        , sessionExpired = SessionExpired
                                        , applyError =
                                            \message current ->
                                                { current
                                                    | fields = setSaveError current.fields message
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


setSubmitting : Common.FormFields -> Bool -> Common.FormFields
setSubmitting fields value =
    { fields | submitting = value, error = Nothing }


setError : Common.FormFields -> String -> Common.FormFields
setError fields message =
    { fields | error = Just message, submitting = False }


setSaveError : Common.FormFields -> String -> Common.FormFields
setSaveError fields message =
    { fields | error = Just message, submitting = False }


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
    , submitting = False
    , error = Nothing
    }


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


view : Model -> Element Msg
view model =
    case model of
        LoadingEdit _ ->
            Ui.pageContainer [ Ui.loading "Loading meal..." ]

        EditLoadFailed message ->
            Ui.pageContainer [ Ui.errorBanner message ]

        Editing loaded ->
            Ui.pageContainer
                [ Common.errorView loaded.fields
                , Common.viewFormFields FormMsg loaded.fields
                , nutritionView loaded
                , Ui.submitButton loaded.fields.submitting
                    "Update Meal"
                    "Saving..."
                    SubmitClicked
                ]


nutritionView : LoadedModel -> Element Msg
nutritionView loaded =
    Element.column [ Element.width Element.fill, Element.spacing 10 ]
        [ Ui.sectionHeader "Nutrition"
        , View.Nutrients.preview loaded.nutrition
        ]
