module View.Search exposing
    ( resultRow
    , searchInput
    )

import Data.Food exposing (SearchResult)
import Data.Nutrition as Nutrition
import Data.Search as Search exposing (Completion(..))
import Element exposing (Device, Element)
import Html
import Html.Attributes
import Html.Events
import Json.Decode as Decode
import Lib.Text as Text
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Input as UiInput
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


completionDropdown :
    Theme
    -> Device
    -> { id : String, activeIndex : Int, onSelect : Completion -> msg }
    -> List Completion
    -> Element msg
completionDropdown theme device config options =
    if List.isEmpty options then
        Element.none

    else
        Element.el
            [ Element.htmlAttribute (Html.Attributes.attribute "role" "listbox")
            , Element.htmlAttribute (Html.Attributes.attribute "id" config.id)
            ]
            (UiInput.completionDropdown theme
                { height = completionDropdownHeight device options
                , rows = List.indexedMap (completionRow theme config) options
                }
            )


searchInput :
    Theme
    -> Device
    ->
        { id : String
        , onChange : String -> msg
        , text : String
        , label : String
        , completions : List Completion
        , activeIndex : Int
        , onActiveChanged : Int -> msg
        , onTabComplete : msg
        , onCompletionClick : Completion -> msg
        }
    -> Element msg
searchInput theme device config =
    let
        hasCompletions : Bool
        hasCompletions =
            not (List.isEmpty config.completions)

        ariaAttributes : List (Element.Attribute msg)
        ariaAttributes =
            [ Element.htmlAttribute (Html.Attributes.attribute "role" "combobox")
            , Element.htmlAttribute
                (Html.Attributes.attribute
                    "aria-expanded"
                    (if hasCompletions then
                        "true"

                     else
                        "false"
                    )
                )
            , Element.htmlAttribute
                (Html.Attributes.attribute "aria-controls" config.id)
            , Element.htmlAttribute (Html.Attributes.attribute "aria-autocomplete" "list")
            ]
                ++ (if hasCompletions && config.activeIndex >= 0 then
                        [ Element.htmlAttribute
                            (Html.Attributes.attribute
                                "aria-activedescendant"
                                (optionId config.id config.activeIndex)
                            )
                        ]

                    else
                        []
                   )
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
        [ UiInput.searchInput theme
            { onChange = config.onChange
            , text = config.text
            , label = config.label
            , extraAttrs =
                ariaAttributes
                    ++ [ Element.htmlAttribute
                            (keydownHandler
                                { activeIndex = config.activeIndex
                                , completions = config.completions
                                , onActiveChanged = config.onActiveChanged
                                , onTabComplete = config.onTabComplete
                                , onCompletionClick = config.onCompletionClick
                                }
                            )
                       ]
            }
        , completionDropdown theme
            device
            { id = config.id
            , activeIndex = config.activeIndex
            , onSelect = config.onCompletionClick
            }
            config.completions
        ]


keydownHandler :
    { activeIndex : Int
    , completions : List Completion
    , onActiveChanged : Int -> msg
    , onTabComplete : msg
    , onCompletionClick : Completion -> msg
    }
    -> Html.Attribute msg
keydownHandler config =
    Html.Events.preventDefaultOn "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if List.isEmpty config.completions then
                        Decode.fail "no completions"

                    else
                        case key of
                            "Tab" ->
                                Decode.succeed ( config.onTabComplete, True )

                            "ArrowDown" ->
                                Decode.succeed
                                    ( config.onActiveChanged
                                        (min (List.length config.completions - 1) (config.activeIndex + 1))
                                    , True
                                    )

                            "ArrowUp" ->
                                Decode.succeed
                                    ( config.onActiveChanged
                                        (max 0 (config.activeIndex - 1))
                                    , True
                                    )

                            "Enter" ->
                                case completionAt config.activeIndex config.completions of
                                    Just completion ->
                                        Decode.succeed ( config.onCompletionClick completion, True )

                                    Nothing ->
                                        Decode.fail "no active completion"

                            "Escape" ->
                                Decode.succeed ( config.onActiveChanged -1, True )

                            _ ->
                                Decode.fail "unhandled key"
                )
        )


completionAt : Int -> List Completion -> Maybe Completion
completionAt index completions =
    if index < 0 then
        Nothing

    else
        completions |> List.drop index |> List.head


optionId : String -> Int -> String
optionId listboxId index =
    listboxId ++ "-option-" ++ String.fromInt index


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
                [ if UiCommon.isSmall device then
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
            not (List.isEmpty config.item.categories)
    in
    Surface.listRow
        { onSelect = config.onSelect config.item.id
        , leading = [ macroDot ]
        , title = searchItem
        , subtitle =
            if UiCommon.isSmall device && hasCategories then
                [ categoryTags ]

            else
                []
        , trailing =
            if UiCommon.isSmall device || not hasCategories then
                []

            else
                [ categoryTags ]
        }


completionDropdownHeight : Device -> List Completion -> Int
completionDropdownHeight device options =
    if UiCommon.isSmall device then
        min 264 (8 + List.length options * 44)

    else
        min 224 (8 + List.length options * 38)


completionRow :
    Theme
    -> { id : String, activeIndex : Int, onSelect : Completion -> msg }
    -> Int
    -> Completion
    -> Element msg
completionRow theme config index completion =
    Element.el
        [ Element.htmlAttribute (Html.Attributes.attribute "role" "option")
        , Element.htmlAttribute (Html.Attributes.attribute "id" (optionId config.id index))
        , Element.htmlAttribute
            (Html.Attributes.attribute
                "aria-selected"
                (if index == config.activeIndex then
                    "true"

                 else
                    "false"
                )
            )
        ]
        (UiInput.completionRow theme
            { label = Search.completionLabel completion
            , trailing =
                case completion of
                    CategoryCompletion _ count ->
                        Just (Chip.badge theme (String.fromInt count))

                    OperatorCompletion _ ->
                        Nothing
            , onPress = config.onSelect completion
            }
        )


metaText : String -> SearchResult -> String
metaText query item =
    [ item.brand
    , if isBarcodeVisible query item then
        item.barcode

      else
        Nothing
    , Maybe.map (\kcal -> kcal ++ " kcal per 100 g") item.nutritionSummary.per100g.energyKcal
    ]
        |> Text.dotSeparated


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value)
        && String.all Char.isDigit value


categoryPills : Theme -> Device -> List String -> Element msg
categoryPills theme device categories =
    if List.isEmpty categories then
        Element.none

    else if UiCommon.isSmall device then
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space4
            ]
            (List.map (categoryPill theme) categories)

    else
        Element.wrappedRow
            [ Element.width (Element.px 160)
            , Element.spacing DesignTokens.space4
            , Element.alignRight
            ]
            (List.map (categoryPill theme) categories)


categoryPill : Theme -> String -> Element msg
categoryPill theme label =
    Element.el
        [ Element.width (Element.maximum 160 Element.fill)
        , Element.clip
        , UiCommon.uiClass "ui-text-ellipsis"
        ]
        (Chip.chip theme
            { label = label
            , selected = False
            }
        )
