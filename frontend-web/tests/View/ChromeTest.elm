module View.ChromeTest exposing (tests)

{-| Pure laws for the shell's chrome and bottom-nav visibility.

The bottom nav is Phone-only and its reservation must use the same predicate
as rendering, so the two cannot drift. Chrome suppression is a shell state
(boot/logout), not a page-loading state.

-}

import Data.Auth as Auth exposing (Session(..))
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Test exposing (Test, describe, test)
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env)
import Ui.Theme as Theme
import View.Chrome as Chrome


tests : Test
tests =
    describe "View.Chrome"
        [ describe "shouldReserveBottomNav"
            [ test "reserves on a Phone app route for an authenticated non-admin" <|
                \_ ->
                    Chrome.shouldReserveBottomNav phoneEnv user appRoute
                        |> Expect.equal True
            , test "does not reserve for an admin" <|
                \_ ->
                    Chrome.shouldReserveBottomNav phoneEnv admin appRoute
                        |> Expect.equal False
            , test "does not reserve on login or setup" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            Chrome.shouldReserveBottomNav phoneEnv user AuthLogin
                                |> Expect.equal False
                        , \_ ->
                            Chrome.shouldReserveBottomNav phoneEnv user BootstrapSetup
                                |> Expect.equal False
                        ]
                        ()
            , test "reserves on a Phone contextual detail route" <|
                \_ ->
                    Chrome.shouldReserveBottomNav phoneEnv user (MealShow "meal-1")
                        |> Expect.equal True
            , test "does not reserve on a Tablet" <|
                \_ ->
                    Chrome.shouldReserveBottomNav tabletEnv user appRoute
                        |> Expect.equal False
            , test "does not reserve when unauthenticated" <|
                \_ ->
                    Chrome.shouldReserveBottomNav phoneEnv anonymous appRoute
                        |> Expect.equal False
            ]
        , describe "showBottomNav"
            [ test "follows the reservation predicate when chrome is not suppressed" <|
                \_ ->
                    Chrome.showBottomNav phoneEnv user False appRoute
                        |> Expect.equal
                            (Chrome.shouldReserveBottomNav phoneEnv user appRoute)
            , test "hides the nav while chrome is suppressed even where it is reserved" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            Chrome.shouldReserveBottomNav phoneEnv user appRoute
                                |> Expect.equal True
                        , \_ ->
                            Chrome.showBottomNav phoneEnv user True appRoute
                                |> Expect.equal False
                        ]
                        ()
            ]
        , describe "showsAppChrome"
            [ test "shows for an authenticated app route when not suppressed" <|
                \_ ->
                    Chrome.showsAppChrome user False appRoute
                        |> Expect.equal True
            , test "is hidden by the suppression flag, independent of page loading" <|
                \_ ->
                    Chrome.showsAppChrome user True appRoute
                        |> Expect.equal False
            ]
        ]


phoneEnv : Env
phoneEnv =
    env Phone


tabletEnv : Env
tabletEnv =
    env Tablet


env : DeviceClass -> Env
env class =
    { theme = Theme.forMode Theme.Light
    , device = { class = class, orientation = Portrait }
    , language = EN_US
    }


user : Session
user =
    Authenticated { id = "1", username = "user", role = Auth.User }


admin : Session
admin =
    Authenticated { id = "2", username = "admin", role = Auth.Admin }


anonymous : Session
anonymous =
    Unauthenticated


appRoute : Route
appRoute =
    DiaryDay Nothing Nothing
