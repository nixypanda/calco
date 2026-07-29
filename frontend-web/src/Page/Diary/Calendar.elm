module Page.Diary.Calendar exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , Status(..)
    , compactCalories
    , contentViewWithSelection
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.Calendar as Calendar
import Data.LogSummary exposing (DaySummary)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html
import Html.Attributes as Attr
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Ui
import Ui.Calendar.Month as MonthCalendar
import Ui.Chart.Ring as Ring
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



-- MODEL


type Status
    = Loading
    | Ready
    | Failed String


type alias Model =
    { today : LocalDate
    , newestMonth : String
    , oldestMonth : String
    , summaries : List DaySummary
    , status : Status
    , loadingEarlier : Bool
    }


init : { monthParam : Maybe String, today : LocalDate } -> ( Model, OutMsg )
init args =
    let
        currentMonth : String
        currentMonth =
            Calendar.monthKey args.today

        newestMonth : String
        newestMonth =
            args.monthParam
                |> Maybe.andThen validMonth
                |> Maybe.map (min currentMonth)
                |> Maybe.withDefault currentMonth

        oldestMonth : String
        oldestMonth =
            Calendar.shiftMonth -5 newestMonth

        model : Model
        model =
            { today = args.today
            , newestMonth = newestMonth
            , oldestMonth = oldestMonth
            , summaries = []
            , status = Loading
            , loadingEarlier = False
            }
    in
    ( model, requestForMonths oldestMonth newestMonth args.today )


validMonth : String -> Maybe String
validMonth period =
    Calendar.monthStart period
        |> Maybe.map (\_ -> period)



-- UPDATE


type Msg
    = SummaryLoaded (Result Client.ApiError (List DaySummary))
    | EarlierSummaryLoaded (Result Client.ApiError (List DaySummary))
    | LoadEarlierClicked
    | DayClicked String String


type OutMsg
    = NoOp
    | RequestSummary LocalDate LocalDate
    | RequestEarlierSummary LocalDate LocalDate
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SummaryLoaded result ->
            applySummaryResult False result model

        EarlierSummaryLoaded result ->
            applySummaryResult True result model

        LoadEarlierClicked ->
            if model.loadingEarlier then
                ( model, Cmd.none, NoOp )

            else
                let
                    nextOldest : String
                    nextOldest =
                        Calendar.shiftMonth -6 model.oldestMonth

                    previousDay : Maybe LocalDate
                    previousDay =
                        Calendar.monthStart model.oldestMonth
                            |> Maybe.map (LocalDate.addDays -1)
                in
                case ( Calendar.monthStart nextOldest, previousDay ) of
                    ( Just fromDate, Just toDate ) ->
                        ( { model
                            | oldestMonth = nextOldest
                            , loadingEarlier = True
                          }
                        , Cmd.none
                        , RequestEarlierSummary fromDate toDate
                        )

                    _ ->
                        ( model, Cmd.none, NoOp )

        DayClicked month date ->
            ( model
            , Cmd.none
            , Navigate (DiaryDay (Just date) (Just month))
            )


applySummaryResult :
    Bool
    -> Result Client.ApiError (List DaySummary)
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
applySummaryResult earlier result model =
    case result of
        Ok summaries ->
            ( { model
                | summaries = mergeSummaries model.summaries summaries
                , status = Ready
                , loadingEarlier = False
              }
            , Cmd.none
            , NoOp
            )

        Err error ->
            if Client.isUnauthorized error then
                ( model, Cmd.none, SessionExpired )

            else
                ( { model
                    | oldestMonth =
                        if earlier then
                            Calendar.shiftMonth 6 model.oldestMonth

                        else
                            model.oldestMonth
                    , status =
                        if earlier && not (List.isEmpty model.summaries) then
                            Ready

                        else
                            Failed (Client.displayError error)
                    , loadingEarlier = False
                  }
                , Cmd.none
                , NoOp
                )


mergeSummaries : List DaySummary -> List DaySummary -> List DaySummary
mergeSummaries existing incoming =
    List.foldl
        (\summary merged ->
            summary
                :: List.filter (.date >> (/=) summary.date) merged
        )
        existing
        incoming
        |> List.sortBy .date


requestForMonths : String -> String -> LocalDate -> OutMsg
requestForMonths oldest newest today =
    case ( Calendar.monthStart oldest, Calendar.monthEnd newest ) of
        ( Just fromDate, Just monthEnd ) ->
            RequestSummary fromDate (LocalDate.clampTo today monthEnd)

        _ ->
            NoOp



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ contentView { model = model, device = device, theme = theme } ]


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView =
    contentViewWithSelection Nothing


contentViewWithSelection :
    Maybe String
    -> { model : Model, device : Device, theme : Theme }
    -> Element Msg
contentViewWithSelection selectedDate { model, device, theme } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        (case model.status of
            Loading ->
                [ Ui.loading theme "Loading calendar" ]

            Failed message ->
                [ Ui.errorBanner theme message ]

            Ready ->
                monthRange model.newestMonth model.oldestMonth
                    |> List.map (monthView theme device model selectedDate)
                    |> (\months ->
                            months
                                ++ [ loadEarlierButton theme device model.loadingEarlier ]
                       )
        )


monthRange : String -> String -> List String
monthRange newest oldest =
    if newest < oldest then
        []

    else
        newest :: monthRange (Calendar.shiftMonth -1 newest) oldest


