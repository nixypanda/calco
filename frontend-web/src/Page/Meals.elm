module Page.Meals exposing (Model, Msg(..), OutMsg(..), emptyList, init, update, view)

import Api.Client as Client
import Api.Meals as Meals exposing (Meal)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Route exposing (Route(..))
import Ui


type alias Model =
    { meals : Maybe (List Meal)
    , error : Maybe String
    }


type Msg
    = MealsLoaded (Result Client.ApiError Meals.MealListResponse)
    | OpenMealClicked String
    | CreateMealClicked
    | BackClicked


type OutMsg
    = NoOp
    | RequestMeals
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { meals = Nothing, error = Nothing }, RequestMeals )


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

        CreateMealClicked ->
            ( model, Cmd.none, Navigate MealCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (Diary Nothing) )


emptyList : Model -> Bool
emptyList model =
    model.meals == Just []


view : Model -> Element Msg
view model =
    Element.column [ Element.width Element.fill, Element.spacing 16, Element.padding 24 ]
        [ Element.row [ Element.width Element.fill, Element.spacing 12 ]
            [ Ui.button "Back" BackClicked
            , Element.el [ Font.size 22, Font.bold ] (Element.text "Meals")
            , Ui.button "Create Meal" CreateMealClicked
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
    case model.meals of
        Just [] ->
            Element.el [ Font.color (Element.rgb255 107 114 128) ] (Element.text "No meals yet.")

        Just meals ->
            Element.column
                [ Element.width Element.fill, Element.spacing 10 ]
                (List.map mealRow meals)

        Nothing ->
            if model.error /= Nothing then
                Element.none

            else
                Element.el
                    [ Font.color (Element.rgb255 107 114 128) ]
                    (Element.text "Loading meals...")


mealRow : Meal -> Element Msg
mealRow meal =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 6
        , Element.padding 14
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Element.el [ Font.bold ] (Element.text meal.name)
        , Element.el
            [ Font.size 14
            , Font.color (Element.rgb255 107 114 128)
            ]
            (Element.text (String.fromInt (List.length meal.components) ++ " components"))
        , Ui.button "Open" (OpenMealClicked meal.id)
        ]
