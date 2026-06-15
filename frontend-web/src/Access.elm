module Access exposing (RouteDecision(..), resolveRoute)

import Data.Route exposing (Route(..))
import Session


type RouteDecision
    = Render Route
    | Navigate Route
    | Hold


resolveRoute : Session.Session -> Bool -> Route -> RouteDecision
resolveRoute session adminExists route =
    case session of
        Session.Loading ->
            Hold

        _ ->
            resolveKnownSession session adminExists route


resolveKnownSession : Session.Session -> Bool -> Route -> RouteDecision
resolveKnownSession session adminExists route =
    if not adminExists then
        case route of
            BootstrapSetup ->
                Render BootstrapSetup

            _ ->
                Navigate BootstrapSetup

    else if Session.isAdmin session then
        case route of
            AdminDashboard ->
                Render AdminDashboard

            AdminCreateUser ->
                Render AdminCreateUser

            AdminEditUser _ ->
                Render route

            _ ->
                Navigate AdminDashboard

    else if not (Session.isAuthenticated session) then
        case route of
            AuthLogin ->
                Render AuthLogin

            _ ->
                Navigate AuthLogin

    else
        case route of
            Root ->
                Navigate (DiaryDay Nothing)

            NotFound ->
                Navigate Root

            BootstrapSetup ->
                Navigate Root

            AuthLogin ->
                Navigate Root

            AdminDashboard ->
                Navigate (DiaryDay Nothing)

            AdminCreateUser ->
                Navigate (DiaryDay Nothing)

            AdminEditUser _ ->
                Navigate (DiaryDay Nothing)

            DiaryDay _ ->
                Render route

            FoodLogEntry _ ->
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
