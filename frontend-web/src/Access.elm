module Access exposing (RouteDecision(..), resolveRoute)

import Data.Route exposing (Route(..))
import Session


type RouteDecision
    = Render Route
    | Navigate Route


resolveRoute : Session.Session -> Bool -> Route -> RouteDecision
resolveRoute session adminExists route =
    if not adminExists then
        case route of
            Setup ->
                Render Setup

            _ ->
                Navigate Setup

    else if Session.isAdmin session then
        case route of
            AdminDashboard ->
                Render AdminDashboard

            AdminCreateUser ->
                Render AdminCreateUser

            _ ->
                Navigate AdminDashboard

    else if not (Session.isAuthenticated session) then
        case route of
            Login ->
                Render Login

            _ ->
                Navigate Login

    else
        case route of
            Root ->
                Navigate (Diary Nothing)

            NotFound ->
                Navigate Root

            Setup ->
                Navigate Root

            Login ->
                Navigate Root

            AdminDashboard ->
                Navigate (Diary Nothing)

            AdminCreateUser ->
                Navigate (Diary Nothing)

            Diary _ ->
                Render route

            FoodLogDetail _ ->
                Render route

            FoodSearch _ ->
                Render route

            FoodDetail _ _ ->
                Render route

            CustomFoodCreate ->
                Render route

            CustomFoodEdit _ ->
                Render route

            Meals ->
                Render route

            MealCreate ->
                Render route

            MealDetail _ ->
                Render route

            MealEdit _ ->
                Render route
