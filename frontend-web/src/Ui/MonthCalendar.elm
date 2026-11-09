module Ui.MonthCalendar exposing (monthRows, skeleton, view)

import Data.Calendar as Calendar
import Element exposing (Element)
import Element.Font as Font
import Html.Attributes as Attr
import Ui.Common as UiCommon
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
            monthRows config.period
                |> List.map
                    (List.map cell >> Element.row [ Element.width Element.fill ])
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.row [ Element.width Element.fill, UiCommon.testId "calendar-weekdays" ]
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
        , Element.column
            [ Element.width Element.fill, UiCommon.testId "calendar-grid" ]
            rows
        ]


{-| Placeholder with the same grid geometry as `view`, so swapping in loaded
data does not shift the layout. A known period uses the same `monthRows`
partition as `view`; a `Nothing` period renders `rows` neutral weeks for the
pre-date boot shell.
-}
skeleton : Theme -> { period : Maybe String, rows : Int, cellHeight : Int } -> Element msg
skeleton theme config =
    let
        rows : List (List (Maybe Int))
        rows =
            case config.period of
                Just period ->
                    monthRows period

                Nothing ->
                    List.repeat config.rows (List.repeat 7 Nothing)

        cell : Maybe Int -> Element msg
        cell _ =
            Element.el
                [ Element.width (Element.fillPortion 1)
                , Element.height (Element.px config.cellHeight)
                , equalColumn
                ]
                (Skeleton.barCustom theme
                    { width = Element.fill, height = config.cellHeight }
                )

        weekdayPlaceholder : Element msg
        weekdayPlaceholder =
            Element.el
                [ Element.width (Element.fillPortion 1)
                , equalColumn
                ]
                (Skeleton.elLine theme { size = 13, width = Element.fill })
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        , UiCommon.skeletonRegion
        ]
        [ Element.row [ Element.width Element.fill, UiCommon.testId "calendar-weekdays" ]
            (List.repeat 7 weekdayPlaceholder)
        , Element.column
            [ Element.width Element.fill, UiCommon.testId "calendar-grid" ]
            (List.map
                (List.map cell >> Element.row [ Element.width Element.fill ])
                rows
            )
        ]


{-| The shared row partition. Both `view` and `skeleton` use it so the
skeleton row count cannot drift from the real grid.
-}
monthRows : String -> List (List (Maybe Int))
monthRows period =
    Calendar.monthCells period |> chunks 7


equalColumn : Element.Attribute msg
equalColumn =
    Element.htmlAttribute (Attr.attribute "style" "flex: 1 1 0; min-width: 0")


chunks : Int -> List value -> List (List value)
chunks size values =
    if List.isEmpty values then
        []

    else
        List.take size values :: chunks size (List.drop size values)
