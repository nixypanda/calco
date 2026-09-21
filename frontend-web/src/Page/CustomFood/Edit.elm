module Page.CustomFood.Edit exposing
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
import Api.Foods as Foods
    exposing
        ( CategorySuggestionResponse
        , CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , ProductDetail
        , UnitItem
        )
import Component.FoodEditor as Form
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Lib.Ticket exposing (Ticket)
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)



-- MODEL


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed { productId : String, message : String }


type alias LoadingModel =
    { productId : String
    , food : Maybe ProductDetail
    , nutrients : Maybe (List NutrientItem)
    , units : Maybe (List UnitItem)
    }


type alias LoadedModel =
    { productId : String
    , form : Form.FormModel
    , nutrients : List NutrientItem
    , units : List UnitItem
    }


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestUpdateFood String CreateFoodRequest
    | RequestCategorySuggestions Ticket Foods.CategorySuggestionRequest
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( Loading
        { productId = productId
        , food = Nothing
        , nutrients = Nothing
        , units = Nothing
        }
    , RequestInitialData productId
    )



-- UPDATE


type Msg
    = FoodLoaded String (Result Client.ApiError ProductDetail)
    | NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | CategorySuggestionsLoaded Ticket (Result Client.ApiError CategorySuggestionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)
    | RetryClicked


modelId : Model -> Maybe String
modelId model =
    case model of
        Loading loading ->
            Just loading.productId

        Loaded loaded ->
            Just loaded.productId

        LoadFailed _ ->
            Nothing


