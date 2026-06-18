module Page.CustomFood.Show exposing
    ( DeleteState(..)
    , LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , modalView
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String


type alias LoadingModel =
    { productId : String
    , food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    }


type alias LoadedModel =
    { productId : String
    , food : ProductDetail
    , units : List UnitItem
    , delete : DeleteState
    }


type DeleteState
    = DeleteIdle
    | DeleteConfirming
    | Deleting
    | DeleteFailed String


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | EditClicked
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestDeleteCustomFood String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( Loading
        { productId = productId
        , food = Nothing
        , units = Nothing
        }
    , RequestInitialData productId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded result ->
            case result of
                Ok food ->
                    ( setLoadedFood food model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( setLoadedUnits response.items model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        EditClicked ->
            case model of
                Loaded loaded ->
                    case customFoodEditRoute loaded.food of
                        Just route ->
                            ( model, Cmd.none, Navigate route )

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

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
                            , RequestDeleteCustomFood loaded.productId
                            )

                        DeleteFailed _ ->
                            ( Loaded { loaded | delete = Deleting }
                            , Cmd.none
                            , RequestDeleteCustomFood loaded.productId
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
                                ( model, Cmd.none, Navigate CustomFoodList )

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


setLoadedFood : ProductDetail -> Model -> Model
setLoadedFood food model =
    case model of
        Loading loading ->
            completeLoading { loading | food = Just food }

        Loaded loaded ->
            Loaded { loaded | food = food, delete = DeleteIdle }

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
    case ( loading.food, loading.units ) of
        ( Just food, Just units ) ->
            Loaded
                { productId = loading.productId
                , food = food
                , units = units
                , delete = DeleteIdle
                }

        _ ->
            Loading loading


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


applyDeleteError : String -> Model -> Model
applyDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | delete = DeleteFailed message }

        _ ->
            model


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            LoadFailed message ->
                Ui.errorBanner theme message

            _ ->
                Element.none
        , bodyView theme device model
        ]


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView { model, device, theme } =
    case model of
        Loaded loaded ->
            deleteModalView theme device loaded

        _ ->
            Nothing


bodyView : Theme -> Device -> Model -> Element Msg
bodyView theme device model =
    case model of
        Loaded loaded ->
            loadedView theme device loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Ui.skeletonLoading theme


loadedView : Theme -> Device -> LoadedModel -> Element Msg
loadedView theme device loaded =
    let
        food : ProductDetail
        food =
            loaded.food

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            foodNutrientsPer100g food
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing Ui.space16
        ]
        [ foodHeader theme food
        , View.Nutrients.nutritionCard theme device nutrients
        , bottomActionsView theme device food
        ]


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


foodHeader : Theme -> ProductDetail -> Element Msg
foodHeader theme food =
    let
        macroNutrients : List Nutrition.NutrientAmount
        macroNutrients =
            food.nutrients
                |> List.map
                    (\n -> { code = n.code, amount = n.amountPer100g, unit = n.unit })
    in
    Ui.card theme
        [ Ui.pageHeader theme
            { leading = Just (View.Nutrients.macroDot theme macroNutrients)
            , title = Ui.truncatedHeader theme food.name
            , subtitle = Just (metaText food)
            , actions = []
            }
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.macroDotGhost, Ui.chips theme food.categories ]
        ]


metaText : ProductDetail -> String
metaText food =
    [ food.brand
    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
    ]
        |> Ui.dotSeparated


bottomActionsView : Theme -> Device -> ProductDetail -> Element Msg
bottomActionsView theme device food =
    let
        actions : List { label : String, onPress : Msg, tone : Ui.BottomActionTone }
        actions =
            case customFoodEditRoute food of
                Just _ ->
                    [ { label = "Edit Food", onPress = EditClicked, tone = Ui.PrimaryAction }
                    , { label = "Delete Food", onPress = DeleteClicked, tone = Ui.DangerAction }
                    ]

                Nothing ->
                    []
    in
    Ui.bottomActionButtons device theme actions


deleteModalView : Theme -> Device -> LoadedModel -> Maybe (Element Msg)
deleteModalView theme device loaded =
    case loaded.delete of
        DeleteConfirming ->
            Just (deleteModalContent theme device Nothing False)

        Deleting ->
            Just (deleteModalContent theme device Nothing True)

        DeleteFailed message ->
            Just (deleteModalContent theme device (Just message) False)

        DeleteIdle ->
            Nothing


deleteModalContent : Theme -> Device -> Maybe String -> Bool -> Element Msg
deleteModalContent theme device maybeError deleting =
    Ui.modalOverlay theme
        { title = "Delete food?"
        , body =
            [ Ui.mutedParagraph theme "This will permanently remove the custom food."
            , Ui.maybeErrorBanner theme maybeError
            ]
        , actions =
            Ui.bottomActionButtons device
                theme
                [ { label = "Cancel", onPress = CancelDeleteClicked, tone = Ui.PrimaryAction }
                , { label =
                        if deleting then
                            "Deleting..."

                        else
                            "Confirm Delete"
                  , onPress = ConfirmDeleteClicked
                  , tone = Ui.DangerAction
                  }
                ]
        , onBackgroundPress = Just CancelDeleteClicked
        }


customFoodEditRoute : ProductDetail -> Maybe Route
customFoodEditRoute food =
    if food.source == "USER" then
        Just (CustomFoodEdit food.id)

    else
        Nothing
