module Ui.CategoryTag exposing
    ( CategoryTag(..)
    , rows
    , view
    )

import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens exposing (space4)
import Ui.Theme exposing (Theme)


{-| A cell in the category-tag grid: either a category label or a single
overflow tag counting the categories that did not fit.
-}
type CategoryTag
    = CategoryTag String
    | CategoryOverflowTag Int


{-| UI product rule: category tags occupy at most two rows of at most two tags
each. Once more than four categories exist, the final cell becomes one overflow
tag, so the grid can never grow beyond two rows.
-}
rows : List String -> List (List CategoryTag)
rows categories =
    case categories of
        [] ->
            []

        [ a ] ->
            [ [ CategoryTag a ] ]

        [ a, b ] ->
            [ [ CategoryTag a, CategoryTag b ] ]

        [ a, b, c ] ->
            [ [ CategoryTag a, CategoryTag b ], [ CategoryTag c ] ]

        [ a, b, c, d ] ->
            [ [ CategoryTag a, CategoryTag b ], [ CategoryTag c, CategoryTag d ] ]

        a :: b :: c :: hidden ->
            [ [ CategoryTag a, CategoryTag b ]
            , [ CategoryTag c, CategoryOverflowTag (List.length hidden) ]
            ]


view : Theme -> Language -> List (List CategoryTag) -> Element msg
view theme language tagRows =
    Element.column
        [ Element.spacing space4 ]
        (List.map (tagRow theme language) tagRows)


tagRow : Theme -> Language -> List CategoryTag -> Element msg
tagRow theme language cells =
    Element.row
        [ Element.spacing space4
        , Element.alignRight
        ]
        (List.map (tagCell theme language) cells)


tagCell : Theme -> Language -> CategoryTag -> Element msg
tagCell theme language tag =
    Element.el
        [ Element.width (Element.px cellWidth)
        , Element.clip
        , UiCommon.uiClass "ui-text-ellipsis"
        ]
        (Chip.chip theme { label = label language tag, selected = False })


{-| Fixed cell width, so two chips per row form a stable right-aligned grid and
a long label ellipsizes instead of squashing the chip.
-}
cellWidth : Int
cellWidth =
    140


label : Language -> CategoryTag -> String
label language tag =
    case tag of
        CategoryTag name ->
            name

        CategoryOverflowTag count ->
            I18n.t language (TidUiCategoryOverflowMore (String.fromInt count))
