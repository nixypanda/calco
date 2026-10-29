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
import Element exposing (Element)
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
import Ui.Env exposing (Env)
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
    Calendar.monthStart period |> Maybe.map (\_ -> period)



-- UPDATE


type Msg
    = SummaryLoaded Int (Result Client.ApiError (List DaySummary))
    | EarlierSummaryLoaded Int (Result Client.ApiError (List DaySummary))
    | DayTotalsKnown LocalDate (Maybe DaySummary)
    | LoadEarlierClicked
    | DayClicked String LocalDate
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
                ( { model | summaries = replaceDay date summary model.summaries }, Cmd.none, NoOp )

            else
                ( model, Cmd.none, NoOp )

        LoadEarlierClicked ->
            case model.status of
                Ready ->
                    loadEarlier model

                _ ->
                    ( model, Cmd.none, NoOp )

        DayClicked month date ->
            ( model, Cmd.none, Navigate (DiaryDay (Just date) (Just month)) )

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
    mergeSummaries (List.filter (\other -> not (LocalDate.equals other.date date)) existing)
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
            Calendar.monthStart model.oldestMonth |> Maybe.map (LocalDate.addDays -1)
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
            ( { model | summaries = mergeSummaries model.summaries summaries, status = Ready }
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
            summary :: List.filter (\other -> not (LocalDate.equals other.date summary.date)) merged
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


contentViewWithSelection : Env -> Maybe LocalDate -> Model -> Element Msg
contentViewWithSelection env selectedDate model =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        (case model.status of
            Loading ->
                calendarSkeleton env.theme model

            Failed message ->
                [ Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = message, onRetry = RetryClicked }
                ]

            Ready ->
                monthsView env model selectedDate False

            LoadingEarlier ->
                monthsView env model selectedDate True
        )


monthsView : Env -> Model -> Maybe LocalDate -> Bool -> List (Element Msg)
monthsView env model selectedDate loadingEarlier =
    monthRange model.newestMonth model.oldestMonth
        |> List.map (monthView env model selectedDate)
        |> (\months -> months ++ [ loadEarlierButton env loadingEarlier ])


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
            Just (Skeleton.barCustom theme { width = Element.px 140, height = 24 })
        , body =
            [ MonthCalendar.skeleton theme { period = month, cellHeight = monthCellHeight } ]
        , footer = Nothing
        }


monthView : Env -> Model -> Maybe LocalDate -> String -> Element Msg
monthView env model selectedDate month =
    Surface.section env.theme
        { header = Just (Typography.sectionTitle env.theme (Calendar.monthLabel env.language month))
        , body =
            [ MonthCalendar.view
                { period = month
                , weekdayLabels =
                    [ I18n.t env.language TidDiaryCalendarWeekdaySun
                    , I18n.t env.language TidDiaryCalendarWeekdayMon
                    , I18n.t env.language TidDiaryCalendarWeekdayTue
                    , I18n.t env.language TidDiaryCalendarWeekdayWed
                    , I18n.t env.language TidDiaryCalendarWeekdayThu
                    , I18n.t env.language TidDiaryCalendarWeekdayFri
                    , I18n.t env.language TidDiaryCalendarWeekdaySat
                    ]
                , weekdayColor = env.theme.textMuted
                , cellHeight = monthCellHeight
                , viewDay = dayView env model selectedDate month
                }
            ]
        , footer = Nothing
        }


dayView :
    Env
    -> Model
    -> Maybe LocalDate
    -> String
    -> Int
    -> List (Element.Attribute Msg)
    -> Element Msg
dayView env model selectedDate month day attributes =
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
            dayLabel env model.today day date maybeSummary
    in
    if future then
        Element.el (Font.color env.theme.textMuted :: attributes)
            (Element.el [ Element.centerX, Element.centerY ] (Element.text (String.fromInt day)))

    else
        Input.button
            (Border.rounded DesignTokens.radiusSmall
                :: Background.color
                    (if selectedDate == maybeDate then
                        env.theme.brandBlueSoft

                     else
                        Element.rgba 0 0 0 0
                    )
                :: Element.htmlAttribute
                    (Attr.attribute "aria-label" (dayAriaLabel env.language date maybeSummary))
                :: Element.htmlAttribute
                    (Attr.attribute "aria-pressed"
                        (if selectedDate == maybeDate then
                            "true"

                         else
                            "false"
                        )
                    )
                :: attributes
            )
            { onPress = Maybe.map (DayClicked month) maybeDate, label = label }


dayLabel : Env -> LocalDate -> Int -> String -> Maybe DaySummary -> Element msg
dayLabel env today day date maybeSummary =
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
                , Border.color env.theme.brandBlue
                , Font.center
                ]
                (Element.el
                    [ Element.centerX, Element.centerY ]
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
                        , segments = macroSegments env.theme summary
                        , emptyColor = env.theme.calorieAccent
                        , centerColor =
                            if isToday then
                                env.theme.brandBlueSoft

                            else
                                env.theme.cardBg
                        , label = dayAriaLabel env.language date maybeSummary
                        , center =
                            Html.span
                                [ Attr.style "font-size" "13px", Attr.style "font-weight" "600" ]
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
                    , Font.color env.theme.textMedium
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
    List.filter (\summary -> LocalDate.equals summary.date date) summaries |> List.head


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
                (TidDiaryCalendarDayAriaLogged date (String.fromInt (round summary.energyKcal)))

        Nothing ->
            I18n.t language (TidDiaryCalendarDayAriaNoFood date)


loadEarlierButton : Env -> Bool -> Element Msg
loadEarlierButton env loading =
    Button.textButton env.device
        env.theme
        { tone = Button.GhostFilled
        , width = Button.FullWidth
        , label =
            if loading then
                I18n.t env.language TidCommonLoading

            else
                I18n.t env.language TidDiaryCalendarLoadEarlier
        , onPress = LoadEarlierClicked
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
