module Access exposing (RouteDecision(..), resolveRoute)

import Data.Auth as Auth exposing (Session)
import Data.Route exposing (Route(..))


type RouteDecision
    = Render Route
    | Navigate Route
    | Hold


resolveRoute : Session -> Bool -> Route -> RouteDecision
resolveRoute session adminExists route =
    case session of
        Auth.Loading ->
            Hold

        _ ->
            resolveKnownSession session adminExists route


resolveKnownSession : Session -> Bool -> Route -> RouteDecision
resolveKnownSession session adminExists route =
    if not adminExists then
        case route of
            BootstrapSetup ->
                Render BootstrapSetup

            _ ->
                Navigate BootstrapSetup

    else if Auth.isAdmin session then
        case route of
            AdminDashboard ->
                Render AdminDashboard

            AdminCreateUser ->
                Render AdminCreateUser

            AdminEditUser _ ->
                Render route

            _ ->
                Navigate AdminDashboard

    else if not (Auth.isAuthenticated session) then
        case route of
            AuthLogin ->
                Render AuthLogin

            _ ->
                Navigate AuthLogin

    else
        case route of
            Root ->
                Navigate (DiaryDay Nothing Nothing)

            NotFound ->
                Navigate Root

            BootstrapSetup ->
                Navigate Root

            AuthLogin ->
                Navigate Root

            AdminDashboard ->
                Navigate (DiaryDay Nothing Nothing)

            AdminCreateUser ->
                Navigate (DiaryDay Nothing Nothing)

            AdminEditUser _ ->
                Navigate (DiaryDay Nothing Nothing)

            DiaryDay _ _ ->
                Render route

            DiaryCalendar _ ->
                Render route

            GoalSettings ->
                Render route

            DiarySettings ->
                Render route

            FoodLogEntry _ _ _ ->
                Render route

            FoodSearch _ _ ->
                Render route

            FoodShow _ _ _ ->
                Render route

            CustomFoodList ->
                Render route

            CustomFoodCreate ->
                Render route

            CustomFoodEdit _ ->
                Render route

            CustomFoodShow _ ->
                Render route

            MealList ->
                Render route

            MealCreate ->
                Render route

            MealShow _ ->
                Render route

            MealEdit _ ->
                Render route
