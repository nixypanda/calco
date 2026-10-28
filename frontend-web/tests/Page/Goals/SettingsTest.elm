module Page.Goals.SettingsTest exposing (tests)

{-| Goal-settings stories.

The first story loads, refreshes fields, keeps edits across a refresh, and saves
all four targets. The second covers every validation branch. The third keeps
edits through a failed save, retries, and expires the session on a later 401.

-}

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..), GoalStatus)
import Data.LocalCtx exposing (LocalCtx)
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as S
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "a failed load retries, refreshes fields, keeps edits, and saves four targets" <|
            \_ ->
                let
                    failed : S.Model
                    failed =
                        S.init
                            |> Tuple.first
                            |> step (S.GoalLoaded (Err Client.NetworkError))

                    ( retrying, retryOut ) =
                        stepOnce S.RetryClicked failed

                    loaded : S.Model
                    loaded =
                        step (S.GoalLoaded (Ok defaultSnapshot)) retrying

                    pristine : S.Model
                    pristine =
                        step (S.GoalLoaded (Ok pristineSnapshot)) loaded

                    edited : S.Model
                    edited =
                        edits
                            [ S.CalorieTargetChanged "2150"
                            , S.ProteinTargetChanged "170"
                            , S.CarbsTargetChanged "210"
                            , S.FatTargetChanged "70"
                            ]
                            pristine

                    refreshed : S.Model
                    refreshed =
                        step (S.GoalLoaded (Ok editedRefreshSnapshot)) edited

                    ( awaiting, saveClickOut ) =
                        stepOnce S.SaveClicked refreshed

                    ( submitting, ctxOut ) =
                        stepOnce (S.LocalCtxReceived context) awaiting

                    ( saved, finalOut ) =
                        stepOnce (S.SaveCompleted (Ok savedSnapshot)) submitting
                in
                { retryOut = retryOut
                , loaded = ( fieldsOf loaded, statusOf loaded )
                , pristine = ( fieldsOf pristine, statusOf pristine )
                , editedFields = fieldsOf edited
                , refreshed = ( fieldsOf refreshed, statusOf refreshed )
                , saveClickOut = saveClickOut
                , awaiting = toScreen awaiting
                , saveRequest = request ctxOut
                , finalOut = finalOut
                , final = toScreen saved
                }
                    |> Expect.equal
                        { retryOut = S.RequestGoal
                        , loaded = ( [ "2290", "160", "255", "70" ], Just defaultStatus )
                        , pristine = ( [ "2250", "150", "255", "70" ], Just savedToday )
                        , editedFields = [ "2150", "170", "210", "70" ]
                        , refreshed =
                            ( [ "2150", "170", "210", "70" ], Just savedYesterday )
                        , saveClickOut = S.RequestLocalCtx
                        , awaiting =
                            { readyScreen
                                | fields = [ "2150", "170", "210", "70" ]
                                , statusLabel = Just savedYesterday
                                , submit = Just ( savingLabel, True )
                            }
                        , saveRequest = Just (saveTargets [ 2150, 170, 210, 70 ])
                        , finalOut = S.NoOp
                        , final =
                            { readyScreen
                                | fields = [ "2150", "170", "210", "70" ]
                                , statusLabel = Just savedToday
                            }
                        }
        , test "each invalid target shape blocks save with its own message" <|
            \_ ->
                let
                    loaded : S.Model
                    loaded =
                        loadedFrom defaultSnapshot

                    ( afterInvalidNumbers, invalidNumbersOut ) =
                        validationAttempt [ S.ProteinTargetChanged "abc" ] loaded

                    ( afterImbalance, imbalanceOut ) =
                        validationAttempt
                            [ S.ProteinTargetChanged "160"
                            , S.CalorieTargetChanged "2200"
                            ]
                            afterInvalidNumbers

                    ( afterMacros, macrosOut ) =
                        validationAttempt
                            [ S.ProteinTargetChanged "-1" ]
                            afterImbalance

                    ( afterCalories, caloriesOut ) =
                        validationAttempt
                            [ S.ProteinTargetChanged "160"
                            , S.CalorieTargetChanged "-1"
                            ]
                            afterMacros

                    fixed : S.Model
                    fixed =
                        edits
                            [ S.CalorieTargetChanged "2150"
                            , S.ProteinTargetChanged "170"
                            , S.CarbsTargetChanged "210"
                            , S.FatTargetChanged "70"
                            ]
                            afterCalories

                    ( awaiting, saveOut ) =
                        stepOnce S.SaveClicked fixed

                    ( _, ctxOut ) =
                        stepOnce (S.LocalCtxReceived context) awaiting
                in
                { invalidNumbers = ( (toScreen afterInvalidNumbers).error, invalidNumbersOut )
                , imbalance = ( (toScreen afterImbalance).error, imbalanceOut )
                , macros = ( (toScreen afterMacros).error, macrosOut )
                , calories = ( (toScreen afterCalories).error, caloriesOut )
                , fixedFields = fieldsOf fixed
                , saveOut = saveOut
                , finalOut = request ctxOut
                }
                    |> Expect.equal
                        { invalidNumbers = ( Just invalidNumbersMessage, S.NoOp )
                        , imbalance = ( Just imbalanceMessage, S.NoOp )
                        , macros = ( Just macrosMessage, S.NoOp )
                        , calories = ( Just caloriesMessage, S.NoOp )
                        , fixedFields = [ "2150", "170", "210", "70" ]
                        , saveOut = S.RequestLocalCtx
                        , finalOut = Just (saveTargets [ 2150, 170, 210, 70 ])
                        }
        , test "a failed save keeps the edits, retries, and a later 401 expires the session" <|
            \_ ->
                let
                    edited : S.Model
                    edited =
                        loadedFrom defaultSnapshot
                            |> edits
                                [ S.CalorieTargetChanged "2150"
                                , S.ProteinTargetChanged "170"
                                , S.CarbsTargetChanged "210"
                                , S.FatTargetChanged "70"
                                ]

                    ( failed, failedOut ) =
                        saveAndComplete (Err Client.NetworkError) edited

                    ( retrying, retryOut ) =
                        stepOnce S.SaveClicked failed

                    ( retryingWithCtx, retryRequestOut ) =
                        stepOnce (S.LocalCtxReceived context) retrying

                    finalOut : S.OutMsg
                    finalOut =
                        stepOnce
                            (S.SaveCompleted (Err Fixtures.unauthorized))
                            retryingWithCtx
                            |> Tuple.second
                in
                { failed = toScreen failed
                , failedOut = failedOut
                , retryOut = retryOut
                , retryRequest = request retryRequestOut
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { failed =
                            { readyScreen
                                | fields = [ "2150", "170", "210", "70" ]
                                , statusLabel = Just defaultStatus
                                , error = Just Fixtures.networkErrorMessage
                            }
                        , failedOut = S.NoOp
                        , retryOut = S.RequestLocalCtx
                        , retryRequest = Just (saveTargets [ 2150, 170, 210, 70 ])
                        , finalOut = S.SessionExpired
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { fields : List String
    , statusLabel : Maybe String
    , error : Maybe String
    , submit : Maybe ( String, Bool )
    }


toScreen : S.Model -> Screen
toScreen model =
    case model of
        S.Loading ->
            loadingScreen

        S.Failed message ->
            { loadingScreen | error = Just message }

        S.Ready ready ->
            { fields =
                [ ready.form.calorieTarget
                , ready.form.proteinTargetG
                , ready.form.carbsTargetG
                , ready.form.fatTargetG
                ]
            , statusLabel = Just (statusText ready.status)
            , error =
                case ready.save of
                    S.ValidationFailed message ->
                        Just message

                    S.SaveFailed message ->
                        Just message

                    _ ->
                        Nothing
            , submit =
                if isSaving ready.save then
                    Just ( savingLabel, True )

                else
                    Just ( saveLabel, False )
            }


fieldsOf : S.Model -> List String
fieldsOf model =
    (toScreen model).fields


statusOf : S.Model -> Maybe String
statusOf model =
    (toScreen model).statusLabel


statusText : GoalStatus -> String
statusText status =
    case ( status.source, status.effectiveFrom ) of
        ( Default, Nothing ) ->
            defaultStatus

        ( Default, Just effectiveFrom ) ->
            I18n.en
                (TidGoalSettingsStatusDefaultAfter
                    (LocalDate.display I18n.defaultLanguage effectiveFrom)
                )

        ( Saved, Nothing ) ->
            I18n.en TidGoalSettingsStatusSavedActive

        ( Saved, Just effectiveFrom ) ->
            I18n.en
                (TidGoalSettingsStatusSavedFrom
                    (LocalDate.display I18n.defaultLanguage effectiveFrom)
                )


isSaving : S.SaveState -> Bool
isSaving save =
    case save of
        S.AwaitingLocalCtx _ ->
            True

        S.Saving ->
            True

        _ ->
            False


loadingScreen : Screen
loadingScreen =
    { fields = [], statusLabel = Nothing, error = Nothing, submit = Nothing }


readyScreen : Screen
readyScreen =
    { fields = []
    , statusLabel = Nothing
    , error = Nothing
    , submit = Just ( saveLabel, False )
    }



-- HELPERS


loadedFrom : GoalSnapshot -> S.Model
loadedFrom goalSnapshot =
    S.init
        |> Tuple.first
        |> step (S.GoalLoaded (Ok goalSnapshot))


edits : List S.Msg -> S.Model -> S.Model
edits messages model =
    runSteps step messages model


validationAttempt :
    List S.Msg
    -> S.Model
    -> ( S.Model, S.OutMsg )
validationAttempt changes model =
    stepOnce S.SaveClicked (edits changes model)


saveAndComplete :
    Result Client.ApiError GoalSnapshot
    -> S.Model
    -> ( S.Model, S.OutMsg )
saveAndComplete result model =
    let
        ( awaiting, _ ) =
            stepOnce S.SaveClicked model

        ( submitting, _ ) =
            stepOnce (S.LocalCtxReceived context) awaiting
    in
    stepOnce (S.SaveCompleted result) submitting


step : S.Msg -> S.Model -> S.Model
step msg model =
    Tuple.first (stepOnce msg model)


stepOnce :
    S.Msg
    -> S.Model
    -> ( S.Model, S.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            S.update msg model
    in
    ( next, outMsg )


type alias SaveRequest =
    { date : String
    , timezone : String
    , targets : List Float
    }


request : S.OutMsg -> Maybe SaveRequest
request outMsg =
    case outMsg of
        S.RequestSaveGoal saveRequest ->
            Just
                { date = LocalDate.format saveRequest.localDate
                , timezone = saveRequest.deviceTimezone
                , targets =
                    [ saveRequest.targets.calorieTarget
                    , saveRequest.targets.proteinTargetG
                    , saveRequest.targets.carbsTargetG
                    , saveRequest.targets.fatTargetG
                    ]
                }

        _ ->
            Nothing


saveTargets : List Float -> SaveRequest
saveTargets targets =
    { date = "2026-06-16", timezone = "Asia/Kolkata", targets = targets }


context : LocalCtx
context =
    { date = today, timezone = "Asia/Kolkata" }


snapshot : GoalSource -> Maybe LocalDate -> Float -> Float -> Float -> Float -> GoalSnapshot
snapshot source effective calories protein carbs fat =
    { requestedDate = today
    , effectiveFrom = effective
    , source = source
    , targets =
        { calorieTarget = calories
        , proteinTargetG = protein
        , carbsTargetG = carbs
        , fatTargetG = fat
        }
    }


defaultSnapshot : GoalSnapshot
defaultSnapshot =
    snapshot Default Nothing 2290 160 255 70


pristineSnapshot : GoalSnapshot
pristineSnapshot =
    snapshot Saved (Just today) 2250 150 255 70


editedRefreshSnapshot : GoalSnapshot
editedRefreshSnapshot =
    snapshot Saved (Just yesterday) 1905 120 210 65


savedSnapshot : GoalSnapshot
savedSnapshot =
    snapshot Saved (Just today) 2150 170 210 70


today : LocalDate
today =
    Fixtures.date "2026-06-16"


yesterday : LocalDate
yesterday =
    Fixtures.date "2026-06-15"


defaultStatus : String
defaultStatus =
    I18n.en TidGoalSettingsStatusDefaultForDate


savedToday : String
savedToday =
    I18n.en
        (TidGoalSettingsStatusSavedFrom (LocalDate.display I18n.defaultLanguage today))


savedYesterday : String
savedYesterday =
    I18n.en
        (TidGoalSettingsStatusSavedFrom (LocalDate.display I18n.defaultLanguage yesterday))


saveLabel : String
saveLabel =
    I18n.en TidGoalSettingsSave


savingLabel : String
savingLabel =
    I18n.en TidCommonSaving


invalidNumbersMessage : String
invalidNumbersMessage =
    I18n.en TidGoalSettingsErrorInvalidNumbers


imbalanceMessage : String
imbalanceMessage =
    I18n.en TidGoalSettingsErrorCaloriesMacros


macrosMessage : String
macrosMessage =
    I18n.en TidGoalSettingsErrorMacrosNonNegative


caloriesMessage : String
caloriesMessage =
    I18n.en TidGoalSettingsErrorCaloriesPositive
