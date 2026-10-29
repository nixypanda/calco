module Page.Goals.SettingsTest exposing (tests)

import Api.Client as Client
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.LocalCtx exposing (LocalCtx)
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Goals.Settings as S
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Goals.Settings"
        [ test "a user edits and saves goal targets" <|
            \_ ->
                loaded
                    |> step (S.CalorieTargetChanged "2150")
                    |> step (S.ProteinTargetChanged "170")
                    |> step (S.CarbsTargetChanged "210")
                    |> step (S.FatTargetChanged "70")
                    |> step S.SaveClicked
                    |> step (S.LocalCtxReceived context)
                    |> step (S.SaveCompleted (Ok savedSnapshot))
                    |> finish
                        (\( model, outMsg ) ->
                            { fields = fieldsOf model
                            , status = statusOf model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { fields = [ "2150", "170", "210", "70" ]
                                    , status = Just savedStatus
                                    , finalOut = S.NoOp
                                    }
                        )
        , test "a failed save keeps edits, retries, and a 401 expires the session" <|
            \_ ->
                loaded
                    |> step (S.CalorieTargetChanged "2150")
                    |> step (S.ProteinTargetChanged "170")
                    |> step (S.CarbsTargetChanged "210")
                    |> step (S.FatTargetChanged "70")
                    |> step S.SaveClicked
                    |> step (S.LocalCtxReceived context)
                    |> step (S.SaveCompleted (Err Client.NetworkError))
                    |> step S.SaveClicked
                    |> step (S.LocalCtxReceived context)
                    |> step (S.SaveCompleted (Err Fixtures.unauthorized))
                    |> finish
                        (\( model, outMsg ) ->
                            { fields = fieldsOf model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { fields = [ "2150", "170", "210", "70" ]
                                    , finalOut = S.SessionExpired
                                    }
                        )
        ]


stepWithOut :
    S.Msg
    -> S.Model
    -> ( S.Model, S.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            S.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey S.Model S.OutMsg


step : S.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( S.Model, S.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loaded : Journey
loaded =
    Story.start ( S.init |> Tuple.first, S.NoOp )
        |> step (S.GoalLoaded (Ok defaultSnapshot))


fieldsOf : S.Model -> List String
fieldsOf model =
    case model of
        S.Ready ready ->
            [ ready.form.calorieTarget
            , ready.form.proteinTargetG
            , ready.form.carbsTargetG
            , ready.form.fatTargetG
            ]

        _ ->
            []


statusOf : S.Model -> Maybe String
statusOf model =
    case model of
        S.Ready _ ->
            Just savedStatus

        _ ->
            Nothing


defaultSnapshot : GoalSnapshot
defaultSnapshot =
    snapshot Default Nothing 2290 160 255 70


savedSnapshot : GoalSnapshot
savedSnapshot =
    snapshot Saved (Just today) 2150 170 210 70


today : LocalDate
today =
    Fixtures.date "2026-06-16"


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


savedStatus : String
savedStatus =
    I18n.en
        (TidGoalSettingsStatusSavedFrom (LocalDate.display I18n.defaultLanguage today))
