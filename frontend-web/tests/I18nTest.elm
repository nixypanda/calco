module I18nTest exposing (tests)

import Expect
import I18n
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util


tests : Test
tests =
    describe "I18n"
        [ test "renders a simple translation" <|
            \_ ->
                Expect.equal "New version available" (I18n.t TidCommonNewVersionAvailable)
        , test "parses the reference locale" <|
            \_ ->
                Expect.equal (Ok Util.EN_US) (Util.parseLanguage "en_US")
        ]
