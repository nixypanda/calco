module Data.Route exposing
    ( Route(..)
    , fromUrl
    , primaryRoute
    , routeToPath
    )

import Data.MealSlot as MealSlot exposing (MealSlot)
import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), (<?>), Parser, oneOf, s, string, top)
import Url.Parser.Query as Query


type Route
    = Root
    | BootstrapSetup
    | AuthLogin
    | AdminDashboard
    | AdminCreateUser
    | AdminEditUser String
    | DiaryDay (Maybe String) (Maybe String)
    | DiaryCalendar (Maybe String)
    | NutritionDetails (Maybe String)
    | GoalSettings
    | DiarySettings
    | FoodLogEntry String (Maybe String) (Maybe String)
    | AdHocLogCreate (Maybe String) (Maybe MealSlot)
    | AiLogCreate (Maybe String) (Maybe MealSlot)
    | FoodSearch (Maybe String) (Maybe MealSlot)
    | FoodShow String (Maybe String) (Maybe MealSlot) (Maybe String)
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
    Parser.parse routeParser url
        |> Maybe.withDefault NotFound


routeParser : Parser (Route -> a) a
routeParser =
    oneOf
        [ Parser.map Root top
        , Parser.map BootstrapSetup (s "setup")
        , Parser.map AuthLogin (s "login")
        , Parser.map AdminDashboard (s "admin")
        , Parser.map AdminCreateUser (s "admin" </> s "users" </> s "new")
        , Parser.map AdminEditUser (s "admin" </> s "users" </> string </> s "edit")
        , Parser.map DiaryDay
            (s "home" <?> Query.string "date" <?> Query.string "calendar_month")
        , Parser.map DiaryCalendar (s "calendar" <?> Query.string "month")
        , Parser.map NutritionDetails (s "details" <?> Query.string "date")
        , Parser.map GoalSettings (s "settings" </> s "goals")
        , Parser.map DiarySettings (s "settings" </> s "diary")
        , Parser.map AdHocLogCreate
            (s "logs"
                </> s "new"
                </> s "ad-hoc"
                <?> Query.string "date"
                <?> mealSlotQuery
            )
        , Parser.map AiLogCreate
            (s "logs"
                </> s "new"
                </> s "ai"
                <?> Query.string "date"
                <?> mealSlotQuery
            )
        , Parser.map FoodLogEntry
            (s "logs"
                </> string
                <?> Query.string "date"
                <?> Query.string "calendar_month"
            )
        , Parser.map FoodSearch (s "search" <?> Query.string "date" <?> mealSlotQuery)
        , Parser.map CustomFoodList (s "foods" </> s "custom")
        , Parser.map CustomFoodCreateWithAi
            (s "foods" </> s "custom" </> s "new" </> s "ai")
        , Parser.map CustomFoodCreate (s "foods" </> s "custom" </> s "new")
        , Parser.map CustomFoodEdit (s "foods" </> s "custom" </> string </> s "edit")
        , Parser.map CustomFoodShow (s "foods" </> s "custom" </> string)
        , Parser.map FoodShow
            (s "foods"
                </> string
                <?> Query.string "date"
                <?> mealSlotQuery
                <?> Query.string "lookup_note"
            )
        , Parser.map MealList (s "meals")
        , Parser.map MealCreate (s "meals" </> s "new")
        , Parser.map MealEdit (s "meals" </> string </> s "edit")
        , Parser.map MealShow (s "meals" </> string)
        ]


mealSlotQuery : Query.Parser (Maybe MealSlot)
mealSlotQuery =
    Query.string "meal_slot"
        |> Query.map (Maybe.andThen MealSlot.fromString)


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
            "/admin/users/" ++ id ++ "/edit"

        DiaryDay maybeDate maybeCalendarMonth ->
            withQueryParams "/home"
                [ Maybe.map (\date -> "date=" ++ Url.percentEncode date) maybeDate
                , Maybe.map
                    (\month -> "calendar_month=" ++ Url.percentEncode month)
                    maybeCalendarMonth
                ]

        DiaryCalendar maybeMonth ->
            withQueryParams "/calendar"
                [ Maybe.map (\month -> "month=" ++ Url.percentEncode month) maybeMonth ]

        NutritionDetails maybeDate ->
            withQueryParams "/details"
                [ Maybe.map (\date -> "date=" ++ Url.percentEncode date) maybeDate ]

        GoalSettings ->
            "/settings/goals"

        DiarySettings ->
            "/settings/diary"

        FoodLogEntry id maybeDate maybeCalendarMonth ->
            withQueryParams ("/logs/" ++ id)
                [ Maybe.map (\date -> "date=" ++ Url.percentEncode date) maybeDate
                , Maybe.map
                    (\month -> "calendar_month=" ++ Url.percentEncode month)
                    maybeCalendarMonth
                ]

        AdHocLogCreate maybeDate maybeSlot ->
            withFoodContext "/logs/new/ad-hoc" maybeDate maybeSlot

        AiLogCreate maybeDate maybeSlot ->
            withFoodContext "/logs/new/ai" maybeDate maybeSlot

        FoodSearch maybeDate maybeSlot ->
            withFoodContext "/search" maybeDate maybeSlot

        FoodShow id maybeDate maybeSlot lookupNote ->
            withQueryParams ("/foods/" ++ id)
                [ Maybe.map (\date -> "date=" ++ Url.percentEncode date) maybeDate
                , Maybe.map
                    (\slot -> "meal_slot=" ++ MealSlot.toString slot)
                    maybeSlot
                , Maybe.map
                    (\note -> "lookup_note=" ++ Url.percentEncode note)
                    lookupNote
                ]

        CustomFoodList ->
            "/foods/custom"

        CustomFoodCreate ->
            "/foods/custom/new"

        CustomFoodCreateWithAi ->
            "/foods/custom/new/ai"

        CustomFoodEdit id ->
            "/foods/custom/" ++ id ++ "/edit"

        CustomFoodShow id ->
            "/foods/custom/" ++ id

        MealList ->
            "/meals"

        MealCreate ->
            "/meals/new"

        MealShow id ->
            "/meals/" ++ id

        MealEdit id ->
            "/meals/" ++ id ++ "/edit"

        NotFound ->
            "/"


withFoodContext : String -> Maybe String -> Maybe MealSlot -> String
withFoodContext path maybeDate maybeSlot =
    let
        params : List String
        params =
            List.filterMap identity
                [ Maybe.map (\date -> "date=" ++ date) maybeDate
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
