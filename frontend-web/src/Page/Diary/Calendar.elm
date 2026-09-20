module Page.Diary.Calendar exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , Status(..)
    , compactCalories
    , contentViewWithSelection
    , init
    , update
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
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.MonthCalendar as MonthCalendar
import Ui.RingChart as Ring
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



-- MODEL


type Status
    = Loading
    | Ready
    | LoadingEarlier
    | Failed String


type alias Model =
    { today : LocalDate
    , newestMonth : String
    , oldestMonth : String
    , summaries : List DaySummary
    , status : Status
    , loadToken : Int
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
            , loadToken = 0
            }
    in
    ( model, requestForMonths 0 oldestMonth newestMonth args.today )


validMonth : String -> Maybe String
validMonth period =
    Calendar.monthStart period
        |> Maybe.map (\_ -> period)



-- UPDATE


type Msg
    = SummaryLoaded Int (Result Client.ApiError (List DaySummary))
    | EarlierSummaryLoaded Int (Result Client.ApiError (List DaySummary))
    | DayTotalsKnown LocalDate (Maybe DaySummary)
    | LoadEarlierClicked
    | DayClicked String String
    | TodayChanged LocalDate
    | RetryClicked


type OutMsg
    = NoOp
    | RequestSummary Int LocalDate LocalDate
    | RequestEarlierSummary Int LocalDate LocalDate
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SummaryLoaded token result ->
            if token /= model.loadToken then
                ( model, Cmd.none, NoOp )

            else
                applySummaryResult False result model

        EarlierSummaryLoaded token result ->
            if token /= model.loadToken then
                ( model, Cmd.none, NoOp )

            else
                applySummaryResult True result model

        DayTotalsKnown date summary ->
            if dateIsLoaded date model then
                ( { model | summaries = replaceDay date summary model.summaries }
                , Cmd.none
                , NoOp
                )

            else
                ( model, Cmd.none, NoOp )

        LoadEarlierClicked ->
            case model.status of
                Ready ->
                    loadEarlier model

                _ ->
                    ( model, Cmd.none, NoOp )

        DayClicked month date ->
            ( model
            , Cmd.none
            , Navigate (DiaryDay (Just date) (Just month))
            )

        TodayChanged today ->
            ( { model | today = today }, Cmd.none, NoOp )

        RetryClicked ->
            let
                token : Int
                token =
                    model.loadToken + 1
            in
            ( { model | status = Loading, loadToken = token }
            , Cmd.none
            , requestForMonths token model.oldestMonth model.newestMonth model.today
            )


replaceDay : LocalDate -> Maybe DaySummary -> List DaySummary -> List DaySummary
replaceDay date summary existing =
    mergeSummaries
        (List.filter (\other -> not (LocalDate.equals other.date date)) existing)
        (summary |> Maybe.map List.singleton |> Maybe.withDefault [])


dateIsLoaded : LocalDate -> Model -> Bool
dateIsLoaded date model =
    let
        dateKey : String
        dateKey =
            LocalDate.format date

        earliest : Maybe String
        earliest =
            Calendar.monthStart model.oldestMonth |> Maybe.map LocalDate.format

        latest : Maybe String
        latest =
            Calendar.monthEnd model.newestMonth
                |> Maybe.map (LocalDate.clampTo model.today)
                |> Maybe.map LocalDate.format
    in
    case ( earliest, latest ) of
        ( Just first, Just last ) ->
            dateKey >= first && dateKey <= last

        _ ->
            False


loadEarlier : Model -> ( Model, Cmd Msg, OutMsg )
loadEarlier model =
    let
        token : Int
        token =
            model.loadToken + 1

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
            ( { model | oldestMonth = nextOldest, status = LoadingEarlier, loadToken = token }
            , Cmd.none
            , RequestEarlierSummary token fromDate toDate
            )

        _ ->
            ( model, Cmd.none, NoOp )


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
                  }
                , Cmd.none
                , NoOp
                )


mergeSummaries : List DaySummary -> List DaySummary -> List DaySummary
mergeSummaries existing incoming =
    List.foldl
        (\summary merged ->
            summary
                :: List.filter (\other -> not (LocalDate.equals other.date summary.date)) merged
        )
        existing
        incoming
        |> List.sortBy (.date >> LocalDate.format)


requestForMonths : Int -> String -> String -> LocalDate -> OutMsg
requestForMonths token oldest newest today =
    case ( Calendar.monthStart oldest, Calendar.monthEnd newest ) of
        ( Just fromDate, Just monthEnd ) ->
            RequestSummary token fromDate (LocalDate.clampTo today monthEnd)

        _ ->
            NoOp



-- VIEW


contentViewWithSelection :
    Maybe LocalDate
    -> { model : Model, device : Device, theme : Theme, language : Language }
    -> Element Msg
contentViewWithSelection selectedDate { model, device, theme, language } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        (case model.status of
            Loading ->
                calendarSkeleton theme model

            Failed message ->
                [ Feedback.errorRetry theme
                    language
                    device
                    { message = message, onRetry = RetryClicked }
                ]

            Ready ->
                monthsView device theme language model selectedDate False

            LoadingEarlier ->
                monthsView device theme language model selectedDate True
        )


