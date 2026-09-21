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
import I18n
import Json.Decode as Decode
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.CategoryTag as CategoryTag exposing (CategoryTag)
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Input as UiInput
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients


completionDropdown :
    Env
    -> { id : String, activeIndex : Int, onSelect : Completion -> msg }
    -> List Completion
    -> Element msg
completionDropdown env config options =
    if List.isEmpty options then
        Element.none

    else
        Element.el
            [ Element.htmlAttribute (Html.Attributes.attribute "role" "listbox")
            , Element.htmlAttribute (Html.Attributes.attribute "id" config.id)
            ]
            (UiInput.completionDropdown env.theme
                { height = completionDropdownHeight env.device options
                , rows = List.indexedMap (completionRow env.theme config) options
                }
            )


searchInput :
    Env
    ->
        { id : String
        , onChange : String -> msg
        , text : String
        , label : UiInput.SearchLabel
        , completions : List Completion
        , activeIndex : Int
        , onActiveChanged : Int -> msg
        , onTabComplete : msg
        , onCompletionClick : Completion -> msg
        }
    -> Element msg
searchInput env config =
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
        [ UiInput.searchInput env.theme
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
        , completionDropdown env
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
                                let
                                    nextActive : Int
                                    nextActive =
                                        min
                                            (List.length config.completions - 1)
                                            (config.activeIndex + 1)
                                in
                                Decode.succeed ( config.onActiveChanged nextActive, True )

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


resultRow : Env -> { query : String, item : SearchResult, onSelect : String -> msg } -> Element msg
resultRow env config =
    let
        macroDot : Element msg
        macroDot =
            View.Nutrients.macroDot env
                (config.item.nutritionSummary.per100g |> Nutrition.summaryToNutrients)

        searchItem : Element msg
        searchItem =
            Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
                [ if UiCommon.isSmall env.device then
                    Typography.wrappedListItemTitle env.theme config.item.name

                  else
                    Typography.truncatedListItemTitle env.theme config.item.name
                , Typography.mutedCaptionParagraph
                    env.theme
                    (metaText env.language config.query config.item)
                ]

        tagRows : List (List CategoryTag)
        tagRows =
            if UiCommon.isSmall env.device then
                []

            else
                CategoryTag.rows config.item.categories
    in
    Surface.listRow
        { onSelect = config.onSelect config.item.id
        , leading = [ macroDot ]
        , title = searchItem
        , subtitle = []
        , trailing =
            if List.isEmpty tagRows then
                []

            else
                [ CategoryTag.view env.theme env.language tagRows ]
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


metaText : Language -> String -> SearchResult -> String
metaText language query item =
    [ item.brand
    , if isBarcodeVisible query item then
        item.barcode

      else
        Nothing
    , item.nutritionSummary.per100g.energyKcal
        |> Maybe.map (\kcal -> I18n.t language (TidSearchKcalPer100g kcal))
    ]
        |> Text.dotSeparated


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value) && String.all Char.isDigit value
