module Data.Route exposing
    ( Route(..)
    , fromUrl
    , primaryRoute
    , routeToPath
    )

import Data.MealSlot as MealSlot exposing (MealSlot)
import Lib.Date as LocalDate exposing (LocalDate)
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), (<?>), Parser, oneOf, s, top)
import Url.Parser.Query as Query


type Route
    = Root
    | BootstrapSetup
    | AuthLogin
    | AdminDashboard
    | AdminCreateUser
    | AdminEditUser String
    | DiaryDay (Maybe LocalDate) (Maybe String)
    | DiaryCalendar (Maybe String)
    | NutritionDetails (Maybe LocalDate)
    | GoalSettings
    | DiarySettings
    | SettingsApiKeys
    | SettingsApiKeyCreate
    | FoodLogEntry String (Maybe LocalDate) (Maybe String)
    | AdHocLogCreate (Maybe LocalDate) (Maybe MealSlot)
    | AiLogCreate (Maybe LocalDate) (Maybe MealSlot)
    | FoodSearch (Maybe LocalDate) (Maybe MealSlot)
    | FoodShow String (Maybe LocalDate) (Maybe MealSlot) (Maybe String)
    | CustomFoodList
    | CustomFoodCreate
    | CustomFoodCreateWithAi
    | CustomFoodEdit String
    | CustomFoodShow String
    | MealList
    | MealCreate
    | MealShow String
    | MealEdit String
    | NotFound


fromUrl : Url -> Route
fromUrl url =
    Parser.parse routeParser url |> Maybe.withDefault NotFound


routeParser : Parser (Route -> a) a
routeParser =
    oneOf
        [ Parser.map Root top
        , Parser.map BootstrapSetup (s "setup")
        , Parser.map AuthLogin (s "login")
        , Parser.map AdminDashboard (s "admin")
        , Parser.map AdminCreateUser (s "admin" </> s "users" </> s "new")
        , Parser.map AdminEditUser (s "admin" </> s "users" </> pathSegment </> s "edit")
        , Parser.map DiaryDay (s "home" <?> dateQuery <?> Query.string "calendar_month")
        , Parser.map DiaryCalendar (s "calendar" <?> Query.string "month")
        , Parser.map NutritionDetails (s "details" <?> dateQuery)
        , Parser.map GoalSettings (s "settings" </> s "goals")
        , Parser.map DiarySettings (s "settings" </> s "diary")
        , Parser.map SettingsApiKeys (s "settings" </> s "api-keys")
        , Parser.map SettingsApiKeyCreate (s "settings" </> s "api-keys" </> s "new")
        , Parser.map AdHocLogCreate
            (s "logs" </> s "new" </> s "ad-hoc" <?> dateQuery <?> mealSlotQuery)
        , Parser.map AiLogCreate (s "logs" </> s "new" </> s "ai" <?> dateQuery <?> mealSlotQuery)
        , Parser.map FoodLogEntry
            (s "logs" </> pathSegment <?> dateQuery <?> Query.string "calendar_month")
        , Parser.map FoodSearch (s "search" <?> dateQuery <?> mealSlotQuery)
        , Parser.map CustomFoodList (s "foods" </> s "custom")
        , Parser.map CustomFoodCreateWithAi (s "foods" </> s "custom" </> s "new" </> s "ai")
        , Parser.map CustomFoodCreate (s "foods" </> s "custom" </> s "new")
        , Parser.map CustomFoodEdit (s "foods" </> s "custom" </> pathSegment </> s "edit")
        , Parser.map CustomFoodShow (s "foods" </> s "custom" </> pathSegment)
        , Parser.map FoodShow
            (s "foods"
                </> pathSegment
                <?> dateQuery
                <?> mealSlotQuery
                <?> Query.string "lookup_note"
            )
        , Parser.map MealList (s "meals")
        , Parser.map MealCreate (s "meals" </> s "new")
        , Parser.map MealEdit (s "meals" </> pathSegment </> s "edit")
        , Parser.map MealShow (s "meals" </> pathSegment)
        ]


{-| Url.Parser's built-in `string` leaves percent escapes untouched. Dynamic
routes are written with `Url.percentEncode`, so the parser must decode exactly
once to recover the original ID. A malformed raw escape such as `/foods/100%`
stays verbatim instead of turning the whole route into `NotFound`.
-}
pathSegment : Parser (String -> a) a
pathSegment =
    Parser.custom "SEGMENT" (\raw -> Just (Maybe.withDefault raw (Url.percentDecode raw)))


mealSlotQuery : Query.Parser (Maybe MealSlot)
mealSlotQuery =
    Query.string "meal_slot" |> Query.map (Maybe.andThen MealSlot.fromString)


dateQuery : Query.Parser (Maybe LocalDate)
dateQuery =
    Query.string "date" |> Query.map (Maybe.andThen LocalDate.fromString)


primaryRoute : Route -> Route
primaryRoute route =
    case route of
        FoodShow _ maybeDate maybeSlot _ ->
            FoodSearch maybeDate maybeSlot

        CustomFoodCreate ->
            CustomFoodList

        CustomFoodCreateWithAi ->
            CustomFoodList

        CustomFoodEdit _ ->
            CustomFoodList

        CustomFoodShow _ ->
            CustomFoodList

        AdminCreateUser ->
            AdminDashboard

        AdminEditUser _ ->
            AdminDashboard

        MealCreate ->
            MealList

        SettingsApiKeyCreate ->
            SettingsApiKeys

        MealShow _ ->
            MealList

        MealEdit _ ->
            MealList

        FoodLogEntry _ _ _ ->
            DiaryDay Nothing Nothing

        AdHocLogCreate maybeDate maybeSlot ->
            FoodSearch maybeDate maybeSlot

        AiLogCreate maybeDate maybeSlot ->
            FoodSearch maybeDate maybeSlot

        DiaryDay _ _ ->
            DiaryDay Nothing Nothing

        DiaryCalendar _ ->
            DiaryDay Nothing Nothing

        NutritionDetails _ ->
            DiaryDay Nothing Nothing

        FoodSearch maybeDate maybeSlot ->
            FoodSearch maybeDate maybeSlot

        other ->
            other