monthsView : Device -> Theme -> Language -> Model -> Maybe LocalDate -> Bool -> List (Element Msg)
monthsView device theme language model selectedDate loadingEarlier =
    monthRange model.newestMonth model.oldestMonth
        |> List.map (monthView theme language model selectedDate)
        |> (\months -> months ++ [ loadEarlierButton device theme language loadingEarlier ])


monthRange : String -> String -> List String
monthRange newest oldest =
    if newest < oldest then
        []

    else
        newest :: monthRange (Calendar.shiftMonth -1 newest) oldest


monthCellHeight : Int
monthCellHeight =
    68


calendarSkeleton : Theme -> Model -> List (Element msg)
calendarSkeleton theme model =
    monthRange model.newestMonth model.oldestMonth
        |> List.map (monthSkeleton theme)
        |> (\months -> months ++ [ Skeleton.button theme ])


monthSkeleton : Theme -> String -> Element msg
monthSkeleton theme month =
    Surface.section theme
        { header =
            Just
                (Skeleton.barCustom theme
                    { width = Element.px 140
                    , height = 24
                    }
                )
        , body =
            [ MonthCalendar.skeleton theme
                { period = month
                , cellHeight = monthCellHeight
                }
            ]
        , footer = Nothing
        }


monthView : Theme -> Language -> Model -> Maybe LocalDate -> String -> Element Msg
monthView theme language model selectedDate month =
    Surface.section theme
        { header = Just (Typography.sectionTitle theme (Calendar.monthLabel language month))
        , body =
            [ MonthCalendar.view
                { period = month
                , weekdayLabels =
                    [ I18n.t language TidDiaryCalendarWeekdaySun
                    , I18n.t language TidDiaryCalendarWeekdayMon
                    , I18n.t language TidDiaryCalendarWeekdayTue
                    , I18n.t language TidDiaryCalendarWeekdayWed
                    , I18n.t language TidDiaryCalendarWeekdayThu
                    , I18n.t language TidDiaryCalendarWeekdayFri
                    , I18n.t language TidDiaryCalendarWeekdaySat
                    ]
                , weekdayColor = theme.textMuted
                , cellHeight = monthCellHeight
                , viewDay = dayView theme language model selectedDate month
                }
            ]
        , footer = Nothing
        }


dayView :
    Theme
    -> Language
    -> Model
    -> Maybe LocalDate
    -> String
    -> Int
    -> List (Element.Attribute Msg)
    -> Element Msg
dayView theme language model selectedDate month day attributes =
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
            maybeDate |> Maybe.andThen (\value -> summaryFor value model.summaries)

        label : Element Msg
        label =
            dayLabel theme language model.today day date maybeSummary
    in
    if future then
        Element.el
            (Font.color theme.textMuted :: attributes)
            (Element.el [ Element.centerX, Element.centerY ] (Element.text (String.fromInt day)))

    else
        Input.button
            (Border.rounded DesignTokens.radiusSmall
                :: Background.color
                    (if selectedDate == maybeDate then
                        theme.brandBlueSoft

                     else
                        Element.rgba 0 0 0 0
                    )
                :: Element.htmlAttribute
                    (Attr.attribute "aria-label" (dayAriaLabel language date maybeSummary))
                :: Element.htmlAttribute
                    (Attr.attribute
                        "aria-pressed"
                        (if selectedDate == maybeDate then
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
    -> Language
    -> LocalDate
    -> Int
    -> String
    -> Maybe DaySummary
    -> Element msg
dayLabel theme language today day date maybeSummary =
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
        , Element.spacing DesignTokens.space4
        , Element.paddingXY DesignTokens.space2 DesignTokens.space4
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
                        , label = dayAriaLabel language date maybeSummary
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
                    , Typography.caption
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


summaryFor : LocalDate -> List DaySummary -> Maybe DaySummary
summaryFor date summaries =
    List.filter (\summary -> LocalDate.equals summary.date date) summaries
        |> List.head


compactCalories : Float -> String
compactCalories calories =
    if calories >= 1000 then
        Number.toFixedTrimmed 1 (calories / 1000) ++ "k"

    else
        String.fromInt (round calories)


dayAriaLabel : Language -> String -> Maybe DaySummary -> String
dayAriaLabel language date maybeSummary =
    case maybeSummary of
        Just summary ->
            I18n.t language
                (TidDiaryCalendarDayAriaLogged
                    date
                    (String.fromInt (round summary.energyKcal))
                )

        Nothing ->
            I18n.t language (TidDiaryCalendarDayAriaNoFood date)


loadEarlierButton : Device -> Theme -> Language -> Bool -> Element Msg
loadEarlierButton device theme language loading =
    Button.textButton device
        theme
        { tone = Button.GhostFilled
        , width = Button.FullWidth
        , label =
            if loading then
                I18n.t language TidCommonLoading

            else
                I18n.t language TidDiaryCalendarLoadEarlier
        , onPress = LoadEarlierClicked
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
