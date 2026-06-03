module Access exposing (RouteDecision(..), resolveRoute)

import Route exposing (Route(..))
import Session


type RouteDecision
    = Render Route
    | Navigate Route


resolveRoute : Session.Session -> Route -> RouteDecision
resolveRoute session route =
    case route of
        Root ->
            if not session.adminExists then
                Navigate Setup

            else if not (Session.isAuthenticated session) then
                Navigate Login

            else if Session.isAdmin session then
                Navigate AdminDashboard

            else
                Navigate (Diary Nothing)

        NotFound ->
            Navigate Root

        Setup ->
            if session.adminExists && not (Session.isAuthenticated session) then
                Navigate Login

            else if Session.isAuthenticated session then
                Navigate Root

            else
                Render Setup

        Login ->
            if Session.isAuthenticated session then
                Navigate Root

            else
                Render Login

        AdminDashboard ->
            if not (Session.isAuthenticated session) then
                Navigate Login

            else if not (Session.isAdmin session) then
                Navigate (Diary Nothing)

            else
                Render AdminDashboard

        Diary _ ->
            foodRoute session route

        FoodLogDetail _ ->
            foodRoute session route

        FoodSearch _ ->
            foodRoute session route

        FoodDetail _ _ ->
            foodRoute session route

        CustomFoodCreate ->
            foodRoute session route

        CustomFoodEdit _ ->
            foodRoute session route

        Meals ->
            foodRoute session route

        MealCreate ->
            foodRoute session route

        MealDetail _ ->
            foodRoute session route

        MealEdit _ ->
            foodRoute session route


foodRoute : Session.Session -> Route -> RouteDecision
foodRoute session route =
    if not (Session.isAuthenticated session) then
        Navigate Login

    else if Session.isAdmin session then
        Navigate AdminDashboard

    else
        Render route
