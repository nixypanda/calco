module Page.Meal.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , init
    , mealSummaryText
    , update
    )

import Api.Client as Client
import Api.Meals as MealsApi exposing (Meal)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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


contentView : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
contentView { model, device, theme, language } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ case model of
            Loaded _ ->
                Element.none

            LoadFailed message ->
                Feedback.errorBanner theme message

            Loading ->
                Element.none
        , bodyView theme language device model
        ]


bodyView : Theme -> Language -> Device -> Model -> Element Msg
bodyView theme language device model =
    case model of
        Loaded meals ->
            Surface.section theme
                { header =
                    Just
                        (Button.textButton device
                            theme
                            { tone = Button.Primary
                            , width = Button.FullWidth
                            , label = I18n.t language TidMealListCreate
                            , onPress = CreateMealClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        )
                , body =
                    if List.isEmpty meals then
                        [ Typography.mutedBodyParagraph
                            theme
                            (I18n.t language TidCustomFoodListEmpty)
                        ]

                    else
                        List.intersperse (Surface.hairline theme)
                            (List.map (mealRow theme language device) meals)
                , footer = Nothing
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            mealListSkeleton theme


mealRow : Theme -> Language -> Device -> Meal -> Element Msg
mealRow theme language _ meal =
    let
        macroDot : List (Element Msg)
        macroDot =
            Maybe.withDefault []
                (Maybe.map
                    (List.singleton
                        << View.Nutrients.macroDot theme language
                        << Nutrition.summaryToNutrients
                    )
                    meal.nutritionSummary
                )
    in
    Surface.listRow
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
            I18n.en
                (TidDiaryKcal
                    (String.fromInt
                        (round (Nutrition.safeAmount (Maybe.withDefault "0" summary.energyKcal)))
                    )
                )
        )
        meal.nutritionSummary
    , Just
        (I18n.en
            (TidMealComponentsCount (String.fromInt (List.length meal.components)))
        )
    ]
        |> Text.dotSeparated


mealListSkeleton : Theme -> Element msg
mealListSkeleton theme =
    Surface.section theme
        { header =
            Just (Skeleton.button theme)
        , body =
            List.intersperse (Surface.hairline theme)
                (List.map (\_ -> Skeleton.listRow theme)
                    (List.range 1 3)
                )
        , footer = Nothing
        }
