module Page.Meal.List exposing
    ( ActionState(..)
    , LoadedModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , mealSummaryText
    , update
    , view
    )

import Api.Client as Client
import Api.Meals as MealsApi exposing (Meal)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients


type Model
    = Loading
    | LoadFailed String
    | Loaded LoadedModel


type alias LoadedModel =
    { meals : List Meal
    , action : ActionState
    }


type ActionState
    = Idle
    | Deleting String
    | DeleteFailed String


type Msg
    = MealsLoaded (Result Client.ApiError MealsApi.MealListResponse)
    | OpenMealClicked String
    | EditMealClicked String
    | DeleteMealClicked String
    | DeleteCompleted String (Result Client.ApiError ())
    | CreateMealClicked
    | BackClicked


type OutMsg
    = NoOp
    | RequestMeals
    | RequestDeleteMeal String
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestMeals )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealsLoaded result ->
            case result of
                Ok response ->
                    ( Loaded { meals = response.items, action = Idle }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        OpenMealClicked id ->
            ( model, Cmd.none, Navigate (MealShow id) )

        EditMealClicked id ->
            ( model, Cmd.none, Navigate (MealEdit id) )

        DeleteMealClicked id ->
            case model of
                Loaded loaded ->
                    case loaded.action of
                        Deleting _ ->
                            ( model, Cmd.none, NoOp )

                        _ ->
                            ( Loaded { loaded | action = Deleting id }
                            , Cmd.none
                            , RequestDeleteMeal id
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted id result ->
            case model of
                Loaded loaded ->
                    if loaded.action == Deleting id then
                        case result of
                            Ok _ ->
                                ( Loaded
                                    { loaded
                                        | meals = List.filter (\meal -> meal.id /= id) loaded.meals
                                        , action = Idle
                                    }
                                , Cmd.none
                                , NoOp
                                )

                            Err error ->
                                Client.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyLoadedActionError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateMealClicked ->
            ( model, Cmd.none, Navigate MealCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (DiaryDay Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


applyLoadedActionError : String -> Model -> Model
applyLoadedActionError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | action = DeleteFailed message }

        _ ->
            model


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            Loaded loaded ->
                case loaded.action of
                    DeleteFailed message ->
                        Ui.errorBanner theme message

                    _ ->
                        Element.none

            LoadFailed message ->
                Ui.errorBanner theme message

            Loading ->
                Element.none
        , bodyView theme device model
        ]


bodyView : Theme -> Device -> Model -> Element Msg
bodyView theme device model =
    case model of
        Loaded loaded ->
            Ui.listCard theme
                { rows = List.map (mealRow theme device loaded.action) loaded.meals
                , footer = Just (Ui.ghostButton device theme "+ Create Meal" CreateMealClicked)
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.skeletonLoading theme


mealRow : Theme -> Device -> ActionState -> Meal -> Element Msg
mealRow theme device action meal =
    let
        macroDot : List (Element Msg)
        macroDot =
            Maybe.withDefault []
                (Maybe.map
                    (List.singleton << View.Nutrients.macroDot << Nutrition.summaryToNutrients)
                    meal.nutritionSummary
                )
    in
    Ui.listRow
        { onSelect = OpenMealClicked meal.id
        , leading = macroDot
        , title = Ui.truncatedListItemTitle theme device meal.name
        , subtitle =
            [ Ui.mutedBody theme (mealSummaryText meal)
            , Ui.mutedParagraph theme (Maybe.withDefault "" meal.notes)
            ]
        , trailing =
            [ Ui.iconButton device
                theme
                { label = "✎", title = "Edit", onPress = EditMealClicked meal.id }
            , Ui.dangerIconButton device
                theme
                { label = "×"
                , title =
                    if action == Deleting meal.id then
                        "Deleting..."

                    else
                        "Delete"
                , onPress = DeleteMealClicked meal.id
                }
            ]
        }


mealSummaryText : Meal -> String
mealSummaryText meal =
    [ Maybe.map
        (\summary ->
            String.fromInt (round (Nutrition.safeAmount (Maybe.withDefault "0" summary.energyKcal)))
                ++ " kcal"
        )
        meal.nutritionSummary
    , Just (String.fromInt (List.length meal.components) ++ " components")
    ]
        |> Ui.dotSeparated
