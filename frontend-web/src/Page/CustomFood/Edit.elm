module Page.CustomFood.Edit exposing (Model, Msg(..), OutMsg(..), init, update, view)

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , ProductDetail
        , UnitItem
        )
import Element exposing (Element)
import Page.CustomFood.Form as Form
import Route exposing (Route(..))
import Ui


type alias Model =
    { productId : String
    , form : Maybe Form.FormModel
    , nutrients : List NutrientItem
    , units : List UnitItem
    , error : Maybe String
    }


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)
    | BackClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestUpdateFood String CreateFoodRequest
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( { productId = productId, form = Nothing, nutrients = [], units = [], error = Nothing }
    , RequestInitialData productId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded result ->
            case result of
                Ok food ->
                    ( { model
                        | form = Just (Form.fromProductDetail food)
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    failure error model

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    ( { model | nutrients = response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            case model.form of
                Just form ->
                    ( { model | form = Just (Form.update subMsg form) }, Cmd.none, NoOp )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model.form of
                Just form ->
                    case Form.toCreateFoodRequest form of
                        Ok request ->
                            ( { model
                                | form = Just { form | submitting = True, error = Nothing }
                                , error = Nothing
                              }
                            , Cmd.none
                            , RequestUpdateFood model.productId request
                            )

                        Err Form.NameRequired ->
                            ( { model | form = Just { form | error = Just "Name is required" } }
                            , Cmd.none
                            , NoOp
                            )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case result of
                Ok response ->
                    ( model, Cmd.none, Navigate (FoodDetail response.id Nothing) )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | form = Maybe.map (\form -> { form | submitting = False }) model.form
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | form = Maybe.map (\form -> { form | submitting = False }) model.form
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        BackClicked ->
            ( model, Cmd.none, Navigate (FoodDetail model.productId Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ Ui.pageHeader "Edit Custom Food" (Just BackClicked)
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case model.form of
            Just form ->
                Element.column [ Element.width Element.fill, Element.spacing 14 ]
                    [ Element.map FormMsg (Form.view model.nutrients model.units form)
                    , Ui.submitButton form.submitting "Save Food" "Saving..." SubmitClicked
                    ]

            Nothing ->
                Ui.loading "Loading food..."
        ]
