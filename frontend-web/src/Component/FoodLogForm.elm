module Component.FoodLogForm exposing
    ( Model
    , Msg(..)
    , OpenDropdown(..)
    , SubmitFailure(..)
    , SubmitState(..)
    , ValidationError(..)
    , applyQuantityDefault
    , createProductLogRequest
    , createUpdateLogRequest
    , fields
    , initLogFormFromFood
    , initLogFormFromLog
    , setSubmitState
    , submitFailureMessage
    , update
    )

import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest, UpdateLogRequest)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef exposing (ItemType(..))
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (Quantity, defaultCode)
import Element exposing (Device, Element)
import I18n
import Lib.Date as LocalDate
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Theme exposing (Theme)
import View.QuantityInput


defaultQuantity : String
defaultQuantity =
    "100"


sourceForFood : Maybe ProductDetail -> List UnitItem -> List UnitItem
sourceForFood food units =
    case Maybe.map .allowedUnits food of
        Just allowed ->
            if List.isEmpty allowed then
                units

            else
                allowed

        Nothing ->
            units



-- MODEL


type alias Model =
    { amount : String
    , unit : String
    , mealSlot : Maybe MealSlot
    , notes : String
    , openDropdown : OpenDropdown
    , submitState : SubmitState
    }


type OpenDropdown
    = NoDropdownOpen
    | MealSlotDropdownOpen
    | UnitDropdownOpen


type SubmitState
    = SubmitIdle
    | SubmitSubmitting
    | SubmitFailed SubmitFailure


type SubmitFailure
    = AmountRequiredMessage
    | InvalidDateMessage
    | RequestFailed String


type ValidationError
    = AmountRequired
    | InvalidDate


initLogFormFromFood : Maybe MealSlot -> ProductDetail -> Model
initLogFormFromFood mealSlot food =
    let
        fallback : ( String, String )
        fallback =
            List.head food.servings
                |> Maybe.map (\serving -> ( "1", serving.unit ))
                |> Maybe.withDefault ( defaultQuantity, defaultCode )

        portion : ( String, String )
        portion =
            Maybe.map2 Tuple.pair food.defaultQuantity food.defaultUnit
                |> Maybe.withDefault fallback
    in
    { amount = Tuple.first portion
    , unit = Tuple.second portion
    , mealSlot = mealSlot
    , notes = ""
    , openDropdown = NoDropdownOpen
    , submitState = SubmitIdle
    }


initLogFormFromLog : FoodLog -> Model
initLogFormFromLog log =
    { amount = log.quantity.amount
    , unit = log.quantity.unit
    , mealSlot = log.mealSlot
    , notes = log.notes |> Maybe.withDefault ""
    , openDropdown = NoDropdownOpen
    , submitState = SubmitIdle
    }


applyQuantityDefault : Quantity -> Model -> Model
applyQuantityDefault quantity model =
    { model
        | amount = quantity.amount
        , unit = quantity.unit
    }



-- UPDATE


type Msg
    = AmountChanged String
    | UnitChanged String
    | MealSlotChanged (Maybe MealSlot)
    | NotesChanged String
    | ToggleMealSlotDropdown
    | ToggleUnitDropdown


update : Msg -> Model -> Model
update msg model =
    case msg of
        AmountChanged value ->
            { model
                | amount = value
                , openDropdown = NoDropdownOpen
                , submitState = clearSubmitFailure model.submitState
            }

        UnitChanged value ->
            { model
                | unit = value
                , openDropdown = NoDropdownOpen
                , submitState = clearSubmitFailure model.submitState
            }

        MealSlotChanged value ->
            { model
                | mealSlot = value
                , openDropdown = NoDropdownOpen
                , submitState = clearSubmitFailure model.submitState
            }

        NotesChanged value ->
            { model
                | notes = value
                , openDropdown = NoDropdownOpen
                , submitState = clearSubmitFailure model.submitState
            }

        ToggleMealSlotDropdown ->
            { model
                | openDropdown =
                    if model.openDropdown == MealSlotDropdownOpen then
                        NoDropdownOpen

                    else
                        MealSlotDropdownOpen
            }

        ToggleUnitDropdown ->
            { model
                | openDropdown =
                    if model.openDropdown == UnitDropdownOpen then
                        NoDropdownOpen

                    else
                        UnitDropdownOpen
            }