monthView : Theme -> Device -> Model -> Maybe String -> String -> Element Msg
monthView theme device model selectedDate month =
    Ui.card theme
        [ Typography.sectionTitle theme (Calendar.monthLabel month)
        , MonthCalendar.view
            { period = month
            , weekdayLabels = [ "S", "M", "T", "W", "T", "F", "S" ]
            , weekdayColor = theme.textMuted
            , cellHeight =
                if Ui.isSmall device then
                    68

                else
                    76
            , viewDay = dayView theme model selectedDate month
            }
        ]


dayView :
    Theme
    -> Model
    -> Maybe String
    -> String
    -> Int
    -> List (Element.Attribute Msg)
    -> Element Msg
dayView theme model selectedDate month day attributes =
    let
        date : String
        date =
            Calendar.dayKey month day

        maybeDate : Maybe LocalDate
        maybeDate =
            LocalDate.fromString date

        future : Bool
        future =
            maybeDate
                |> Maybe.map (\value -> LocalDate.compare value model.today == GT)
                |> Maybe.withDefault True

        maybeSummary : Maybe DaySummary
        maybeSummary =
            summaryFor date model.summaries

        label : Element Msg
        label =
            dayLabel theme model.today day date maybeSummary
    in
    if future then
        Element.el
            (Font.color theme.textMuted :: attributes)
            (Element.el [ Element.centerX, Element.centerY ] (Element.text (String.fromInt day)))

    else
        Input.button
            (Border.rounded DesignTokens.radiusSmall
                :: Background.color
                    (if selectedDate == Just date then
                        theme.brandBlueSoft

                     else
                        Element.rgba 0 0 0 0
                    )
                :: Element.htmlAttribute
                    (Attr.attribute "aria-label" (dayAriaLabel date maybeSummary))
                :: Element.htmlAttribute
                    (Attr.attribute
                        "aria-pressed"
                        (if selectedDate == Just date then
                            "true"

                         else
                            "false"
                        )
                    )
                :: attributes
            )
            { onPress = Just (DayClicked month date)
            , label = label
            }


dayLabel :
    Theme
    -> LocalDate
    -> Int
    -> String
    -> Maybe DaySummary
    -> Element msg
dayLabel theme today day date maybeSummary =
    let
        isToday : Bool
        isToday =
            LocalDate.fromString date
                |> Maybe.map (LocalDate.equals today)
                |> Maybe.withDefault False

        number : Element msg
        number =
            Element.el
                [ Element.width (Element.px 38)
                , Element.height (Element.px 38)
                , Element.centerX
                , Element.centerY
                , Border.rounded DesignTokens.radiusPill
                , Border.width
                    (if isToday then
                        1

                     else
                        0
                    )
                , Border.color theme.brandBlue
                , Font.center
                ]
                (Element.el [ Element.centerX, Element.centerY ]
                    (Element.text (String.fromInt day))
                )
    in
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.centerX
        , Element.spacing 4
        , Element.paddingXY 1 3
        ]
        [ Element.el [ Element.centerX ]
            (case maybeSummary of
                Just summary ->
                    Ring.view
                        { size = 38
                        , thickness = 4
                        , gap = 2
                        , segments = macroSegments theme summary
                        , emptyColor = theme.calorieAccent
                        , centerColor =
                            if isToday then
                                theme.brandBlueSoft

                            else
                                theme.cardBg
                        , label = dayAriaLabel date maybeSummary
                        , center =
                            Html.span
                                [ Attr.style "font-size" "13px"
                                , Attr.style "font-weight" "600"
                                ]
                                [ Html.text (String.fromInt day) ]
                        }

                Nothing ->
                    number
            )
        , case maybeSummary of
            Just summary ->
                Element.el
                    [ Element.centerX
                    , Font.size 11
                    , Font.semiBold
                    , Font.color theme.textMedium
                    ]
                    (Element.text (compactCalories summary.energyKcal))

            Nothing ->
                Element.el [ Element.height (Element.px 14) ] Element.none
        ]


macroSegments : Theme -> DaySummary -> List Ring.Segment
macroSegments theme summary =
    [ { color = theme.proteinAccent, value = summary.proteinG * 4 }
    , { color = theme.carbsAccent, value = summary.carbsG * 4 }
    , { color = theme.fatAccent, value = summary.fatG * 9 }
    ]


summaryFor : String -> List DaySummary -> Maybe DaySummary
summaryFor date summaries =
    List.filter (.date >> (==) date) summaries
        |> List.head


compactCalories : Float -> String
compactCalories calories =
    if calories >= 1000 then
        Number.toFixedTrimmed 1 (calories / 1000) ++ "k"

    else
        String.fromInt (round calories)


dayAriaLabel : String -> Maybe DaySummary -> String
dayAriaLabel date maybeSummary =
    case maybeSummary of
        Just summary ->
            date
                ++ ", "
                ++ String.fromInt (round summary.energyKcal)
                ++ " kilocalories logged"

        Nothing ->
            date ++ ", no food logged"


loadEarlierButton : Theme -> Device -> Bool -> Element Msg
loadEarlierButton theme device loading =
    Input.button
        [ Element.width
            (if Ui.isSmall device then
                Element.fill

             else
                Element.px 220
            )
        , Element.centerX
        , Element.paddingXY DesignTokens.space16 DesignTokens.space12
        , Background.color theme.brandBlueSoft
        , Font.color theme.brandBlue
        , Font.center
        , Font.semiBold
        , Border.rounded DesignTokens.radiusControl
        ]
        { onPress =
            if loading then
                Nothing

            else
                Just LoadEarlierClicked
        , label =
            Element.text
                (if loading then
                    "Loading…"

                 else
                    "Load earlier"
                )
        }
