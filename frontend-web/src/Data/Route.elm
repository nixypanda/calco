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
    | Setup
    | Login
    | AdminDashboard
    | AdminCreateUser
    | Diary (Maybe String)
    | FoodLogDetail String
    | FoodSearch (Maybe MealSlot)
    | FoodDetail String (Maybe MealSlot)
    | CustomFoodCreate
    | CustomFoodEdit String
    | Meals
    | MealCreate
    | MealDetail String
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
        , Parser.map Setup (s "setup")
        , Parser.map Login (s "login")
        , Parser.map AdminDashboard (s "admin")
        , Parser.map AdminCreateUser (s "admin" </> s "users" </> s "new")
        , Parser.map Diary (s "home" <?> Query.string "date")
        , Parser.map FoodLogDetail (s "logs" </> string)
        , Parser.map FoodSearch (s "search" <?> mealSlotQuery)
        , Parser.map CustomFoodCreate (s "foods" </> s "custom" </> s "new")
        , Parser.map CustomFoodEdit (s "foods" </> s "custom" </> string </> s "edit")
        , Parser.map FoodDetail (s "foods" </> string <?> mealSlotQuery)
        , Parser.map Meals (s "meals")
        , Parser.map MealCreate (s "meals" </> s "new")
        , Parser.map MealEdit (s "meals" </> string </> s "edit")
        , Parser.map MealDetail (s "meals" </> string)
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

        Setup ->
            "/setup"

        Login ->
            "/login"

        AdminDashboard ->
            "/admin"

        AdminCreateUser ->
            "/admin/users/new"

        Diary maybeDate ->
            case maybeDate of
                Just date ->
                    "/home?date=" ++ date

                Nothing ->
                    "/home"

        FoodLogDetail id ->
            "/logs/" ++ id

        FoodSearch maybeSlot ->
            withMealSlot "/search" maybeSlot

        FoodDetail id maybeSlot ->
            withMealSlot ("/foods/" ++ id) maybeSlot

        CustomFoodCreate ->
            "/foods/custom/new"

        CustomFoodEdit id ->
            "/foods/custom/" ++ id ++ "/edit"

        Meals ->
            "/meals"

        MealCreate ->
            "/meals/new"

        MealDetail id ->
            "/meals/" ++ id

        MealEdit id ->
            "/meals/" ++ id ++ "/edit"

        NotFound ->
            "/"


withMealSlot : String -> Maybe MealSlot -> String
withMealSlot path maybeSlot =
    case maybeSlot of
        Just slot ->
            path ++ "?meal_slot=" ++ MealSlot.toString slot

        Nothing ->
            path