clearSubmitFailure : SubmitState -> SubmitState
clearSubmitFailure submitState =
    case submitState of
        SubmitFailed _ ->
            SubmitIdle

        _ ->
            submitState


createProductLogRequest :
    String
    -> Maybe String
    -> String
    -> Model
    -> Result ValidationError CreateLogRequest
createProductLogRequest rawDate deviceTimezone productId model =
    if Text.isBlank model.amount then
        Err AmountRequired

    else
        case LocalDate.fromString rawDate of
            Nothing ->
                Err InvalidDate

            Just logDate ->
                Ok
                    { logDate = logDate
                    , deviceTimezone = deviceTimezone
                    , mealSlot = Maybe.map MealSlot.toString model.mealSlot
                    , item = { itemType = Product, id = productId }
                    , quantity = Quantity model.amount model.unit
                    , notes = Text.blankToMaybe model.notes
                    }


createUpdateLogRequest : Model -> Result ValidationError UpdateLogRequest
createUpdateLogRequest model =
    if Text.isBlank model.amount then
        Err AmountRequired

    else
        Ok
            { mealSlot = Maybe.map MealSlot.toString model.mealSlot
            , quantity = Quantity model.amount model.unit
            , notes = Text.blankToMaybe model.notes
            }


submitFailureMessage : SubmitFailure -> String
submitFailureMessage failure =
    case failure of
        AmountRequiredMessage ->
            I18n.en TidFoodLogAmountRequired

        InvalidDateMessage ->
            I18n.en TidFoodLogInvalidDeviceDate

        RequestFailed message ->
            message


setSubmitState : SubmitState -> Model -> Model
setSubmitState submitState model =
    { model | submitState = submitState }



-- VIEW


{-| The form controls as a flat list, so a page can place them inside its own
panel section instead of a standalone card.
-}
fields :
    Theme
    -> Language
    -> Device
    -> Maybe ProductDetail
    -> List UnitItem
    -> Model
    -> List (Element Msg)
fields theme language device food units model =
    (case submitError model.submitState of
        Just message ->
            [ Feedback.errorBanner theme message ]

        Nothing ->
            []
    )
        ++ [ mealSlotDropdown theme language device model
           , View.QuantityInput.dropdown theme
                language
                device
                { amountLabel = I18n.t language TidNutrientTableAmount
                , amount = model.amount
                , onAmountChange = AmountChanged
                , unitLabel = I18n.t language TidNutrientTableUnit
                , unit = model.unit
                , units = sourceForFood food units
                , onUnitChange = UnitChanged
                , unitOpen = model.openDropdown == UnitDropdownOpen
                , onUnitToggle = ToggleUnitDropdown
                }
           , UiInput.input theme
                { label = I18n.t language TidFoodLogNotes
                , value = model.notes
                , onChange = NotesChanged
                }
           ]


submitError : SubmitState -> Maybe String
submitError submitState =
    case submitState of
        SubmitFailed failure ->
            Just (submitFailureMessage failure)

        _ ->
            Nothing


mealSlotDropdown : Theme -> Language -> Device -> Model -> Element Msg
mealSlotDropdown theme language device model =
    UiInput.selectDropdown device
        theme
        language
        { label = I18n.t language TidTitleMeal
        , selected = model.mealSlot
        , options =
            [ ( Nothing, I18n.t language TidFoodEditorMealNone )
            , ( Just Breakfast, MealSlot.label language Breakfast )
            , ( Just Lunch, MealSlot.label language Lunch )
            , ( Just Dinner, MealSlot.label language Dinner )
            , ( Just Snack, MealSlot.label language Snack )
            , ( Just LateNightSnack, MealSlot.label language LateNightSnack )
            ]
        , onChange = MealSlotChanged
        , isOpen = model.openDropdown == MealSlotDropdownOpen
        , onToggle = ToggleMealSlotDropdown
        }
