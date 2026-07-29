module Page.Meal.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
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
import Ui.Typography as Typography
import View.Nutrients



-- MODEL


type Model
    = Loading
    | LoadFailed String
    | Loaded (List Meal)


type OutMsg
    = NoOp
    | RequestMeals
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestMeals )



-- UPDATE


type Msg
    = MealsLoaded (Result Client.ApiError MealsApi.MealListResponse)
    | OpenMealClicked String
    | CreateMealClicked
    | BackClicked


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealsLoaded result ->
            case result of
                Ok response ->
                    ( Loaded response.items, Cmd.none, NoOp )

                Err error ->
                    failure error model

        OpenMealClicked id ->
            ( model, Cmd.none, Navigate (MealShow id) )

        CreateMealClicked ->
            ( model, Cmd.none, Navigate MealCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (DiaryDay Nothing Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ contentView { model = model, device = device, theme = theme } ]


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView { model, device, theme } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ case model of
            Loaded _ ->
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
        Loaded meals ->
            Ui.listCard theme
                { rows = List.map (mealRow theme device) meals
                , footer =
                    Just (Ui.fullWidthGhostButton device theme "+ Create Meal" CreateMealClicked)
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.skeletonLoading theme


mealRow : Theme -> Device -> Meal -> Element Msg
mealRow theme _ meal =
    let
        macroDot : List (Element Msg)
        macroDot =
            Maybe.withDefault []
                (Maybe.map
                    (List.singleton
                        << View.Nutrients.macroDot theme
                        << Nutrition.summaryToNutrients
                    )
                    meal.nutritionSummary
                )
    in
    Ui.listRow
        { onSelect = OpenMealClicked meal.id
        , leading = macroDot
        , title = Typography.wrappedListItemTitle theme meal.name
        , subtitle =
            [ Typography.mutedBodyParagraph theme (mealSummaryText meal)
            ]
        , trailing = []
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
