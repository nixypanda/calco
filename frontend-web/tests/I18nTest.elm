module I18nTest exposing (tests)

import Expect
import I18n
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util


tests : Test
tests =
    describe "I18n"
        [ test "parses the Hindi locale" <|
            \_ ->
                Expect.equal (Ok Util.HI_IN) (Util.parseLanguage "hi_IN")
        , test "renders Hindi differently from English" <|
            \_ ->
                Expect.notEqual
                    (I18n.t Util.EN_US TidNavDiary)
                    (I18n.t Util.HI_IN TidNavDiary)
        ]
