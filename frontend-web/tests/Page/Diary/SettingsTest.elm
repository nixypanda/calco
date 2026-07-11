module Page.Diary.SettingsTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Expect
import Page.Diary.Settings as Settings
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Diary.Settings"
        [ test "loads preferences in canonical order" <|
            \_ ->
                Settings.update
                    (Settings.PreferencesLoaded
                        (Ok { enabledMealSlots = [ LateNightSnack, Breakfast ] })
                    )
                    Settings.Loading
                    |> selected
                    |> Expect.equal [ Breakfast, LateNightSnack ]
        , test "cannot save an empty selection" <|
            \_ ->
                Settings.update
                    Settings.SaveClicked
                    (Settings.Ready { selected = [], saveState = Settings.Editing })
                    |> (\( model, _, outMsg ) -> ( saveState model, outMsg ))
                    |> Expect.equal
                        ( Just (Settings.ValidationFailed "Select at least one meal slot.")
                        , Settings.NoOp
                        )
        , test "saves complete selection in canonical order" <|
            \_ ->
                Settings.update
                    Settings.SaveClicked
                    (Settings.Ready
                        { selected = [ Breakfast, LateNightSnack ]
                        , saveState = Settings.Editing
                        }
                    )
                    |> (\( _, _, outMsg ) -> outMsg)
                    |> Expect.equal
                        (Settings.RequestSave
                            { enabledMealSlots = [ Breakfast, LateNightSnack ] }
                        )
        ]


selected : ( Settings.Model, Cmd Settings.Msg, Settings.OutMsg ) -> List MealSlot
selected ( model, _, _ ) =
    case model of
        Settings.Ready loaded ->
            loaded.selected

        _ ->
            []


saveState : Settings.Model -> Maybe Settings.SaveState
saveState model =
    case model of
        Settings.Ready loaded ->
            Just loaded.saveState

        _ ->
            Nothing
