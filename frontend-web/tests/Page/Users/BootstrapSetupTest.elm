module Page.Users.BootstrapSetupTest exposing (tests)

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.BootstrapSetup as BootstrapSetup
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Users.BootstrapSetup"
        [ test "validation, a failed create, retry, then an admin session" <|
            \_ ->
                let
                    blank : BootstrapSetup.Model
                    blank =
                        step (formMsg CredentialForm.Submitted) BootstrapSetup.init

                    shortPassword : BootstrapSetup.Model
                    shortPassword =
                        BootstrapSetup.init
                            |> Story.runSteps step
                                [ formMsg (CredentialForm.UsernameChanged " admin ")
                                , formMsg (CredentialForm.PasswordChanged "short")
                                ]
                            |> step (formMsg CredentialForm.Submitted)

                    edited : BootstrapSetup.Model
                    edited =
                        step
                            (formMsg (CredentialForm.PasswordChanged "long-enough"))
                            shortPassword

                    submitted : BootstrapSetup.Model
                    submitted =
                        step (formMsg CredentialForm.Submitted) edited

                    failed : BootstrapSetup.Model
                    failed =
                        step
                            (BootstrapSetup.CreateAdminCompleted (Err Client.NetworkError))
                            submitted

                    retried : BootstrapSetup.Model
                    retried =
                        step (formMsg CredentialForm.Submitted) failed

                    succeeded : BootstrapSetup.Model
                    succeeded =
                        step
                            (BootstrapSetup.CreateAdminCompleted (Ok loginSession))
                            retried
                in
                { blankError = (toScreen blank).error
                , shortPasswordError = (toScreen shortPassword).error
                , request = out (formMsg CredentialForm.Submitted) edited
                , failedError = (toScreen failed).error
                , retryRequest = out (formMsg CredentialForm.Submitted) failed
                , finalOut =
                    out
                        (BootstrapSetup.CreateAdminCompleted (Ok loginSession))
                        retried
                , final = toScreen succeeded
                }
                    |> Expect.equal
                        { blankError = Just (I18n.en TidCommonUsernameRequired)
                        , shortPasswordError = Just (I18n.en TidSetupPasswordMinLength)
                        , request =
                            BootstrapSetup.RequestCreateAdmin
                                { username = "admin", password = "long-enough" }
                        , failedError = Just Fixtures.networkErrorMessage
                        , retryRequest =
                            BootstrapSetup.RequestCreateAdmin
                                { username = "admin", password = "long-enough" }
                        , finalOut = BootstrapSetup.CreateAdminSucceeded loginSession
                        , final = { username = " admin ", error = Nothing }
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { username : String
    , error : Maybe String
    }


toScreen : BootstrapSetup.Model -> Screen
toScreen model =
    let
        form : CredentialForm.Form
        form =
            case model of
                CredentialForm.Editing current ->
                    current

                CredentialForm.Invalid current _ ->
                    current

                CredentialForm.Submitting current ->
                    current

                CredentialForm.Failed current _ ->
                    current
    in
    { username = form.username
    , error =
        case model of
            CredentialForm.Invalid _ message ->
                Just message

            CredentialForm.Failed _ message ->
                Just message

            _ ->
                Nothing
    }



-- HELPERS


step : BootstrapSetup.Msg -> BootstrapSetup.Model -> BootstrapSetup.Model
step msg model =
    Fixtures.tupleFirst (BootstrapSetup.update msg model)


out : BootstrapSetup.Msg -> BootstrapSetup.Model -> BootstrapSetup.OutMsg
out msg model =
    Fixtures.tupleThird (BootstrapSetup.update msg model)


formMsg : CredentialForm.Msg -> BootstrapSetup.Msg
formMsg =
    BootstrapSetup.FormMsg


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }
