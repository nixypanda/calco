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
import Translations.Util exposing (Language(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Icon as Icon
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Theme as Theme
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
    | ThemeToggleClicked
    | LanguageClicked Language
    | LogoutClicked


type OutMsg
    = Navigate Route
    | ToggleTheme
    | SetLanguage Language
    | Logout


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        ApiKeysClicked ->
            ( model, Cmd.none, Navigate SettingsApiKeys )

        ThemeToggleClicked ->
            ( model, Cmd.none, ToggleTheme )

        LanguageClicked language ->
            ( model, Cmd.none, SetLanguage language )

        LogoutClicked ->
            ( model, Cmd.none, Logout )



-- VIEW


view : Env -> Model -> Element Msg
view env _ =
    UiPage.pageContainer
        [ Typography.mutedBodyParagraph env.theme
            (I18n.t env.language TidSettingsDescription)
        , accessSection env
        , preferencesSection env
        , accountSection env
        ]


accessSection : Env -> Element Msg
accessSection env =
    Surface.section env.theme
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


preferencesSection : Env -> Element Msg
preferencesSection env =
    Surface.section env.theme
        { header =
            Just
                (Typography.sectionTitle env.theme
                    (I18n.t env.language TidSettingsPreferencesTitle)
                )
        , body =
            [ Surface.staticRow
                { leading = []
                , title =
                    Typography.wrappedListItemTitle env.theme
                        (I18n.t env.language TidSettingsThemeTitle)
                , subtitle =
                    [ Typography.mutedBodyParagraph env.theme
                        (I18n.t env.language TidSettingsThemeDescription)
                    ]
                , trailing =
                    [ UiInput.toggleSwitch env.theme
                        { label = I18n.t env.language TidCommonUseDarkTheme
                        , isActive = env.theme.mode == Theme.Dark
                        , onToggle = ThemeToggleClicked
                        }
                    ]
                }
            , Surface.hairline env.theme
            , Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ Typography.wrappedListItemTitle env.theme
                    (I18n.t env.language TidSettingsLanguageTitle)
                , Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidSettingsLanguageDescription)
                , languageOptions env
                ]
            ]
        , footer = Nothing
        }


languageOptions : Env -> Element Msg
languageOptions env =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space4
        ]
        [ languageOption env EN_US
        , languageOption env HI_IN
        ]


languageOption : Env -> Language -> Element Msg
languageOption env language =
    UiInput.optionRowWithState env.theme
        { label = I18n.languageName language
        , selected = env.language == language
        , onPress = LanguageClicked language
        , disabled = False
        , trailing = Nothing
        }


accountSection : Env -> Element Msg
accountSection env =
    Surface.section env.theme
        { header =
            Just
                (Typography.sectionTitle env.theme
                    (I18n.t env.language TidSettingsAccountTitle)
                )
        , body =
            [ Typography.mutedBodyParagraph env.theme
                (I18n.t env.language TidSettingsAccountDescription)
            , Button.textButton env.device
                env.theme
                { tone = Button.DangerOutline
                , width = Button.FullWidth
                , label = I18n.t env.language TidNavLogout
                , onPress = LogoutClicked
                , submitState = Nothing
                , submittingLabel = Nothing
                , trailing = Nothing
                }
            ]
        , footer = Nothing
        }