loadId : Msg -> Maybe String
loadId msg =
    case msg of
        FoodLoaded productId _ ->
            Just productId

        _ ->
            Nothing


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded incomingId result ->
            if modelId model /= Just incomingId then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok food ->
                        ( setLoadedFood food model, Cmd.none, NoOp )

                    Err error ->
                        failure error model

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    case model of
                        Loaded loaded ->
                            ( Loaded
                                { loaded
                                    | form = Form.withNutrientCatalog response.items loaded.form
                                    , nutrients = response.items
                                }
                            , Cmd.none
                            , NoOp
                            )

                        _ ->
                            ( setLoadedNutrients response.items model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( setLoadedUnits response.items model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            case model of
                Loaded loaded ->
                    let
                        ( nextForm, subCmd, formOut ) =
                            Form.update subMsg loaded.form
                    in
                    ( Loaded { loaded | form = nextForm }
                    , Cmd.map FormMsg subCmd
                    , case formOut of
                        Form.NoOutMsg ->
                            NoOp

                        Form.RequestCategorySuggestions token request ->
                            RequestCategorySuggestions token request
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        CategorySuggestionsLoaded token result ->
            case model of
                Loaded loaded ->
                    let
                        ( nextForm, subCmd, _ ) =
                            Form.update
                                (Form.CategorySuggestionsLoaded token
                                    (Result.map .items result)
                                )
                                loaded.form
                    in
                    ( Loaded { loaded | form = nextForm }
                    , Cmd.map FormMsg subCmd
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model of
                Loaded loaded ->
                    submitLoaded loaded

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case model of
                Loaded loaded ->
                    if Form.isSubmitting loaded.form.submit then
                        completeSave result model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        RetryClicked ->
            case model of
                LoadFailed failed ->
                    ( Loading
                        { productId = failed.productId
                        , food = Nothing
                        , nutrients = Nothing
                        , units = Nothing
                        }
                    , Cmd.none
                    , RequestInitialData failed.productId
                    )

                _ ->
                    ( model, Cmd.none, NoOp )


submitLoaded : LoadedModel -> ( Model, Cmd Msg, OutMsg )
submitLoaded loaded =
    case Form.toCreateFoodRequest loaded.form of
        Ok request ->
            ( Loaded { loaded | form = withSubmit Form.Submitting loaded.form }
            , Cmd.none
            , RequestUpdateFood loaded.productId request
            )

        Err validationError ->
            ( Loaded
                { loaded
                    | form =
                        withSubmit
                            (Form.SubmitFailed (validationMessage validationError))
                            loaded.form
                }
            , Cmd.none
            , NoOp
            )


withSubmit : Form.SubmitState -> Form.FormModel -> Form.FormModel
withSubmit state form =
    { form | submit = state }


validationMessage : Form.ValidationError -> String
validationMessage err =
    case err of
        Form.NameRequired ->
            I18n.en TidCustomFoodNameRequired

        Form.InvalidNutrientAmount value ->
            I18n.en (TidCustomFoodInvalidNutrientAmount value)

        Form.InvalidServingGrams value ->
            I18n.en (TidCustomFoodInvalidServingGrams value)

        Form.DuplicateServingUnit unit ->
            I18n.en (TidCustomFoodDuplicateServingUnit unit)

        Form.InvalidDefaultPortion ->
            I18n.en TidCustomFoodInvalidDefaultPortion


completeSave :
    Result Client.ApiError CreateFoodResponse
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
completeSave result model =
    case result of
        Ok response ->
            ( model, Cmd.none, Navigate (CustomFoodShow response.id) )

        Err error ->
            Client.failure
                { noOp = NoOp
                , sessionExpired = SessionExpired
                , applyError =
                    \message current ->
                        applySubmitError message current
                }
                error
                model


setLoadedFood : ProductDetail -> Model -> Model
setLoadedFood food model =
    case model of
        Loading loading ->
            completeLoading { loading | food = Just food }

        Loaded loaded ->
            Loaded
                { loaded
                    | form =
                        Form.fromProductDetail food
                            |> Form.withNutrientCatalog loaded.nutrients
                }

        LoadFailed _ ->
            model


setLoadedNutrients : List NutrientItem -> Model -> Model
setLoadedNutrients nutrients model =
    case model of
        Loading loading ->
            completeLoading { loading | nutrients = Just nutrients }

        Loaded loaded ->
            Loaded
                { loaded
                    | nutrients = nutrients
                    , form = Form.withNutrientCatalog nutrients loaded.form
                }

        LoadFailed _ ->
            model


setLoadedUnits : List UnitItem -> Model -> Model
setLoadedUnits units model =
    case model of
        Loading loading ->
            completeLoading { loading | units = Just units }

        Loaded loaded ->
            Loaded { loaded | units = units }

        LoadFailed _ ->
            model


completeLoading : LoadingModel -> Model
completeLoading loading =
    case ( loading.food, loading.nutrients, loading.units ) of
        ( Just food, Just nutrients, Just units ) ->
            Loaded
                { productId = loading.productId
                , form =
                    Form.fromProductDetail food
                        |> Form.withNutrientCatalog nutrients
                , nutrients = nutrients
                , units = units
                }

        _ ->
            Loading loading


applySubmitError : String -> Model -> Model
applySubmitError message model =
    case model of
        Loaded loaded ->
            Loaded
                { loaded
                    | form = withSubmit (Form.SubmitFailed message) loaded.form
                }

        _ ->
            model


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError =
            \message current ->
                case current of
                    Loading loading ->
                        LoadFailed
                            { productId = loading.productId
                            , message = message
                            }

                    Loaded loaded ->
                        LoadFailed
                            { productId = loaded.productId
                            , message = message
                            }

                    LoadFailed _ ->
                        current
        }



-- VIEW


view :
    Env
    -> Model
    -> Element Msg
view env model =
    UiPage.pageContainer
        [ bodyView env model ]


bodyView :
    Env
    -> Model
    -> Element Msg
bodyView env model =
    case model of
        Loaded loaded ->
            Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
                [ Element.map FormMsg
                    (Form.view env loaded.nutrients loaded.units loaded.form)
                , Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidCustomFoodSave
                    , onPress = SubmitClicked
                    , submitState =
                        Just (Button.submittingOrIdle (Form.isSubmitting loaded.form.submit))
                    , submittingLabel = Just (I18n.t env.language TidCommonSaving)
                    , trailing = Nothing
                    }
                ]

        LoadFailed failed ->
            Feedback.errorRetry env.theme
                env.language
                env.device
                { message = failed.message, onRetry = RetryClicked }

        Loading _ ->
            customFoodFormSkeleton env.theme


customFoodFormSkeleton : Theme -> Element msg
customFoodFormSkeleton theme =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.button theme
        ]
