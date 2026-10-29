module Page.Users.EditUserTest exposing (tests)

import Api.Client as Client
import Data.User exposing (User)
import Expect
import Page.Users.EditUser as EditUser
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.EditUser"
        [ test "a user resets a password" <|
            \_ ->
                loaded
                    |> step (EditUser.PasswordChanged "new-password")
                    |> step EditUser.ResetSubmitted
                    |> step (EditUser.ResetCompleted (Err Client.NetworkError))
                    |> step EditUser.ResetSubmitted
                    |> step (EditUser.ResetCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal EditUser.UpdateSucceeded
                        )
        , test "a user disables an account" <|
            \_ ->
                loaded
                    |> step EditUser.DisableClicked
                    |> step EditUser.DisableConfirmClicked
                    |> step (EditUser.DisableCompleted (Err Client.NetworkError))
                    |> step EditUser.DisableClicked
                    |> step EditUser.DisableConfirmClicked
                    |> step (EditUser.DisableCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal EditUser.UpdateSucceeded
                        )
        ]


stepWithOut :
    EditUser.Msg
    -> EditUser.Model
    -> ( EditUser.Model, EditUser.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            EditUser.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey EditUser.Model EditUser.OutMsg


step : EditUser.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( EditUser.Model, EditUser.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loaded : Journey
loaded =
    Story.start ( EditUser.init "u1" |> Tuple.first, EditUser.init "u1" |> Tuple.second )
        |> step (EditUser.UserLoaded (Ok alice))


alice : User
alice =
    { id = "u1"
    , username = "alice"
    , displayName = "Alice"
    , status = "active"
    , createdAt = "2026-01-01T00:00:00Z"
    }
