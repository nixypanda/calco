module I18n exposing (t)

import Translations.Ids exposing (TranslationId)
import Translations.Util exposing (Language(..), translate)


t : TranslationId -> String
t =
    translate EN_US
