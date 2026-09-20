module Translations.Util exposing (parseLanguage, translate, Language(..))

import Translations.Ids exposing (TranslationId)
import Translations.EnUs exposing (enUsTranslations)


type Language
    = EN_US


parseLanguage : String -> Result String Language
parseLanguage candidate =
    case candidate of
        "en_US" ->
            Ok EN_US

        _ ->
            Err <| "Unknown language: '" ++ candidate ++ "'"


translate : Language -> TranslationId -> String
translate language translationId =
    let
        translateFun =
            case language of
                EN_US ->
                    enUsTranslations
    in
        translateFun translationId
