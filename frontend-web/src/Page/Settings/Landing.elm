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
import Ui.Env exposing (Env)
import Ui.Icon as Icon
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Surface as Surface
import Ui.Theme as Theme
import Ui.Typography as Typography



-- MODEL


type alias Model =
    { languageOpen : Bool }


init : Model
init =
    { languageOpen = False }



-- UPDATE


type Msg
    = ApiKeysClicked
    | ThemeToggleClicked
    | LanguageDropdownToggled
    | LanguageClicked Language
    | LogoutClicked


type OutMsg
    = NoOp
    | Navigate Route
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

        LanguageDropdownToggled ->
            ( { model | languageOpen = not model.languageOpen }, Cmd.none, NoOp )

        LanguageClicked language ->
            ( { model | languageOpen = False }, Cmd.none, SetLanguage language )

        LogoutClicked ->
            ( model, Cmd.none, Logout )



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        [ Typography.mutedBodyParagraph env.theme
            (I18n.t env.language TidSettingsDescription)
        , accessSection env
        , preferencesSection env model
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


preferencesSection : Env -> Model -> Element Msg
preferencesSection env model =
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
            , languageRow env model
            ]
        , footer = Nothing
        }


languageRow : Env -> Model -> Element Msg
languageRow env model =
    Surface.staticRow
        { leading = []
        , title =
            Typography.wrappedListItemTitle env.theme
                (I18n.t env.language TidSettingsLanguageTitle)
        , subtitle =
            [ Typography.mutedBodyParagraph env.theme
                (I18n.t env.language TidSettingsLanguageDescription)
            ]
        , trailing =
            [ Element.el [ Element.width (Element.px 200) ]
                (UiInput.selectDropdownLabelHidden env.device
                    env.theme
                    env.language
                    { label = I18n.t env.language TidSettingsLanguageTitle
                    , selected = env.language
                    , options =
                        [ ( EN_US, I18n.languageName EN_US )
                        , ( HI_IN, I18n.languageName HI_IN )
                        ]
                    , onChange = LanguageClicked
                    , isOpen = model.languageOpen
                    , onToggle = LanguageDropdownToggled
                    }
                )
            ]
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
