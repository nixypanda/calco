module Translations.Util exposing (parseLanguage, translate, Language(..))

import Translations.Ids exposing (TranslationId)
import Translations.EnUs exposing (enUsTranslations)
import Translations.HiIn exposing (hiInTranslations)


type Language
    = EN_US
    | HI_IN


parseLanguage : String -> Result String Language
parseLanguage candidate =
    case candidate of
        "en_US" ->
            Ok EN_US

        "hi_IN" ->
            Ok HI_IN

        _ ->
            Err <| "Unknown language: '" ++ candidate ++ "'"


translate : Language -> TranslationId -> String
translate language translationId =
    let
        translateFun =
            case language of
                EN_US ->
                    enUsTranslations

                HI_IN ->
                    hiInTranslations
    in
        translateFun translationId
