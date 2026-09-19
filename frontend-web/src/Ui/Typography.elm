module Ui.Typography exposing
    ( body
    , caption
    , decimalNumber
    , heroStat
    , listItemTitle
    , maybeMutedParagraph
    , mutedBody
    , mutedBodyParagraph
    , mutedCaption
    , mutedCaptionParagraph
    , mutedParagraph
    , pageTitle
    , sectionTitle
    , subsectionTitle
    , tableHeader
    , truncatedHeader
    , truncatedListItemTitle
    , wrappedListItemTitle
    )

import Element exposing (Element)
import Element.Font as Font
import Element.Region as Region
import Ui.Common exposing (minWidthZero, uiClass)
import Ui.Theme exposing (Theme)


body : Element.Attribute msg
body =
    Font.size 16


caption : Element.Attribute msg
caption =
    Font.size 13


decimalNumber : String -> Element msg
decimalNumber value =
    Element.el
        [ body
        , Font.alignRight
        , Font.variant Font.tabularNumbers
        ]
        (Element.text value)


sizePageTitle : Element.Attribute msg
sizePageTitle =
    Font.size 32


sizeHeroStat : Element.Attribute msg
sizeHeroStat =
    Font.size 44


sizeSectionTitle : Element.Attribute msg
sizeSectionTitle =
    Font.size 24


sizeSubsectionTitle : Element.Attribute msg
sizeSubsectionTitle =
    Font.size 20


pageTitle : Theme -> String -> Element msg
pageTitle theme text =
    Element.el
        [ sizePageTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 1
        ]
        (Element.text text)


heroStat : Theme -> String -> Element msg
heroStat theme text =
    Element.el
        [ sizeHeroStat
        , Font.bold
        , Font.color theme.textPrimary
        ]
        (Element.text text)


sectionTitle : Theme -> String -> Element msg
sectionTitle theme text =
    Element.el
        [ sizeSectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 2
        ]
        (Element.text text)


subsectionTitle : Theme -> String -> Element msg
subsectionTitle theme text =
    Element.el
        [ sizeSubsectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 3
        ]
        (Element.text text)


listItemTitle : Theme -> Element msg -> Element msg
listItemTitle theme child =
    Element.el
        [ body
        , Font.bold
        , Font.color theme.textPrimary
        ]
        child


truncatedListItemTitle : Theme -> String -> Element msg
truncatedListItemTitle theme name =
    Element.el
        [ Element.width Element.fill
        ]
        (listItemTitle theme
            (Element.el
                [ Element.width Element.fill
                , Element.clip
                , uiClass "ui-text-ellipsis"
                ]
                (Element.text name)
            )
        )


wrappedListItemTitle : Theme -> String -> Element msg
wrappedListItemTitle theme name =
    listItemTitle theme
        (Element.paragraph
            [ Element.width Element.fill
            , minWidthZero
            ]
            [ Element.text name ]
        )


mutedCaption : Theme -> String -> Element msg
mutedCaption theme text =
    Element.el
        [ caption
        , Font.color theme.textMuted
        ]
        (Element.text text)


mutedCaptionParagraph : Theme -> String -> Element msg
mutedCaptionParagraph theme text =
    Element.paragraph
        [ caption
        , Font.color theme.textMuted
        , Element.width Element.fill
        , minWidthZero
        ]
        [ Element.text text ]


tableHeader : Theme -> String -> Element msg
tableHeader theme text =
    Element.el
        [ body
        , Font.bold
        , Font.color theme.textMuted
        ]
        (Element.text text)


truncatedHeader : Theme -> String -> Element msg
truncatedHeader theme heading =
    Element.paragraph
        [ sizeSectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 2
        , Element.width Element.fill
        , minWidthZero
        ]
        [ Element.text heading ]


mutedBody : Theme -> String -> Element msg
mutedBody theme text =
    Element.el
        [ Font.color theme.textMuted
        , body
        ]
        (Element.text text)


mutedBodyParagraph : Theme -> String -> Element msg
mutedBodyParagraph theme text =
    Element.paragraph
        [ Font.color theme.textMuted
        , body
        , Element.width Element.fill
        , minWidthZero
        ]
        [ Element.text text ]


mutedParagraph : Theme -> String -> Element msg
mutedParagraph theme text =
    Element.paragraph
        [ Font.color theme.textMuted
        , body
        ]
        [ Element.text text ]


maybeMutedParagraph : Theme -> Maybe String -> Element msg
maybeMutedParagraph theme maybeText =
    case maybeText of
        Just text ->
            mutedParagraph theme text

        Nothing ->
            Element.none
