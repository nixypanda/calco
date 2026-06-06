module View.Search exposing
    ( resultRow
    , searchInput
    )

import Api.Foods exposing (SearchResult)
import Data.Nutrition as Nutrition
import Data.Search as Search exposing (Completion(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html
import Html.Events
import Json.Decode as Decode
import Ui
import View.Nutrients


completionDropdown : { onSelect : Completion -> msg } -> List Completion -> Element msg
completionDropdown config options =
    if List.isEmpty options then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.height (Element.px (completionDropdownHeight options))
            , Element.scrollbarY
            , Element.spacing 2
            , Element.padding 4
            , Border.rounded 12
            , Background.color Ui.cardBg
            , Ui.cardShadow
            ]
            (List.map (completionRow config.onSelect) options)


searchInput :
    { onChange : String -> msg
    , text : String
    , label : String
    , completions : List Completion
    , onTabComplete : msg
    , onCompletionClick : Completion -> msg
    }
    -> Element msg
searchInput config =
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Input.text
            [ Border.rounded 12
            , Background.color Ui.inputFill
            , Element.padding 12
            , Element.htmlAttribute (tabCompletionHandler config.onTabComplete config.completions)
            ]
            { onChange = config.onChange
            , text = config.text
            , placeholder = Nothing
            , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text config.label)
            }
        , completionDropdown { onSelect = config.onCompletionClick } config.completions
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
    Device
    -> { query : String, item : SearchResult, onSelect : String -> msg }
    -> Element msg
resultRow device config =
    let
        maybeCategoryTags : List (Element msg)
        maybeCategoryTags =
            if Ui.isSmall device then
                []

            else
                [ categoryPills config.item.categories ]

        macroDot : Element msg
        macroDot =
            View.Nutrients.macroDot
                (config.item.nutritionSummary.per100g |> Nutrition.summaryToNutrients)

        searchItem : Element msg
        searchItem =
            Element.column
                [ Element.width Element.fill
                , Element.spacing 4
                , Element.clip
                ]
                [ Element.el [ Font.medium ]
                    (Element.text
                        (Ui.truncateWithEllipsis (Ui.truncationCap device) config.item.name)
                    )
                , Element.el
                    [ Ui.caption, Font.color Ui.mutedColor ]
                    (Element.text (metaText config.query config.item))
                ]
    in
    Input.button
        [ Element.width Element.fill
        , Element.padding 16
        ]
        { onPress = Just (config.onSelect config.item.id)
        , label =
            Element.row
                [ Element.width Element.fill
                , Element.spacing 12
                ]
                ([ macroDot, searchItem ] ++ maybeCategoryTags)
        }


completionDropdownHeight : List Completion -> Int
completionDropdownHeight options =
    min 224 (8 + List.length options * 38)


completionRow : (Completion -> msg) -> Completion -> Element msg
completionRow onSelect completion =
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY 12 10
        , Border.rounded 999
        ]
        { onPress = Just (onSelect completion)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 8 ]
                [ Element.el
                    [ Element.width Element.fill, Font.medium ]
                    (Element.text (Search.completionLabel completion))
                , case completion of
                    CategoryCompletion _ count ->
                        Ui.badge (String.fromInt count)

                    OperatorCompletion _ ->
                        Element.none
                ]
        }


metaText : String -> SearchResult -> String
metaText query item =
    [ item.brand
    , if isBarcodeVisible query item then
        item.barcode

      else
        Nothing
    , Maybe.map (\kcal -> kcal ++ " kcal per 100 g") item.energyKcalPer100g
    ]
        |> List.filterMap identity
        |> String.join " ⋅ "


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value)
        && String.all Char.isDigit value


categoryPills : List String -> Element msg
categoryPills categories =
    let
        pills : List String
        pills =
            visibleCategories categories
    in
    if List.isEmpty pills then
        Element.none

    else
        Element.column
            [ Element.width (Element.px 160)
            , Element.spacing 4
            , Element.alignRight
            ]
            (pills
                |> chunkPairs
                |> List.map pillRow
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


pillRow : List String -> Element msg
pillRow pills =
    Element.row
        [ Element.spacing 4
        , Element.alignRight
        ]
        (List.map categoryPill pills)


categoryPill : String -> Element msg
categoryPill label =
    Ui.chip
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
