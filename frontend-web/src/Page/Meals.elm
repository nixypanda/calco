module Page.Meals exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , emptyList
    , init
    , mealSummaryText
    , update
    , view
    )

import Api.Client as Client
import Api.Meals as Meals exposing (Meal)
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Route exposing (Route(..))
import Ui


type alias Model =
    { meals : Maybe (List Meal)
    , error : Maybe String
    , deletingMealId : Maybe String
    }


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
    ( { meals = Nothing, error = Nothing, deletingMealId = Nothing }, RequestMeals )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealsLoaded result ->
            case result of
                Ok response ->
                    ( { model | meals = Just response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | error = Just (Client.displayError error) }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )

        OpenMealClicked id ->
            ( model, Cmd.none, Navigate (MealDetail id) )

        EditMealClicked id ->
            ( model, Cmd.none, Navigate (MealEdit id) )

        DeleteMealClicked id ->
            ( { model | deletingMealId = Just id, error = Nothing }
            , Cmd.none
            , RequestDeleteMeal id
            )

        DeleteCompleted id result ->
            case result of
                Ok _ ->
                    ( { model
                        | meals = Maybe.map (List.filter (\meal -> meal.id /= id)) model.meals
                        , deletingMealId = Nothing
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | deletingMealId = Nothing
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | deletingMealId = Nothing
                            , error = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        CreateMealClicked ->
            ( model, Cmd.none, Navigate MealCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (Diary Nothing) )


emptyList : { record | meals : Maybe (List Meal) } -> Bool
emptyList model =
    model.meals == Just []


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
    case model.meals of
        Just [] ->
            Ui.card [ createMealRow ]

        Just meals ->
            Ui.card (List.map (mealRow model.deletingMealId) meals ++ [ createMealRow ])

        Nothing ->
            if model.error /= Nothing then
                Element.none

            else
                Ui.loading "Loading meals..."


mealRow : Maybe String -> Meal -> Element Msg
mealRow deletingMealId meal =
    Element.row
        [ Element.width Element.fill
        , Element.padding 12
        , Element.spacing 12
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        ]
        [ Input.button
            [ Element.width Element.fill ]
            { onPress = Just (OpenMealClicked meal.id)
            , label =
                Element.column [ Element.width Element.fill, Element.spacing 4 ]
                    [ Element.el [ Font.bold ] (Element.text meal.name)
                    , Ui.mutedText (mealSummaryText meal)
                    ]
            }
        , Ui.smallButton "Edit" (EditMealClicked meal.id)
        , Ui.dangerButton
            (if deletingMealId == Just meal.id then
                "Deleting..."

             else
                "Delete"
            )
            (DeleteMealClicked meal.id)
        ]


createMealRow : Element Msg
createMealRow =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 0, left = 0 }
        , Border.color Ui.borderGray
        , Font.color Ui.primaryTeal
        , Font.medium
        ]
        { onPress = Just CreateMealClicked
        , label = Element.text "Create Meal"
        }


mealSummaryText : Meal -> String
mealSummaryText meal =
    [ Just (String.fromInt (List.length meal.components) ++ " components")
    , meal.notes
    ]
        |> List.filterMap identity
        |> String.join " - "