routeToPath : Route -> String
routeToPath route =
    case route of
        Root ->
            "/"

        BootstrapSetup ->
            "/setup"

        AuthLogin ->
            "/login"

        AdminDashboard ->
            "/admin"

        AdminCreateUser ->
            "/admin/users/new"

        AdminEditUser id ->
            "/admin/users/" ++ pathSegmentToString id ++ "/edit"

        DiaryDay maybeDate maybeCalendarMonth ->
            withQueryParams "/home"
                [ Maybe.map
                    (\date -> "date=" ++ Url.percentEncode (LocalDate.format date))
                    maybeDate
                , Maybe.map (\month -> "calendar_month=" ++ Url.percentEncode month)
                    maybeCalendarMonth
                ]

        DiaryCalendar maybeMonth ->
            withQueryParams "/calendar"
                [ Maybe.map (\month -> "month=" ++ Url.percentEncode month) maybeMonth ]

        NutritionDetails maybeDate ->
            withQueryParams "/details"
                [ Maybe.map
                    (\date -> "date=" ++ Url.percentEncode (LocalDate.format date))
                    maybeDate
                ]

        GoalSettings ->
            "/settings/goals"

        DiarySettings ->
            "/settings/diary"

        SettingsApiKeys ->
            "/settings/api-keys"

        SettingsApiKeyCreate ->
            "/settings/api-keys/new"

        FoodLogEntry id maybeDate maybeCalendarMonth ->
            withQueryParams ("/logs/" ++ pathSegmentToString id)
                [ Maybe.map
                    (\date -> "date=" ++ Url.percentEncode (LocalDate.format date))
                    maybeDate
                , Maybe.map (\month -> "calendar_month=" ++ Url.percentEncode month)
                    maybeCalendarMonth
                ]

        AdHocLogCreate maybeDate maybeSlot ->
            withFoodCtx "/logs/new/ad-hoc" maybeDate maybeSlot

        AiLogCreate maybeDate maybeSlot ->
            withFoodCtx "/logs/new/ai" maybeDate maybeSlot

        FoodSearch maybeDate maybeSlot ->
            withFoodCtx "/search" maybeDate maybeSlot

        FoodShow id maybeDate maybeSlot lookupNote ->
            withQueryParams ("/foods/" ++ pathSegmentToString id)
                [ Maybe.map
                    (\date -> "date=" ++ Url.percentEncode (LocalDate.format date))
                    maybeDate
                , Maybe.map (\slot -> "meal_slot=" ++ MealSlot.toString slot) maybeSlot
                , Maybe.map (\note -> "lookup_note=" ++ Url.percentEncode note) lookupNote
                ]

        CustomFoodList ->
            "/foods/custom"

        CustomFoodCreate ->
            "/foods/custom/new"

        CustomFoodCreateWithAi ->
            "/foods/custom/new/ai"

        CustomFoodEdit id ->
            "/foods/custom/" ++ pathSegmentToString id ++ "/edit"

        CustomFoodShow id ->
            "/foods/custom/" ++ pathSegmentToString id

        MealList ->
            "/meals"

        MealCreate ->
            "/meals/new"

        MealShow id ->
            "/meals/" ++ pathSegmentToString id

        MealEdit id ->
            "/meals/" ++ pathSegmentToString id ++ "/edit"

        NotFound ->
            "/"


{-| Encode a dynamic path segment so reserved characters cannot split the
path, the query, or the fragment. `"new"` and `"custom"` also get their first
character escaped because otherwise `/meals/new` could only mean `MealCreate`,
and `/foods/custom` could only mean `CustomFoodList`.
-}
pathSegmentToString : String -> String
pathSegmentToString value =
    let
        encoded : String
        encoded =
            Url.percentEncode value
    in
    if List.member encoded [ "new", "custom" ] then
        escapeFirstCharacter encoded

    else
        encoded


escapeFirstCharacter : String -> String
escapeFirstCharacter value =
    case String.uncons value of
        Just ( first, rest ) ->
            "%" ++ hexByte (Char.toCode first) ++ rest

        Nothing ->
            value


hexByte : Int -> String
hexByte value =
    String.fromList [ hexDigit (value // 16), hexDigit (modBy 16 value) ]


hexDigit : Int -> Char
hexDigit value =
    Char.fromCode
        (if value < 10 then
            Char.toCode '0' + value

         else
            Char.toCode 'A' + value - 10
        )


withFoodCtx : String -> Maybe LocalDate -> Maybe MealSlot -> String
withFoodCtx path maybeDate maybeSlot =
    let
        params : List String
        params =
            List.filterMap identity
                [ Maybe.map
                    (\date -> "date=" ++ Url.percentEncode (LocalDate.format date))
                    maybeDate
                , Maybe.map (\slot -> "meal_slot=" ++ MealSlot.toString slot) maybeSlot
                ]
    in
    if List.isEmpty params then
        path

    else
        path ++ "?" ++ String.join "&" params


withQueryParams : String -> List (Maybe String) -> String
withQueryParams path maybeParams =
    let
        params : List String
        params =
            List.filterMap identity maybeParams
    in
    if List.isEmpty params then
        path

    else
        path ++ "?" ++ String.join "&" params
