module Page.Food.Detail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , customFoodEditRoute
    , foodNutrientsForDisplay
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest)
import Api.Result as ApiResult
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Font as Font
import Ui
import View.FoodLogForm as FoodLogForm
import View.Nutrients


type alias Model =
    { productId : String
    , mealSlot : Maybe MealSlot
    , food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    , form : Maybe FoodLogForm.Model
    , error : Maybe String
    }


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | LocalTimestampReceived String
    | LogCompleted (Result Client.ApiError FoodLog)
    | EditCustomFoodClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestLocalTimestamp
    | RequestCreateLog CreateLogRequest
    | Navigate Route
    | SessionExpired


init : String -> Maybe MealSlot -> ( Model, OutMsg )
init productId mealSlot =
    ( { productId = productId
      , mealSlot = mealSlot
      , food = Nothing
      , units = Nothing
      , form = Nothing
      , error = Nothing
      }
    , RequestInitialData productId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded result ->
            case result of
                Ok food ->
                    ( { model
                        | food = Just food
                        , form = Just (FoodLogForm.initLogFormFromFood model.mealSlot food)
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = Just response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            case model.form of
                Just form ->
                    ( { model | form = Just (FoodLogForm.update subMsg form) }, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model.form of
                Just form ->
                    case FoodLogForm.createProductLogRequest "pending" model.productId form of
                        Ok _ ->
                            ( { model
                                | form = Just { form | submitting = True, error = Nothing }
                                , error = Nothing
                              }
                            , Cmd.none
                            , RequestLocalTimestamp
                            )

                        Err FoodLogForm.AmountRequired ->
                            ( { model | form = Just { form | error = Just "Amount is required." } }
                            , Cmd.none
                            , NoOp
                            )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        LocalTimestampReceived loggedAt ->
            case model.form of
                Just form ->
                    case FoodLogForm.createProductLogRequest loggedAt model.productId form of
                        Ok request ->
                            ( model, Cmd.none, RequestCreateLog request )

                        Err FoodLogForm.AmountRequired ->
                            ( { model
                                | form =
                                    Just
                                        { form
                                            | submitting = False
                                            , error = Just "Amount is required."
                                        }
                              }
                            , Cmd.none
                            , NoOp
                            )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        LogCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate (Diary Nothing) )

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

        EditCustomFoodClicked ->
            case Maybe.andThen customFoodEditRoute model.food of
                Just route ->
                    ( model, Cmd.none, Navigate route )

                Nothing ->
                    ( model, Cmd.none, NoOp )


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


customFoodEditRoute : ProductDetail -> Maybe Route
customFoodEditRoute food =
    if food.source == "USER" then
        Just (CustomFoodEdit food.id)

    else
        Nothing


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
    case ( model.food, model.units, model.form ) of
        ( Just food, Just units, Just form ) ->
            loadedView food units form

        _ ->
            if model.error /= Nothing then
                Element.none

            else
                Ui.loading "Loading food..."


loadedView : ProductDetail -> List UnitItem -> FoodLogForm.Model -> Element Msg
loadedView food units form =
    let
        nutrients : List Nutrition.NutrientAmount
        nutrients =
            foodNutrientsForDisplay food form
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ foodHeader food
        , Element.map FormMsg (FoodLogForm.view (Just food) units form)
        , Ui.cardActions
            [ Ui.submitButton form.submitting "Log Food" "Logging..." SubmitClicked
            ]
        , Ui.card
            [ Ui.sectionHeader "Macro Breakdown"
            , View.Nutrients.macroBreakdownView nutrients
            ]
        , View.Nutrients.nutrientsTable nutrients
        ]


foodNutrientsForDisplay : ProductDetail -> FoodLogForm.Model -> List Nutrition.NutrientAmount
foodNutrientsForDisplay food form =
    Nutrition.nutrientsForQuantity
        { amount = form.amount, unit = form.unit }
        food.servings
        food.nutrients
        |> Maybe.withDefault (foodNutrientsPer100g food)


foodNutrientsPer100g : ProductDetail -> List Nutrition.NutrientAmount
foodNutrientsPer100g food =
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amount = nutrient.amountPer100g
            , unit = nutrient.unit
            }
        )
        food.nutrients


foodHeader : ProductDetail -> Element Msg
foodHeader food =
    Ui.card
        [ Element.el [ Ui.heading2, Font.bold ] (Element.text food.name)
        , Ui.mutedText (metaText food)
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.spacing 4 ]
                (List.map Ui.badge food.categories)
        , case customFoodEditRoute food of
            Just _ ->
                Ui.button "Edit food" EditCustomFoodClicked

            Nothing ->
                Element.none
        ]


metaText : ProductDetail -> String
metaText food =
    [ food.brand
    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
    , if List.isEmpty food.categories then
        Nothing

      else
        Just (String.join ", " food.categories)
    ]
        |> List.filterMap identity
        |> String.join " - "
