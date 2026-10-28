module Page.Diary.SettingsTest exposing (tests)

{-| Diary-settings stories.

Load retry, save failure/retry, validation, and the page-level 401 wiring check
are steps inside the two user flows rather than standalone branch tests.

-}

import Api.Client as Client
import Data.DiaryPrefs exposing (DiaryPrefs)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Expect
import I18n
import Page.Diary.Settings as S
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Settings"
        [ test "a failed load retries, edits save through a failure, and the retry wins" <|
            \_ ->
                let
                    ( loading, initialOut ) =
                        S.init

                    failedLoad : S.Model
                    failedLoad =
                        step (S.PrefsLoaded (Err Client.NetworkError)) loading

                    ( retryingLoad, retryLoadOut ) =
                        stepOnce S.RetryClicked failedLoad

                    loaded : S.Model
                    loaded =
                        step
                            (S.PrefsLoaded (Ok (prefs [ LateNightSnack, Breakfast ])))
                            retryingLoad

                    ( edited, _ ) =
                        stepOnce (S.SlotToggled Lunch True) loaded

                    ( editedAgain, _ ) =
                        stepOnce (S.SlotToggled Breakfast False) edited

                    ( saving, saveOut ) =
                        stepOnce S.SaveClicked editedAgain

                    ( saveFailed, saveFailureOut ) =
                        stepOnce (S.SaveCompleted (Err Client.NetworkError)) saving

                    ( retryingSave, retrySaveOut ) =
                        stepOnce S.SaveClicked saveFailed

                    ( saved, finalOut ) =
                        stepOnce
                            (S.SaveCompleted (Ok (prefs [ Dinner, Lunch ])))
                            retryingSave
                in
                { initialOut = initialOut
                , failedLoad = toScreen failedLoad
                , retryLoadOut = retryLoadOut
                , loaded =
                    ( (toScreen loaded).selected, (toScreen loaded).submit )
                , edited = (toScreen editedAgain).selected
                , saveOut = saveOut
                , saving = (toScreen saving).submit
                , saveFailureOut = saveFailureOut
                , saveFailed = toScreen saveFailed
                , retrySaveOut = retrySaveOut
                , saved = toScreen saved
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { initialOut = S.RequestPrefs
                        , failedLoad = { emptyScreen | error = Just Fixtures.networkErrorMessage }
                        , retryLoadOut = S.RequestPrefs
                        , loaded =
                            ( [ "Breakfast", "Late-night Snack" ]
                            , Just ( saveLabel, False )
                            )
                        , edited = [ "Lunch", "Late-night Snack" ]
                        , saveOut =
                            S.RequestSave
                                { enabledMealSlots = [ Lunch, LateNightSnack ] }
                        , saving = Just ( savingLabel, True )
                        , saveFailureOut = S.NoOp
                        , saveFailed =
                            { readyScreen
                                | selected = [ "Lunch", "Late-night Snack" ]
                                , error = Just Fixtures.networkErrorMessage
                            }
                        , retrySaveOut =
                            S.RequestSave { enabledMealSlots = [ Lunch, LateNightSnack ] }
                        , saved =
                            { readyScreen
                                | selected = [ "Lunch", "Dinner" ]
                                , submit = Just ( savedLabel, False )
                            }
                        , finalOut = S.NoOp
                        }
        , test "clearing every slot blocks save until fixed, then a 401 expires the session" <|
            \_ ->
                let
                    loaded : S.Model
                    loaded =
                        S.init
                            |> Tuple.first
                            |> step (S.PrefsLoaded (Ok (prefs [ Breakfast, Lunch ])))

                    ( withoutBreakfast, _ ) =
                        stepOnce (S.SlotToggled Breakfast False) loaded

                    ( cleared, _ ) =
                        stepOnce (S.SlotToggled Lunch False) withoutBreakfast

                    ( invalid, validationOut ) =
                        stepOnce S.SaveClicked cleared

                    ( fixed, _ ) =
                        stepOnce (S.SlotToggled Dinner True) invalid

                    ( submitted, submitOut ) =
                        stepOnce S.SaveClicked fixed

                    finalOut : S.OutMsg
                    finalOut =
                        stepOnce (S.SaveCompleted (Err Fixtures.unauthorized)) submitted
                            |> Tuple.second
                in
                { loaded = (toScreen loaded).selected
                , cleared = (toScreen cleared).selected
                , validationOut = validationOut
                , invalid = toScreen invalid
                , fixed = (toScreen fixed).selected
                , submitOut = submitOut
                , submitted = (toScreen submitted).submit
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { loaded = [ "Breakfast", "Lunch" ]
                        , cleared = []
                        , validationOut = S.NoOp
                        , invalid = { readyScreen | error = Just validationMessage }
                        , fixed = [ "Dinner" ]
                        , submitOut = S.RequestSave { enabledMealSlots = [ Dinner ] }
                        , submitted = Just ( savingLabel, True )
                        , finalOut = S.SessionExpired
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { selected : List String
    , error : Maybe String
    , submit : Maybe ( String, Bool )
    }


toScreen : S.Model -> Screen
toScreen model =
    case model of
        S.Loading ->
            emptyScreen

        S.Failed message ->
            { emptyScreen | error = Just message }

        S.Ready ready ->
            { selected = List.map (MealSlot.label I18n.defaultLanguage) ready.selected
            , error = errorText ready.saveState
            , submit = Just (submitText ready.saveState)
            }


errorText : S.SaveState -> Maybe String
errorText state =
    case state of
        S.ValidationFailed message ->
            Just message

        S.SaveFailed message ->
            Just message

        _ ->
            Nothing


submitText : S.SaveState -> ( String, Bool )
submitText state =
    case state of
        S.Saving ->
            ( savingLabel, True )

        S.Saved ->
            ( savedLabel, False )

        _ ->
            ( saveLabel, False )


emptyScreen : Screen
emptyScreen =
    { selected = [], error = Nothing, submit = Nothing }


readyScreen : Screen
readyScreen =
    { selected = [], error = Nothing, submit = Just ( saveLabel, False ) }



-- HELPERS


step : S.Msg -> S.Model -> S.Model
step msg model =
    Tuple.first (stepOnce msg model)


stepOnce : S.Msg -> S.Model -> ( S.Model, S.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            S.update msg model
    in
    ( next, outMsg )


prefs : List MealSlot -> DiaryPrefs
prefs slots =
    { enabledMealSlots = slots }


saveLabel : String
saveLabel =
    I18n.en TidDiarySettingsSave


savingLabel : String
savingLabel =
    I18n.en TidCommonSaving


savedLabel : String
savedLabel =
    I18n.en TidDiarySettingsSaved


validationMessage : String
validationMessage =
    I18n.en TidDiarySettingsSelectAtLeastOne
