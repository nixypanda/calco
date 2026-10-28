module Page.Diary.SettingsTest exposing (tests)

import Api.Client as Client
import Data.DiaryPrefs exposing (DiaryPrefs)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Expect
import I18n
import Page.Diary.Settings as S
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Settings"
        [ test "a user changes meal slots and saves" <|
            \_ ->
                editedPrefs
                    |> step S.SaveClicked
                    |> step (S.SaveCompleted (Ok (prefs [ Lunch, Dinner ])))
                    |> finish
                        (\( model, outMsg ) ->
                            { screen = toScreen model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { screen =
                                        { selected = [ "Lunch", "Dinner" ]
                                        , error = Nothing
                                        , submit = Just ( savedLabel, False )
                                        }
                                    , finalOut = S.NoOp
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                editedPrefs
                    |> step S.SaveClicked
                    |> step (S.SaveCompleted (Err Client.NetworkError))
                    |> step S.SaveClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { request = saveRequest outMsg
                            , submit = (toScreen model).submit
                            }
                                |> Expect.equal
                                    { request = Just { enabledMealSlots = [ Lunch, Dinner ] }
                                    , submit = Just ( savingLabel, True )
                                    }
                        )
        , test "a failed load can be retried" <|
            \_ ->
                S.init
                    |> Story.start
                    |> step (S.PrefsLoaded (Err Client.NetworkError))
                    |> step S.RetryClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal S.RequestPrefs
                        )
        ]


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


saveRequest : S.OutMsg -> Maybe DiaryPrefs
saveRequest outMsg =
    case outMsg of
        S.RequestSave value ->
            Just value

        _ ->
            Nothing


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


loadedPrefs : Journey
loadedPrefs =
    S.init
        |> Story.start
        |> step (S.PrefsLoaded (Ok (prefs [ Breakfast, Lunch ])))


editedPrefs : Journey
editedPrefs =
    loadedPrefs
        |> step (S.SlotToggled Breakfast False)
        |> step (S.SlotToggled Dinner True)
