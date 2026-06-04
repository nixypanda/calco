module Page.FoodLog.Detail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , nutrientsForDisplay
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (UpdateLogRequest)
import Api.Meals exposing (MealName)
import Api.Result as ApiResult
import Data.FoodLog exposing (FoodLog)
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Font as Font
import Page.Food.Detail
import Ui
import View.FoodLogForm as FoodLogForm
import View.Nutrients


type alias Model =
    { logId : String
    , log : Maybe FoodLog
    , food : Maybe ProductDetail
    , itemNames : ItemNameLookup.Names
    , units : Maybe (List UnitItem)
    , form : Maybe FoodLogForm.Model
    , error : Maybe String
    , deleting : Bool
    }


type Msg
    = LogLoaded (Result Client.ApiError FoodLog)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | ProductDetailLoaded (Result Client.ApiError ProductDetail)
    | MealNameLoaded (Result Client.ApiError MealName)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | UpdateCompleted (Result Client.ApiError FoodLog)
    | DeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditCustomFoodClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestMealName String
    | RequestUpdateLog String UpdateLogRequest
    | RequestDeleteLog String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init logId =
    ( { logId = logId
      , log = Nothing
      , food = Nothing
      , itemNames = ItemNameLookup.empty
      , units = Nothing
      , form = Nothing
      , error = Nothing
      , deleting = False
      }
    , RequestInitialData logId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LogLoaded result ->
            case result of
                Ok log ->
                    ( { model
                        | log = Just log
                        , form = Just (FoodLogForm.initLogFormFromLog log)
                        , error = Nothing
                      }
                    , Cmd.none
                    , itemResolutionOutMsg log
                    )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = Just response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        ProductDetailLoaded result ->
            case result of
                Ok food ->
                    ( { model
                        | food = Just food
                        , itemNames =
                            ItemNameLookup.insertProduct food.id food.name model.itemNames
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err _ ->
                    ( { model | itemNames = insertCurrentItemFallback model }
                    , Cmd.none
                    , NoOp
                    )

        MealNameLoaded result ->
            case result of
                Ok meal ->
                    ( { model
                        | itemNames =
                            ItemNameLookup.insert
                                { itemType = "meal", id = meal.id }
                                meal.name
                                model.itemNames
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err _ ->
                    ( { model | itemNames = insertCurrentItemFallback model }
                    , Cmd.none
                    , NoOp
                    )

        FormMsg subMsg ->
            case model.form of
                Just form ->
                    ( { model | form = Just (FoodLogForm.update subMsg form) }, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model.form of
                Just form ->
                    case FoodLogForm.createUpdateLogRequest form of
                        Ok request ->
                            ( { model
                                | form = Just { form | submitting = True, error = Nothing }
                                , error = Nothing
                              }
                            , Cmd.none
                            , RequestUpdateLog model.logId request
                            )

                        Err FoodLogForm.AmountRequired ->
                            ( { model | form = Just { form | error = Just "Amount is required." } }
                            , Cmd.none
                            , NoOp
                            )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        UpdateCompleted result ->
            case result of
                Ok log ->
                    ( { model
                        | log = Just log
                        , form = Just (FoodLogForm.initLogFormFromLog log)
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                setFormSubmitting False { current | error = Just message }
                        }
                        error
                        model

        DeleteClicked ->
            ( { model | deleting = True, error = Nothing }, Cmd.none, RequestDeleteLog model.logId )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate (Diary Nothing) )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current | deleting = False, error = Just message }
                        }
                        error
                        model

        EditCustomFoodClicked ->
            case Maybe.andThen Page.Food.Detail.customFoodEditRoute model.food of
                Just route ->
                    ( model, Cmd.none, Navigate route )

                Nothing ->
                    ( model, Cmd.none, NoOp )


itemResolutionOutMsg : FoodLog -> OutMsg
itemResolutionOutMsg log =
    case log.item.itemType of
        "product" ->
            RequestProductDetail log.item.id

        "meal" ->
            RequestMealName log.item.id

        _ ->
            NoOp


insertCurrentItemFallback : Model -> ItemNameLookup.Names
insertCurrentItemFallback model =
    case model.log of
        Just log ->
            ItemNameLookup.insertResult log.item (Err ()) model.itemNames

        Nothing ->
            model.itemNames


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | error = Just message }
        }


setFormSubmitting : Bool -> Model -> Model
setFormSubmitting submitting model =
    case model.form of
        Just form ->
            { model | form = Just { form | submitting = submitting } }

        Nothing ->
            model


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , bodyView model
        ]


bodyView : Model -> Element Msg
bodyView model =
    case ( model.log, model.units, model.form ) of
        ( Just log, Just units, Just form ) ->
            loadedView model log units form

        _ ->
            if model.error /= Nothing then
                Element.none

            else
                Ui.loading "Loading log..."


loadedView : Model -> FoodLog -> List UnitItem -> FoodLogForm.Model -> Element Msg
loadedView model log units form =
    let
        nutrients : List Nutrition.NutrientAmount
        nutrients =
            nutrientsForDisplay model.food log form
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ itemHeader model log
        , Element.map FormMsg (FoodLogForm.view model.food units form)
        , Ui.cardActions
            [ Ui.submitButton form.submitting "Save" "Saving..." SubmitClicked
            , Ui.dangerButton
                (if model.deleting then
                    "Deleting..."

                 else
                    "Delete"
                )
                DeleteClicked
            ]
        , Ui.card
            [ Ui.sectionHeader "Macro Breakdown"
            , View.Nutrients.macroBreakdownView nutrients
            ]
        , View.Nutrients.nutrientsTable nutrients
        ]


