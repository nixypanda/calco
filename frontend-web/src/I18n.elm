module I18n exposing (defaultLanguage, en, languageCode, languageName, t)

import Translations.Ids exposing (TranslationId)
import Translations.Util exposing (Language(..), translate)


{-| Render a translation in the selected language. Call sites pass the app's
current `Language` explicitly, e.g. `I18n.t language (TidSomeKey ...)`.
-}
t : Language -> TranslationId -> String
t =
    translate


{-| The language used before the user has chosen one.
-}
defaultLanguage : Language
defaultLanguage =
    EN_US


{-| The persisted form understood by `Translations.Util.parseLanguage`. Keeping
the pair together makes the flag/bootstrap roundtrip a local contract.
-}
languageCode : Language -> String
languageCode language =
    case language of
        EN_US ->
            "en_US"

        HI_IN ->
            "hi_IN"


{-| Native name for a language choice. Both names stay in their own script so a
reader can recognize the language they are switching to.
-}
languageName : Language -> String
languageName language =
    case language of
        EN_US ->
            "English"

        HI_IN ->
            "हिन्दी"


{-| Escape hatch for strings produced outside the render path (for example,
messages computed during `update`), which default to English until structured
messages are threaded through the app.
-}
en : TranslationId -> String
en =
    translate EN_US
