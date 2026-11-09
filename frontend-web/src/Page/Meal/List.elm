module Page.Meal.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , init
    , isBusy
    , skeletonView
    , update
    )

import Api.Client as Client
import Api.Meals as MealsApi exposing (Meal)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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


{-| Only the initial fetch is busy; `LoadFailed` is a settled error state.
-}
isBusy : Model -> Bool
isBusy model =
    case model of
        Loading ->
            True

        _ ->
            False



-- UPDATE


type Msg
    = MealsLoaded (Result Client.ApiError MealsApi.MealListResponse)
    | OpenMealClicked String
    | CreateMealClicked


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


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }



-- VIEW


contentView : Env -> Model -> Element Msg
contentView env model =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ case model of
            Loaded _ ->
                Element.none

            LoadFailed message ->
                Feedback.errorBanner env.theme message

            Loading ->
                Element.none
        , bodyView env model
        ]


bodyView : Env -> Model -> Element Msg
bodyView env model =
    case model of
        Loaded meals ->
            Surface.section env.theme
                { header =
                    Just
                        (Button.textButton env.device
                            env.theme
                            { tone = Button.Primary
                            , width = Button.FullWidth
                            , label = I18n.t env.language TidMealListCreate
                            , onPress = CreateMealClicked
                            , submitState = Nothing
                            , submittingLabel = Nothing
                            , trailing = Nothing
                            }
                        )
                , body =
                    if List.isEmpty meals then
                        [ Typography.mutedBodyParagraph env.theme
                            (I18n.t env.language TidCustomFoodListEmpty)
                        ]

                    else
                        List.intersperse (Surface.hairline env.theme) (List.map (mealRow env) meals)
                , footer = Nothing
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Skeleton.busy
                { label = I18n.t env.language TidCommonLoading }
                [ skeletonView env ]


mealRow : Env -> Meal -> Element Msg
mealRow env meal =
    let
        macroDot : List (Element Msg)
        macroDot =
            Maybe.withDefault []
                (Maybe.map
                    (List.singleton << View.Nutrients.macroDot env << Nutrition.summaryToNutrients)
                    meal.nutritionSummary
                )
    in
    Surface.listRow
        { onSelect = OpenMealClicked meal.id
        , leading = macroDot
        , title = Typography.wrappedListItemTitle env.theme meal.name
        , subtitle =
            [ Typography.mutedBodyParagraph env.theme (mealSummaryText meal) ]
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
    , Just (I18n.en (TidMealComponentsCount (String.fromInt (List.length meal.components))))
    ]
        |> Text.dotSeparated


{-| The page body below `contentView`'s column. The caller owns the single
`Skeleton.busy` wrapper so the page view and `Page.bootstrapView` cannot nest
status regions.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Surface.section env.theme
        { header =
            Just (Skeleton.button env.theme)
        , body =
            List.intersperse (Surface.hairline env.theme)
                (List.map (\_ -> mealRowSkeleton env) (List.range 1 3))
        , footer = Nothing
        }


mealRowSkeleton : Env -> Element msg
mealRowSkeleton env =
    Skeleton.row
        { leading = [ Skeleton.dot env.theme ]
        , -- The loaded title is a single-line 16px paragraph; its measured line
          -- box is 17px in this app.
          title = Skeleton.elLine env.theme { size = 17, width = Element.fill }
        , subtitle = [ Skeleton.elLine env.theme { size = 17, width = Element.fill } ]
        , trailing = []
        }
