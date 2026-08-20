module View.Search exposing
    ( resultRow
    , searchInput
    )

import Api.Foods exposing (SearchResult)
import Data.Nutrition as Nutrition
import Data.Search as Search exposing (Completion(..))
import Element exposing (Device, Element)
import Html
import Html.Events
import Json.Decode as Decode
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


completionDropdown :
    Theme
    -> Device
    -> { onSelect : Completion -> msg }
    -> List Completion
    -> Element msg
completionDropdown theme device config options =
    if List.isEmpty options then
        Element.none

    else
        Ui.completionDropdown theme
            { height = completionDropdownHeight device options
            , rows = List.map (completionRow theme config.onSelect) options
            }


searchInput :
    Theme
    -> Device
    ->
        { onChange : String -> msg
        , text : String
        , label : String
        , completions : List Completion
        , onTabComplete : msg
        , onCompletionClick : Completion -> msg
        }
    -> Element msg
searchInput theme device config =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
        [ Ui.searchInput theme
            { onChange = config.onChange
            , text = config.text
            , label = config.label
            , extraAttrs =
                [ Element.htmlAttribute
                    (tabCompletionHandler config.onTabComplete config.completions)
                ]
            }
        , completionDropdown theme device { onSelect = config.onCompletionClick } config.completions
        ]


tabCompletionHandler : msg -> List Completion -> Html.Attribute msg
tabCompletionHandler completeMsg options =
    Html.Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Tab" && not (List.isEmpty options) then
                        Decode.succeed ( completeMsg, True )

                    else
                        Decode.fail "not handled"
                )
        )


resultRow :
    Theme
    -> Device
    -> { query : String, item : SearchResult, onSelect : String -> msg }
    -> Element msg
resultRow theme device config =
    let
        macroDot : Element msg
        macroDot =
            View.Nutrients.macroDot theme
                (config.item.nutritionSummary.per100g |> Nutrition.summaryToNutrients)

        searchItem : Element msg
        searchItem =
            Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space4
                ]
                [ if Ui.isSmall device then
                    Typography.wrappedListItemTitle theme config.item.name

                  else
                    Typography.truncatedListItemTitle theme config.item.name
                , Typography.mutedCaptionParagraph theme (metaText config.query config.item)
                ]

        categoryTags : Element msg
        categoryTags =
            categoryPills theme device config.item.categories

        hasCategories : Bool
        hasCategories =
            not (List.isEmpty (visibleCategories config.item.categories))
    in
    Ui.listRow
        { onSelect = config.onSelect config.item.id
        , leading = [ macroDot ]
        , title = searchItem
        , subtitle =
            if Ui.isSmall device && hasCategories then
                [ categoryTags ]

            else
                []
        , trailing =
            if Ui.isSmall device || not hasCategories then
                []

            else
                [ categoryTags ]
        }


completionDropdownHeight : Device -> List Completion -> Int
completionDropdownHeight device options =
    if Ui.isSmall device then
        min 264 (8 + List.length options * 44)

    else
        min 224 (8 + List.length options * 38)


completionRow : Theme -> (Completion -> msg) -> Completion -> Element msg
completionRow theme onSelect completion =
    Ui.completionRow theme
        { label = Search.completionLabel completion
        , trailing =
            case completion of
                CategoryCompletion _ count ->
                    Just (Ui.badge theme (String.fromInt count))

                OperatorCompletion _ ->
                    Nothing
        , onPress = onSelect completion
        }


metaText : String -> SearchResult -> String
metaText query item =
    [ item.brand
    , if isBarcodeVisible query item then
        item.barcode

      else
        Nothing
    , Maybe.map (\kcal -> kcal ++ " kcal per 100 g") item.nutritionSummary.per100g.energyKcal
    ]
        |> Ui.dotSeparated


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value)
        && String.all Char.isDigit value


categoryPills : Theme -> Device -> List String -> Element msg
categoryPills theme device categories =
    let
        pills : List String
        pills =
            visibleCategories categories
    in
    if List.isEmpty pills then
        Element.none

    else if Ui.isSmall device then
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space4
            ]
            (List.map (categoryPill theme) pills)

    else
        Element.column
            [ Element.width (Element.px 160)
            , Element.spacing DesignTokens.space4
            , Element.alignRight
            ]
            (pills
                |> chunkPairs
                |> List.map (pillRow theme)
            )


visibleCategories : List String -> List String
visibleCategories categories =
    case List.drop 4 categories of
        [] ->
            List.take 4 categories

        hidden ->
            List.take 3 categories ++ [ "+" ++ String.fromInt (List.length hidden + 1) ++ " more" ]


chunkPairs : List a -> List (List a)
chunkPairs items =
    case items of
        [] ->
            []

        first :: second :: rest ->
            [ first, second ] :: chunkPairs rest

        [ first ] ->
            [ [ first ] ]


pillRow : Theme -> List String -> Element msg
pillRow theme pills =
    Element.row
        [ Element.spacing DesignTokens.space4
        , Element.alignRight
        ]
        (List.map (categoryPill theme) pills)


categoryPill : Theme -> String -> Element msg
categoryPill theme label =
    Ui.chip theme
        { label = truncatePillLabel label
        , selected = False
        , onClick = Nothing
        }


truncatePillLabel : String -> String
truncatePillLabel label =
    if String.length label > 10 then
        String.left 9 label ++ "..."

    else
        label
