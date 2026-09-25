module Page.Users.BootstrapSetupTest exposing (tests)

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.BootstrapSetup as BootstrapSetup
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Unauthorized"


networkError : Client.ApiError
networkError =
    Client.NetworkError


tests : Test
tests =
    describe "Page.Users.BootstrapSetup"
        [ test "valid credentials emit the create-admin request and the session out-msg" <|
            \_ ->
                let
                    filled : BootstrapSetup.Model
                    filled =
                        BootstrapSetup.init
                            |> step (formMsg (CredentialForm.UsernameChanged " admin "))
                            |> step (formMsg (CredentialForm.PasswordChanged "long-enough"))

                    submitting : BootstrapSetup.Model
                    submitting =
                        step (formMsg CredentialForm.Submitted) filled
                in
                { request = out (formMsg CredentialForm.Submitted) filled
                , screen = toScreen submitting
                , completed = out (BootstrapSetup.CreateAdminCompleted (Ok loginSession)) submitting
                }
                    |> Expect.equal
                        { request =
                            BootstrapSetup.RequestCreateAdmin
                                { username = "admin", password = "long-enough" }
                        , screen = { phase = "submitting", username = " admin ", error = Nothing }
                        , completed = BootstrapSetup.CreateAdminSucceeded loginSession
                        }
        , test "a short or missing password is rejected and editing clears it" <|
            \_ ->
                let
                    shortPassword : BootstrapSetup.Model
                    shortPassword =
                        BootstrapSetup.init
                            |> step (formMsg (CredentialForm.UsernameChanged "admin"))
                            |> step (formMsg (CredentialForm.PasswordChanged "short"))

                    submittedShort : BootstrapSetup.Model
                    submittedShort =
                        step (formMsg CredentialForm.Submitted) shortPassword

                    missingUsername : BootstrapSetup.Model
                    missingUsername =
                        BootstrapSetup.init
                            |> step (formMsg (CredentialForm.PasswordChanged "long-enough"))
                in
                { shortPassword = toScreen submittedShort
                , shortPasswordOut = out (formMsg CredentialForm.Submitted) shortPassword
                , missingUsername =
                    toScreen (step (formMsg CredentialForm.Submitted) missingUsername)
                , validation =
                    BootstrapSetup.validateBootstrapAdmin
                        { username = " admin ", password = "long-enough" }
                , cleared =
                    toScreen
                        (step
                            (formMsg (CredentialForm.PasswordChanged "long-enough"))
                            submittedShort
                        )
                }
                    |> Expect.equal
                        { shortPassword =
                            { phase = "invalid"
                            , username = "admin"
                            , error = Just (I18n.en TidSetupPasswordMinLength)
                            }
                        , shortPasswordOut = BootstrapSetup.NoOp
                        , missingUsername =
                            { phase = "invalid"
                            , username = ""
                            , error = Just (I18n.en TidCommonUsernameRequired)
                            }
                        , validation = Ok { username = "admin", password = "long-enough" }
                        , cleared = { phase = "editing", username = "admin", error = Nothing }
                        }
        , test "a failed or unauthorized completion surfaces a form error and no session out-msg" <|
            \_ ->
                let
                    submitting : BootstrapSetup.Model
                    submitting =
                        BootstrapSetup.init
                            |> step (formMsg (CredentialForm.UsernameChanged "admin"))
                            |> step (formMsg (CredentialForm.PasswordChanged "long-enough"))
                            |> step (formMsg CredentialForm.Submitted)
                in
                { networkFailure =
                    toScreen
                        (step (BootstrapSetup.CreateAdminCompleted (Err networkError)) submitting)
                , networkOut =
                    out (BootstrapSetup.CreateAdminCompleted (Err networkError)) submitting
                , unauthorized =
                    toScreen
                        (step (BootstrapSetup.CreateAdminCompleted (Err unauthorized)) submitting)
                , unauthorizedOut =
                    out (BootstrapSetup.CreateAdminCompleted (Err unauthorized)) submitting
                }
                    |> Expect.equal
                        { networkFailure =
                            { phase = "failed"
                            , username = "admin"
                            , error = Just networkErrorMessage
                            }
                        , networkOut = BootstrapSetup.NoOp
                        , unauthorized =
                            { phase = "failed"
                            , username = "admin"
                            , error = Just "Unauthorized"
                            }
                        , unauthorizedOut = BootstrapSetup.NoOp
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , username : String
    , error : Maybe String
    }


toScreen : BootstrapSetup.Model -> Screen
toScreen model =
    case model of
        CredentialForm.Editing form ->
            { phase = "editing", username = form.username, error = Nothing }

        CredentialForm.Invalid form message ->
            { phase = "invalid", username = form.username, error = Just message }

        CredentialForm.Submitting form ->
            { phase = "submitting", username = form.username, error = Nothing }

        CredentialForm.Failed form message ->
            { phase = "failed", username = form.username, error = Just message }



-- HELPERS


step : BootstrapSetup.Msg -> BootstrapSetup.Model -> BootstrapSetup.Model
step msg model =
    first (BootstrapSetup.update msg model)


out : BootstrapSetup.Msg -> BootstrapSetup.Model -> BootstrapSetup.OutMsg
out msg model =
    third (BootstrapSetup.update msg model)


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }


formMsg : CredentialForm.Msg -> BootstrapSetup.Msg
formMsg =
    BootstrapSetup.FormMsg


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
