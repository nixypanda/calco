module Page.FoodLogDetail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (UpdateLogRequest)
import Api.Meals exposing (MealName)
import Data.FoodLog exposing (FoodLog)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Page.FoodDetail
import Page.FoodLogForm as FoodLogForm
import Route exposing (Route(..))
import Ui


type alias Model =
    { logId : String
    , log : Maybe FoodLog
    , food : Maybe ProductDetail
    , itemName : String
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
    | BackClicked
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
      , itemName = ""
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
                    ( { model | food = Just food, itemName = food.name }, Cmd.none, NoOp )

                Err _ ->
                    ( { model | itemName = "Unknown food" }, Cmd.none, NoOp )

        MealNameLoaded result ->
            case result of
                Ok meal ->
                    ( { model | itemName = meal.name }, Cmd.none, NoOp )

                Err _ ->
                    ( { model | itemName = "Unknown meal" }, Cmd.none, NoOp )

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
                    if Client.isUnauthorized error then
                        ( setFormSubmitting
                            False
                            { model | error = Just (Client.displayError error) }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( setFormSubmitting
                            False
                            { model | error = Just (Client.displayError error) }
                        , Cmd.none
                        , NoOp
                        )

        DeleteClicked ->
            ( { model | deleting = True, error = Nothing }, Cmd.none, RequestDeleteLog model.logId )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate (Diary Nothing) )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | deleting = False
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | deleting = False
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        BackClicked ->
            ( model, Cmd.none, Navigate (Diary Nothing) )

        EditCustomFoodClicked ->
            case Maybe.andThen Page.FoodDetail.customFoodEditRoute model.food of
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


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


setFormSubmitting : Bool -> Model -> Model
setFormSubmitting submitting model =
    case model.form of
        Just form ->
            { model | form = Just { form | submitting = submitting } }

        Nothing ->
            model


view : Model -> Element Msg
view model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        , Element.padding 24
        ]
        [ Element.row [ Element.width Element.fill, Element.spacing 12 ]
            [ Ui.button "Back" BackClicked
            , Element.el [ Font.size 22, Font.bold ] (Element.text "Edit Log")
            ]
        , case model.error of
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
                Element.el
                    [ Font.color (Element.rgb255 107 114 128) ]
                    (Element.text "Loading log...")


loadedView : Model -> FoodLog -> List UnitItem -> FoodLogForm.Model -> Element Msg
loadedView model log units form =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ itemHeader model log
        , Element.map FormMsg (FoodLogForm.view model.food units form)
        , Element.row [ Element.spacing 12 ]
            [ Ui.button
                (if form.submitting then
                    "Saving..."

                 else
                    "Save"
                )
                SubmitClicked
            , Ui.button
                (if model.deleting then
                    "Deleting..."

                 else
                    "Delete"
                )
                DeleteClicked
            ]
        ]


itemHeader : Model -> FoodLog -> Element Msg
itemHeader model log =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 8
        , Element.padding 16
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Element.el [ Font.size 20, Font.bold ] (Element.text (itemTitle model log))
        , Element.el
            [ Font.size 14
            , Font.color (Element.rgb255 107 114 128)
            ]
            (Element.text (metaText model.food log))
        , case Maybe.andThen Page.FoodDetail.customFoodEditRoute model.food of
            Just _ ->
                Ui.button "Edit food" EditCustomFoodClicked

            Nothing ->
                Element.none
        ]


itemTitle : Model -> FoodLog -> String
itemTitle model log =
    if String.isEmpty model.itemName then
        case log.item.itemType of
            "meal" ->
                "Loading meal..."

            "product" ->
                "Loading food..."

            _ ->
                "Unknown item"

    else
        model.itemName


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
