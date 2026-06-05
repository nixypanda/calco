module View.FoodLogForm exposing
    ( Model
    , Msg(..)
    , ValidationError(..)
    , createProductLogRequest
    , createUpdateLogRequest
    , initLogFormFromFood
    , initLogFormFromLog
    , update
    , view
    )

import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest, UpdateLogRequest)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (defaultCode)
import Data.Quantity exposing (Quantity)
import Element exposing (Element)
import Lib.Date as LocalDate
import Lib.Text as Text
import Ui
import View.QuantityInput


defaultQuantity : String
defaultQuantity =
    "1"


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


type alias Model =
    { amount : String
    , unit : String
    , mealSlot : Maybe MealSlot
    , notes : String
    , mealSlotOpen : Bool
    , unitOpen : Bool
    , error : Maybe String
    , submitting : Bool
    }


type Msg
    = AmountChanged String
    | UnitChanged String
    | MealSlotChanged (Maybe MealSlot)
    | NotesChanged String
    | ToggleMealSlotDropdown
    | ToggleUnitDropdown


type ValidationError
    = AmountRequired
    | InvalidDate


initLogFormFromFood : Maybe MealSlot -> ProductDetail -> Model
initLogFormFromFood mealSlot food =
    { amount = food.defaultQuantity |> Maybe.withDefault defaultQuantity
    , unit = food.defaultUnit |> Maybe.withDefault defaultCode
    , mealSlot = mealSlot
    , notes = ""
    , mealSlotOpen = False
    , unitOpen = False
    , error = Nothing
    , submitting = False
    }


initLogFormFromLog : FoodLog -> Model
initLogFormFromLog log =
    { amount = log.quantity.amount
    , unit = log.quantity.unit
    , mealSlot = Maybe.andThen MealSlot.fromString log.mealSlot
    , notes = log.notes |> Maybe.withDefault ""
    , mealSlotOpen = False
    , unitOpen = False
    , error = Nothing
    , submitting = False
    }


update : Msg -> Model -> Model
update msg model =
    case msg of
        AmountChanged value ->
            { model | amount = value, mealSlotOpen = False, unitOpen = False, error = Nothing }

        UnitChanged value ->
            { model | unit = value, unitOpen = False, error = Nothing }

        MealSlotChanged value ->
            { model | mealSlot = value, mealSlotOpen = False, error = Nothing }

        NotesChanged value ->
            { model | notes = value, mealSlotOpen = False, unitOpen = False, error = Nothing }

        ToggleMealSlotDropdown ->
            { model | mealSlotOpen = not model.mealSlotOpen, unitOpen = False }

        ToggleUnitDropdown ->
            { model | unitOpen = not model.unitOpen, mealSlotOpen = False }


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
                    , item = { itemType = "product", id = productId }
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


view : Maybe ProductDetail -> List UnitItem -> Model -> Element Msg
view food units model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , Ui.card
            [ mealSlotDropdown model
            , View.QuantityInput.dropdown
                { amountLabel = "Amount"
                , amount = model.amount
                , onAmountChange = AmountChanged
                , unitLabel = "Unit"
                , unit = model.unit
                , units = sourceForFood food units
                , onUnitChange = UnitChanged
                , unitOpen = model.unitOpen
                , onUnitToggle = ToggleUnitDropdown
                }
            , Ui.input "Notes" model.notes NotesChanged
            ]
        ]


mealSlotDropdown : Model -> Element Msg
mealSlotDropdown model =
    Ui.selectDropdown
        { label = "Meal"
        , selected = model.mealSlot
        , options =
            [ ( Nothing, "None" )
            , ( Just Breakfast, MealSlot.label Breakfast )
            , ( Just Lunch, MealSlot.label Lunch )
            , ( Just Dinner, MealSlot.label Dinner )
            , ( Just Snack, MealSlot.label Snack )
            ]
        , onChange = MealSlotChanged
        , isOpen = model.mealSlotOpen
        , onToggle = ToggleMealSlotDropdown
        }
