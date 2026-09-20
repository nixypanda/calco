module I18n exposing (defaultLanguage, en, t)

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


{-| Escape hatch for strings produced outside the render path (for example,
messages computed during `update`), which default to English until structured
messages are threaded through the app.
-}
en : TranslationId -> String
en =
    translate EN_US
