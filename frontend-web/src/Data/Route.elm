module Data.Route exposing
    ( Route(..)
    , fromUrl
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
    | DiaryDay (Maybe String)
    | GoalSettings
    | FoodLogEntry String
    | FoodSearch (Maybe String) (Maybe MealSlot)
    | FoodShow String (Maybe String) (Maybe MealSlot)
    | CustomFoodList
    | CustomFoodCreate
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
        , Parser.map DiaryDay (s "home" <?> Query.string "date")
        , Parser.map GoalSettings (s "settings" </> s "goals")
        , Parser.map FoodLogEntry (s "logs" </> string)
        , Parser.map FoodSearch (s "search" <?> Query.string "date" <?> mealSlotQuery)
        , Parser.map CustomFoodList (s "foods" </> s "custom")
        , Parser.map CustomFoodCreate (s "foods" </> s "custom" </> s "new")
        , Parser.map CustomFoodEdit (s "foods" </> s "custom" </> string </> s "edit")
        , Parser.map CustomFoodShow (s "foods" </> s "custom" </> string)
        , Parser.map FoodShow (s "foods" </> string <?> Query.string "date" <?> mealSlotQuery)
        , Parser.map MealList (s "meals")
        , Parser.map MealCreate (s "meals" </> s "new")
        , Parser.map MealEdit (s "meals" </> string </> s "edit")
        , Parser.map MealShow (s "meals" </> string)
        ]


mealSlotQuery : Query.Parser (Maybe MealSlot)
mealSlotQuery =
    Query.string "meal_slot"
        |> Query.map (Maybe.andThen MealSlot.fromString)


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

        DiaryDay maybeDate ->
            case maybeDate of
                Just date ->
                    "/home?date=" ++ date

                Nothing ->
                    "/home"

        GoalSettings ->
            "/settings/goals"

        FoodLogEntry id ->
            "/logs/" ++ id

        FoodSearch maybeDate maybeSlot ->
            withFoodContext "/search" maybeDate maybeSlot

        FoodShow id maybeDate maybeSlot ->
            withFoodContext ("/foods/" ++ id) maybeDate maybeSlot

        CustomFoodList ->
            "/foods/custom"

        CustomFoodCreate ->
            "/foods/custom/new"

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
