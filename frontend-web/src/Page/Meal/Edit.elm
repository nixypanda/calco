module Page.Meal.Edit exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , loadId
    , modelId
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (UnitItem)
import Api.Meals exposing (CreateMealRequest, Meal, MealNutritionResponse)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Nutrition exposing (NutrientAmount, defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)
import View.Nutrients
    exposing
        ( NutritionState(..)
        , defaultNutritionInput
        , nutritionInput
        )



-- MODEL


type alias LoadingModel =
    { mealId : String, nutrition : NutritionState, units : List UnitItem }


type alias LoadedModel =
    { mealId : String, meal : Meal, fields : Common.FormFields, nutrition : NutritionState }


type Model
    = LoadingEdit LoadingModel
    | EditLoadFailed { mealId : String, message : String }
    | Editing LoadedModel


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
        { mealId = mealId, nutrition = NutritionLoading defaultNutritionInput, units = [] }
    , RequestMeal mealId
    )



-- UPDATE


type Msg
    = FormMsg Common.FormFieldMsg
    | MealLoaded String (Result Client.ApiError Meal)
    | NutrientPreviewLoaded String (Result Client.ApiError MealNutritionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)
    | RetryClicked
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)


modelId : Model -> String
modelId model =
    case model of
        LoadingEdit loading ->
            loading.mealId

        EditLoadFailed failed ->
            failed.mealId

        Editing loaded ->
            loaded.mealId


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

        MealLoaded incomingId result ->
            if modelId model /= incomingId then
                ( model, Cmd.none, NoOp )

            else
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
                        ( Editing loaded, Cmd.none, requestFirstProductName meal )

                    Err error ->
                        Client.failure
                            { noOp = NoOp
                            , sessionExpired = SessionExpired
                            , applyError =
                                \message current ->
                                    case current of
                                        LoadingEdit loading ->
                                            EditLoadFailed
                                                { mealId = loading.mealId, message = message }

                                        Editing loaded ->
                                            EditLoadFailed
                                                { mealId = loaded.mealId, message = message }

                                        EditLoadFailed _ ->
                                            current
                            }
                            error
                            model

        NutrientPreviewLoaded incomingId result ->
            if modelId model /= incomingId then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( applyNutritionOk response.nutrients model, Cmd.none, NoOp )

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
                                { loaded | fields = withSubmit Common.Submitting loaded.fields }
                            , Cmd.none
                            , RequestUpdateMeal loaded.mealId request
                            )

                        Err Common.MealNameRequired ->
                            ( Editing
                                { loaded
                                    | fields =
                                        withSubmit
                                            (Common.SubmitFailed
                                                (I18n.en TidCustomFoodNameRequired)
                                            )
                                            loaded.fields
                                }
                            , Cmd.none
                            , NoOp
                            )

                        Err Common.ComponentRequired ->
                            ( Editing
                                { loaded
                                    | fields =
                                        withSubmit (Common.SubmitFailed componentRequiredMessage)
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
                                                        withSubmit (Common.SubmitFailed message)
                                                            current.fields
                                                }
                                        }
                                        error
                                        loaded
                            in
                            ( Editing newLoaded, Cmd.none, outMsg )

                _ ->
                    ( model, Cmd.none, NoOp )

        RetryClicked ->
            case model of
                EditLoadFailed failed ->
                    ( LoadingEdit
                        { mealId = failed.mealId
                        , nutrition = NutritionLoading defaultNutritionInput
                        , units = []
                        }
                    , Cmd.none
                    , RequestMeal failed.mealId
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( setUnits response.items model, Cmd.none, NoOp )

                Err _ ->
                    ( model, Cmd.none, NoOp )


setUnits : List UnitItem -> Model -> Model
setUnits units model =
    case model of
        LoadingEdit loading ->
            LoadingEdit { loading | units = units }

        Editing loaded ->
            let
                fields : Common.FormFields
                fields =
                    loaded.fields
            in
            Editing { loaded | fields = { fields | units = units } }

        EditLoadFailed _ ->
            model


withSubmit : Common.SubmitState -> Common.FormFields -> Common.FormFields
withSubmit state fields =
    { fields | submit = state }


componentRequiredMessage : String
componentRequiredMessage =
    I18n.en TidMealComponentRequired


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
    let
        fields : Common.FormFields
        fields =
            editFormFromMeal meal
    in
    { mealId = loading.mealId
    , meal = meal
    , fields = { fields | units = loading.units }
    , nutrition = loading.nutrition
    }


loadedFromMealFresh : Meal -> LoadedModel
loadedFromMealFresh meal =
    { mealId = meal.id
    , meal = meal
    , fields = editFormFromMeal meal
    , nutrition = NutritionLoading defaultNutritionInput
    }


editFormFromMeal : Meal -> Common.FormFields
editFormFromMeal meal =
    let
        empty : Common.FormFields
        empty =
            Common.emptyFormFields

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
    { empty
        | name = meal.name
        , notes = Maybe.withDefault "" meal.notes
        , totalQuantity =
            Maybe.map .amount meal.totalQuantity |> Maybe.withDefault ""
        , totalUnit =
            Maybe.map .unit meal.totalQuantity |> Maybe.withDefault defaultCode
        , components =
            if List.isEmpty rows then
                empty.components

            else
                rows
        , nextRowId = List.length rows + 1
    }


requestFirstProductName : Meal -> OutMsg
requestFirstProductName meal =
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
        |> List.head
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



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    case model of
        LoadingEdit _ ->
            UiPage.pageContainer [ mealEditSkeleton env.theme ]

        EditLoadFailed failed ->
            UiPage.pageContainer
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = failed.message, onRetry = RetryClicked }
                ]

        Editing loaded ->
            UiPage.pageContainer
                [ Common.submitErrorBanner env.theme loaded.fields.submit
                , Common.viewFormFields env FormMsg loaded.fields
                , nutritionView env loaded
                , Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidMealUpdate
                    , onPress = SubmitClicked
                    , submitState =
                        Just (Button.submittingOrIdle (Common.isSubmitting loaded.fields.submit))
                    , submittingLabel = Just (I18n.t env.language TidCommonSaving)
                    , trailing = Nothing
                    }
                ]


nutritionView : Env -> LoadedModel -> Element Msg
nutritionView env loaded =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ View.Nutrients.preview env loaded.nutrition ]


mealEditSkeleton : Theme -> Element msg
mealEditSkeleton theme =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.card theme { rows = 3 }
        , Skeleton.button theme
        ]
