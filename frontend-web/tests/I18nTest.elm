module I18nTest exposing (tests)

{-| Locale parsing and translation rendering.

Translations are data, so exact strings are the contract for the sample below.
The non-empty check is a **representative sample**, not an enumeration of every
`TranslationId`: the generated ID module has hundreds of constructors and no
registry to fold over. The sample includes plain, interpolated, English, and
Hindi translations so a blank or missing entry in each shape is caught.

-}

import Expect
import I18n
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util


tests : Test
tests =
    describe "I18n"
        [ test "renders exact plain and interpolated translations in both languages" <|
            \_ ->
                Expect.all
                    [ exact Util.EN_US TidNavDiary "Diary"
                    , exact Util.HI_IN TidNavDiary "डायरी"
                    , exact Util.EN_US TidCommonSave "Save"
                    , exact Util.HI_IN TidCommonSave "सहेजें"
                    , exact Util.EN_US
                        TidDiarySettingsSelectAtLeastOne
                        "Select at least one meal slot."
                    , exact Util.HI_IN
                        TidDiarySettingsSelectAtLeastOne
                        "कम से कम एक भोजन स्लॉट चुनें।"
                    , exact Util.EN_US
                        (TidApiErrorRateLimitedSeconds "5")
                        "Too many requests. Try again in 5 seconds."
                    , exact Util.HI_IN
                        (TidNutritionDetailsLoggedItemsIncludedOne "1")
                        "1 दर्ज किया गया आइटम इन दैनिक कुल में शामिल है।"
                    ]
                    ()
        , test "sampled translation ids are non-empty in both languages" <|
            \_ ->
                Expect.all
                    [ \_ -> blankIds Util.EN_US |> Expect.equal []
                    , \_ -> blankIds Util.HI_IN |> Expect.equal []
                    ]
                    ()
        ]


exact : Util.Language -> TranslationId -> String -> () -> Expect.Expectation
exact language translationId expected _ =
    I18n.t language translationId |> Expect.equal expected


blankIds : Util.Language -> List TranslationId
blankIds language =
    sampleIds
        |> List.filter (\translationId -> String.trim (I18n.t language translationId) == "")


sampleIds : List TranslationId
sampleIds =
    [ TidNavDiary
    , TidCommonSave
    , TidDiarySettingsSelectAtLeastOne
    , TidApiErrorNetwork
    , TidNutritionDetailsAdviceFiber
    , TidNutritionDetailsLoggedItemsIncludedOne "1"
    , TidApiErrorRateLimitedSeconds "5"
    , TidMealSlotLateNightSnack
    ]
