module AccessTest exposing (tests)

{-| Exhaustive decision properties for `Access.resolveRoute`.

The route list below contains exactly one representative for every `Route`
constructor, plus optional-field variants (`Nothing` dates, slots, months, and
lookup notes), so the folds also classify the generic user routes rather than
only fully-populated examples.

This is the allowed exhaustive-decision exception: `resolveRoute` is consumed by
every route and page, so a page story cannot cover the whole decision surface
without duplicating this table.

-}

import Access exposing (RouteDecision(..))
import Data.Auth as Auth exposing (Session(..))
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect exposing (Expectation)
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Access.resolveRoute"
        [ loadingHoldsEveryRoute
        , noAdminBootstrapsEveryRoute
        , adminSeesOnlyAdminRoutes
        , unauthenticatedSeesOnlyLogin
        , authenticatedNonAdminSeesOnlyUserRoutes
        ]


{-| `Loading` is not a session decision: every route waits, regardless of
whether an admin exists.
-}
loadingHoldsEveryRoute : Test
loadingHoldsEveryRoute =
    test "Loading holds every route for either adminExists value" <|
        \_ ->
            testRoutes
                |> List.concatMap
                    (\route ->
                        [ Access.resolveRoute Loading False route
                            |> Expect.equal Hold
                        , Access.resolveRoute Loading True route
                            |> Expect.equal Hold
                        ]
                    )
                |> expectAll


{-| Before an admin exists, every known session is funnelled into setup. The
setup route itself is the only one that renders.
-}
noAdminBootstrapsEveryRoute : Test
noAdminBootstrapsEveryRoute =
    test "without an admin every known session renders or navigates to setup" <|
        \_ ->
            testRoutes
                |> List.concatMap
                    (\route ->
                        knownSessions
                            |> List.map
                                (\session ->
                                    Access.resolveRoute session False route
                                        |> Expect.equal (expectedWithoutAdmin route)
                                )
                    )
                |> expectAll


adminSeesOnlyAdminRoutes : Test
adminSeesOnlyAdminRoutes =
    test "an admin renders only admin routes and otherwise lands on the dashboard" <|
        \_ ->
            testRoutes
                |> List.map
                    (\route ->
                        Access.resolveRoute admin True route
                            |> Expect.equal
                                (if List.member route adminRoutes then
                                    Render route

                                 else
                                    Navigate AdminDashboard
                                )
                    )
                |> expectAll


unauthenticatedSeesOnlyLogin : Test
unauthenticatedSeesOnlyLogin =
    test "an unauthenticated session renders only login and otherwise navigates there" <|
        \_ ->
            testRoutes
                |> List.map
                    (\route ->
                        Access.resolveRoute Unauthenticated True route
                            |> Expect.equal
                                (if route == AuthLogin then
                                    Render AuthLogin

                                 else
                                    Navigate AuthLogin
                                )
                    )
                |> expectAll


{-| Both a normal user and an authenticated identity with an unknown role must
follow the normal-user branch; a role that is neither admin nor user is never
treated as an admin.
-}
authenticatedNonAdminSeesOnlyUserRoutes : Test
authenticatedNonAdminSeesOnlyUserRoutes =
    test "an authenticated non-admin renders user routes and redirects the rest" <|
        \_ ->
            [ ( "user", normalUser ), ( "other role", otherRoleUser ) ]
                |> List.concatMap
                    (\( label, session ) ->
                        testRoutes
                            |> List.map
                                (\route ->
                                    Access.resolveRoute session True route
                                        |> Expect.equal (normalUserDecision route)
                                        |> Expect.onFail label
                                )
                    )
                |> expectAll


normalUserDecision : Route -> RouteDecision
normalUserDecision route =
    if List.member route userRoutes then
        Render route

    else
        Navigate (normalUserRedirect route)


expectedWithoutAdmin : Route -> RouteDecision
expectedWithoutAdmin route =
    if route == BootstrapSetup then
        Render BootstrapSetup

    else
        Navigate BootstrapSetup


normalUserRedirect : Route -> Route
normalUserRedirect route =
    if route == Root then
        DiaryDay Nothing Nothing

    else if route == NotFound then
        Root

    else if List.member route setupRoutes then
        Root

    else if List.member route adminRoutes then
        DiaryDay Nothing Nothing

    else
        route


{-| One representative per `Route` constructor, with fixed IDs and dates.
-}
allRoutes : List Route
allRoutes =
    [ Root
    , BootstrapSetup
    , AuthLogin
    , AdminDashboard
    , AdminCreateUser
    , AdminEditUser "user-1"
    , DiaryDay (Just Fixtures.today) (Just "2026-08")
    , DiaryCalendar (Just "2026-08")
    , NutritionDetails (Just Fixtures.today)
    , GoalSettings
    , DiarySettings
    , SettingsApiKeys
    , SettingsApiKeyCreate
    , FoodLogEntry "log-1" (Just Fixtures.today) (Just "2026-08")
    , AdHocLogCreate (Just Fixtures.today) (Just Lunch)
    , AiLogCreate (Just Fixtures.today) (Just Dinner)
    , FoodSearch (Just Fixtures.today) (Just Lunch)
    , FoodShow "food-1" (Just Fixtures.today) (Just Lunch) (Just "lookup")
    , CustomFoodList
    , CustomFoodCreate
    , CustomFoodCreateWithAi
    , CustomFoodEdit "food-1"
    , CustomFoodShow "food-1"
    , MealList
    , MealCreate
    , MealShow "meal-1"
    , MealEdit "meal-1"
    , NotFound
    ]


{-| Optional-field variants for the routes whose context can be generic. These
are the routes chrome users actually land on when a date or slot is not in the
URL.
-}
routeVariants : List Route
routeVariants =
    [ DiaryDay Nothing Nothing
    , DiaryCalendar Nothing
    , NutritionDetails Nothing
    , AdHocLogCreate Nothing Nothing
    , FoodSearch Nothing Nothing
    ]


testRoutes : List Route
testRoutes =
    allRoutes ++ routeVariants


setupRoutes : List Route
setupRoutes =
    [ BootstrapSetup, AuthLogin ]


adminRoutes : List Route
adminRoutes =
    [ AdminDashboard, AdminCreateUser, AdminEditUser "user-1" ]


redirectRoutes : List Route
redirectRoutes =
    [ Root, NotFound ]


userRoutes : List Route
userRoutes =
    testRoutes
        |> List.filter
            (\route ->
                not (List.member route (setupRoutes ++ adminRoutes ++ redirectRoutes))
            )


admin : Session
admin =
    Authenticated { id = "1", username = "admin", role = Auth.Admin }


normalUser : Session
normalUser =
    Authenticated { id = "2", username = "user", role = Auth.User }


otherRoleUser : Session
otherRoleUser =
    Authenticated { id = "3", username = "other", role = Auth.OtherRole }


knownSessions : List Session
knownSessions =
    [ Unauthenticated, admin, normalUser, otherRoleUser ]


expectAll : List Expectation -> Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()
