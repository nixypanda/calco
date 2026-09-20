module Ui.MonthCalendar exposing (skeleton, view)

import Data.Calendar as Calendar
import Element exposing (Element)
import Element.Font as Font
import Html.Attributes as Attr
import Ui.DesignTokens as DesignTokens
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


view :
    { period : String
    , weekdayLabels : List String
    , weekdayColor : Element.Color
    , cellHeight : Int
    , viewDay : Int -> List (Element.Attribute msg) -> Element msg
    }
    -> Element msg
view config =
    let
        attributes : List (Element.Attribute msg)
        attributes =
            [ Element.width (Element.fillPortion 1)
            , Element.height (Element.px config.cellHeight)
            , equalColumn
            ]

        cell : Maybe Int -> Element msg
        cell maybeDay =
            case maybeDay of
                Nothing ->
                    Element.el attributes Element.none

                Just day ->
                    config.viewDay day attributes

        rows : List (Element msg)
        rows =
            Calendar.monthCells config.period
                |> chunks 7
                |> List.map
                    (List.map cell
                        >> Element.row [ Element.width Element.fill ]
                    )
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.row [ Element.width Element.fill ]
            (List.map
                (\label ->
                    Element.el
                        [ Element.width (Element.fillPortion 1)
                        , equalColumn
                        , Font.center
                        , Typography.caption
                        , Font.color config.weekdayColor
                        ]
                        (Element.text label)
                )
                config.weekdayLabels
            )
        , Element.column [ Element.width Element.fill ] rows
        ]


{-| Placeholder with the same grid geometry as `view`, so swapping in loaded
data does not shift the layout.
-}
skeleton : Theme -> { period : String, cellHeight : Int } -> Element msg
skeleton theme config =
    Calendar.monthCells config.period
        |> chunks 7
        |> List.map
            (List.map
                (\_ ->
                    Skeleton.barCustom theme
                        { width = Element.fillPortion 1
                        , height = config.cellHeight
                        }
                )
                >> Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space2 ]
            )
        |> Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space2 ]


equalColumn : Element.Attribute msg
equalColumn =
    Element.htmlAttribute (Attr.attribute "style" "flex: 1 1 0; min-width: 0")


chunks : Int -> List value -> List (List value)
chunks size values =
    if List.isEmpty values then
        []

    else
        List.take size values :: chunks size (List.drop size values)
