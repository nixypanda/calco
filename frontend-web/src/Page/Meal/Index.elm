module Page.Meal.Index exposing
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
import Api.Meals as Meals exposing (Meal)
import Api.Result as ApiResult
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Font as Font
import Element.Input as Input
import Ui


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
    = MealsLoaded (Result Client.ApiError Meals.MealListResponse)
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
            ( model, Cmd.none, Navigate (MealDetail id) )

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
                                ApiResult.failure
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
            ( model, Cmd.none, Navigate (Diary Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
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


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ case model of
            Loaded loaded ->
                case loaded.action of
                    DeleteFailed message ->
                        Ui.errorBanner message

                    _ ->
                        Element.none

            LoadFailed message ->
                Ui.errorBanner message

            Loading ->
                Element.none
        , bodyView device model
        ]


bodyView : Device -> Model -> Element Msg
bodyView device model =
    case model of
        Loaded loaded ->
            if List.isEmpty loaded.meals then
                Ui.card [ createMealRow ]

            else
                Ui.card (List.map (mealRow device loaded.action) loaded.meals ++ [ createMealRow ])

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.loading "Loading meals..."


mealRow : Device -> ActionState -> Meal -> Element Msg
mealRow device action meal =
    let
        macroAccent : Maybe Element.Color
        macroAccent =
            meal.nutritionSummary
                |> Maybe.map Nutrition.summaryToNutrients
                |> Maybe.andThen Nutrition.dominantMacro
                |> Maybe.map Ui.macroColor

        dot : List (Element Msg)
        dot =
            case macroAccent of
                Just c ->
                    [ Ui.accentDot c ]

                Nothing ->
                    []
    in
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.padding 16
        , Element.spacing 12
        ]
        [ Input.button
            [ Element.width Element.fill ]
            { onPress = Just (OpenMealClicked meal.id)
            , label =
                Element.row [ Element.width Element.fill, Element.spacing 12 ]
                    (dot
                        ++ [ Element.column [ Element.width Element.fill, Element.spacing 4 ]
                                [ Ui.truncatedHeader device meal.name
                                , Ui.mutedText (mealSummaryText meal)
                                , Ui.mutedParagraph (Maybe.withDefault "" meal.notes)
                                ]
                           ]
                    )
            }
        , Ui.iconButton { label = "✎", title = "Edit", onPress = EditMealClicked meal.id }
        , Ui.dangerIconButton
            { label = "×"
            , title =
                if action == Deleting meal.id then
                    "Deleting..."

                else
                    "Delete"
            , onPress = DeleteMealClicked meal.id
            }
        ]


createMealRow : Element Msg
createMealRow =
    Ui.ghostButton "+ Create Meal" CreateMealClicked


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
        |> List.filterMap identity
        |> String.join " ⋅ "