nutrientsForDisplay :
    Maybe ProductDetail
    -> FoodLog
    -> FoodLogForm.Model
    -> List Nutrition.NutrientAmount
nutrientsForDisplay maybeFood log form =
    let
        currentQuantity : { amount : String, unit : String }
        currentQuantity =
            { amount = form.amount, unit = form.unit }

        savedSnapshot : List Nutrition.NutrientAmount
        savedSnapshot =
            Nutrition.scaledSnapshotForQuantity
                log.quantity
                currentQuantity
                log.nutrients
                |> Maybe.withDefault log.nutrients
    in
    case maybeFood of
        Just food ->
            Nutrition.nutrientsForQuantity
                currentQuantity
                food.servings
                food.nutrients
                |> Maybe.withDefault savedSnapshot

        Nothing ->
            savedSnapshot


itemHeader : Model -> FoodLog -> Element Msg
itemHeader model log =
    Ui.card
        [ Element.el [ Ui.heading2, Font.bold ] (Element.text (itemTitle model log))
        , Ui.mutedText (metaText model.food log)
        , case model.food of
            Just food ->
                if List.isEmpty food.categories then
                    Element.none

                else
                    Element.row [ Element.spacing 4 ]
                        (List.map Ui.badge food.categories)

            Nothing ->
                Element.none
        , case Maybe.andThen Page.Food.Detail.customFoodEditRoute model.food of
            Just _ ->
                Ui.button "Edit food" EditCustomFoodClicked

            Nothing ->
                Element.none
        ]


itemTitle : Model -> FoodLog -> String
itemTitle model log =
    ItemNameLookup.nameFor (loadingName log.item.itemType) log.item model.itemNames


loadingName : String -> String
loadingName itemType =
    case itemType of
        "meal" ->
            "Loading meal..."

        "product" ->
            "Loading food..."

        _ ->
            "Unknown item"


metaText : Maybe ProductDetail -> FoodLog -> String
metaText maybeFood log =
    case maybeFood of
        Just food ->
            [ food.brand
            , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
            , Just ("Logged " ++ log.loggedAt)
            ]
                |> List.filterMap identity
                |> String.join " - "

        Nothing ->
            "Logged " ++ log.loggedAt
