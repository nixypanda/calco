module Page.Settings.Landing exposing
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
import Ui.Icon as Icon
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
    = ApiKeysClicked


type OutMsg
    = NoOp
    | Navigate Route


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ApiKeysClicked ->
            ( model, Cmd.none, Navigate SettingsApiKeys )



-- VIEW


view : Env -> Model -> Element Msg
view env _ =
    UiPage.pageContainer
        [ Typography.mutedBodyParagraph env.theme
            (I18n.t env.language TidSettingsDescription)
        , Surface.section env.theme
            { header =
                Just
                    (Typography.sectionTitle env.theme
                        (I18n.t env.language TidSettingsAccessTitle)
                    )
            , body =
                [ Surface.listRow
                    { onSelect = ApiKeysClicked
                    , leading =
                        [ Icon.view
                            { icon = Icon.Key
                            , size = 20
                            , color = env.theme.textMuted
                            }
                        ]
                    , title =
                        Typography.wrappedListItemTitle env.theme
                            (I18n.t env.language TidTitleApiKeys)
                    , subtitle =
                        [ Typography.mutedBodyParagraph env.theme
                            (I18n.t env.language TidSettingsApiKeysSummary)
                        ]
                    , trailing =
                        [ Icon.view
                            { icon = Icon.ChevronRight
                            , size = 20
                            , color = env.theme.textMuted
                            }
                        ]
                    }
                ]
            , footer = Nothing
            }
        , Surface.section env.theme
            { header =
                Just
                    (Typography.sectionTitle env.theme
                        (I18n.t env.language TidSettingsPreferencesTitle)
                    )
            , body =
                [ Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidSettingsPreferencesComingSoon)
                ]
            , footer = Nothing
            }
        ]
