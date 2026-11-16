module Page.Settings.Landing exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , dismissTransient
    , init
    , menuPlacementFor
    , update
    , view
    )

import Browser.Dom
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Task
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Button as Button
import Ui.Common as UiCommon
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
    { languageOpen : Bool
    , languageActive : Maybe Language
    , languageMenuPlacement : UiInput.SelectMenuPlacement
    }


init : Model
init =
    { languageOpen = False
    , languageActive = Nothing
    , languageMenuPlacement = UiInput.MenuBelow
    }


{-| Navigation closes page-owned transient UI before the destination changes,
so tapping an already-active bottom-nav tab still dismisses the language menu.
-}
dismissTransient : Model -> Model
dismissTransient model =
    { model | languageOpen = False, languageActive = Nothing }



-- UPDATE


type Msg
    = ApiKeysClicked
    | ThemeToggleClicked
    | LanguageDropdownToggled Language
    | LanguageDropdownClosed
    | LanguageActiveChanged (Maybe Language)
    | LanguageClicked Language
    | LanguageFocusCompleted
    | LanguageMenuMeasured UiInput.SelectMenuPlacement
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

        LanguageDropdownToggled currentLanguage ->
            if model.languageOpen then
                ( dismissTransient model
                , Cmd.none
                , NoOp
                )

            else
                ( { model | languageOpen = True, languageActive = Just currentLanguage }
                , measureLanguageMenu
                , NoOp
                )

        LanguageDropdownClosed ->
            ( dismissTransient model
            , Cmd.none
            , NoOp
            )

        LanguageActiveChanged language ->
            ( { model | languageActive = language }, Cmd.none, NoOp )

        LanguageClicked language ->
            ( dismissTransient model
            , Browser.Dom.focus (UiInput.selectDropdownTriggerId languageDropdownId)
                |> Task.attempt (\_ -> LanguageFocusCompleted)
            , SetLanguage language
            )

        LanguageFocusCompleted ->
            ( model, Cmd.none, NoOp )

        LanguageMenuMeasured placement ->
            ( { model | languageMenuPlacement = placement }, Cmd.none, NoOp )

        LogoutClicked ->
            ( model, Cmd.none, Logout )


{-| Two option rows, their padding, and the menu border, plus a little
headroom. The bottom clearance matches the Phone bottom nav.
-}
languageMenuEstimatedHeight : Int
languageMenuEstimatedHeight =
    100


bottomChromeClearance : Int
bottomChromeClearance =
    56


{-| Pure placement decision from the open trigger's viewport geometry, so the
phone bottom-nav clearance is testable without a browser.
-}
menuPlacementFor :
    { viewportHeight : Float, triggerTop : Float, triggerHeight : Float }
    -> UiInput.SelectMenuPlacement
menuPlacementFor bounds =
    let
        spaceAbove : Float
        spaceAbove =
            bounds.triggerTop

        spaceBelow : Float
        spaceBelow =
            bounds.viewportHeight - (bounds.triggerTop + bounds.triggerHeight)
    in
    if
        spaceBelow
            < toFloat (languageMenuEstimatedHeight + bottomChromeClearance)
            && spaceAbove
            > spaceBelow
    then
        UiInput.MenuAbove

    else
        UiInput.MenuBelow


measureLanguageMenu : Cmd Msg
measureLanguageMenu =
    Task.map2
        (\viewport trigger ->
            menuPlacementFor
                { viewportHeight = viewport.viewport.height
                , triggerTop = trigger.element.y
                , triggerHeight = trigger.element.height
                }
        )
        Browser.Dom.getViewport
        (Browser.Dom.getElement (UiInput.selectDropdownTriggerId languageDropdownId))
        |> Task.attempt (Result.withDefault UiInput.MenuBelow >> LanguageMenuMeasured)



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


languageDropdownId : String
languageDropdownId =
    "settings-language"


languageRow : Env -> Model -> Element Msg
languageRow env model =
    if UiCommon.isSmall env.device then
        Surface.staticRow
            { leading = []
            , title =
                Typography.wrappedListItemTitle env.theme
                    (I18n.t env.language TidSettingsLanguageTitle)
            , subtitle =
                [ Typography.mutedBodyParagraph env.theme
                    (I18n.t env.language TidSettingsLanguageDescription)
                , Element.el
                    [ Element.width Element.fill
                    , Element.paddingEach
                        { top = DesignTokens.space8
                        , right = 0
                        , bottom = 0
                        , left = 0
                        }
                    ]
                    (languageControl env model)
                ]
            , trailing = []
            }

    else
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
                    (languageControl env model)
                ]
            }


languageControl : Env -> Model -> Element Msg
languageControl env model =
    UiInput.selectDropdownLabelHidden env.device
        env.theme
        env.language
        { id = languageDropdownId
        , label = I18n.t env.language TidSettingsLanguageTitle
        , selected = env.language
        , options =
            [ ( EN_US, I18n.languageName EN_US )
            , ( HI_IN, I18n.languageName HI_IN )
            ]
        , onChange = LanguageClicked
        , isOpen = model.languageOpen
        , onToggle = LanguageDropdownToggled env.language
        , active = model.languageActive
        , onActiveChanged = LanguageActiveChanged
        , onClose = LanguageDropdownClosed
        , menuPlacement = model.languageMenuPlacement
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
