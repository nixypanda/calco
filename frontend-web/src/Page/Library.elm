module Page.Library exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Env exposing (Env)
import Ui.Icon as Icon exposing (Icon)
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Typography as Typography



-- MODEL


type alias Model =
    ()


init : Model
init =
    ()



-- UPDATE


type Msg
    = MyFoodsClicked
    | MyMealsClicked


type OutMsg
    = NoOp
    | Navigate Route


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MyFoodsClicked ->
            ( model, Cmd.none, Navigate CustomFoodList )

        MyMealsClicked ->
            ( model, Cmd.none, Navigate MealList )



-- VIEW


view : Env -> Model -> Element Msg
view env _ =
    UiPage.pageContainer
        [ Typography.mutedBodyParagraph env.theme
            (I18n.t env.language TidLibraryDescription)
        , Surface.section env.theme
            { header =
                Just
                    (Typography.sectionTitle env.theme
                        (I18n.t env.language TidLibraryBrowseTitle)
                    )
            , body =
                [ libraryRow env
                    { icon = Icon.Box
                    , title = I18n.t env.language TidTitleMyFoods
                    , description = I18n.t env.language TidLibraryFoodsDescription
                    , onPress = MyFoodsClicked
                    }
                , Surface.hairline env.theme
                , libraryRow env
                    { icon = Icon.Utensils
                    , title = I18n.t env.language TidTitleMyMeals
                    , description = I18n.t env.language TidLibraryMealsDescription
                    , onPress = MyMealsClicked
                    }
                ]
            , footer = Nothing
            }
        ]


libraryRow :
    Env
    -> { icon : Icon, title : String, description : String, onPress : Msg }
    -> Element Msg
libraryRow env config =
    Surface.listRow
        { onSelect = config.onPress
        , leading =
            [ Icon.view
                { icon = config.icon
                , size = 20
                , color = env.theme.textMuted
                }
            ]
        , title = Typography.wrappedListItemTitle env.theme config.title
        , subtitle = [ Typography.mutedBodyParagraph env.theme config.description ]
        , trailing =
            [ Icon.view
                { icon = Icon.ChevronRight
                , size = 20
                , color = env.theme.textMuted
                }
            ]
        }
