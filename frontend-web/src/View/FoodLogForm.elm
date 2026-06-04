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
import Data.Quantity exposing (Quantity)
import Data.Units as Units
import Element exposing (Element)
import Lib.Text as Text
import Ui


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


initLogFormFromFood : Maybe MealSlot -> ProductDetail -> Model
initLogFormFromFood mealSlot food =
    { amount = food.defaultQuantity |> Maybe.withDefault Units.defaultQuantity
    , unit = food.defaultUnit |> Maybe.withDefault Units.defaultCode
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


createProductLogRequest : String -> String -> Model -> Result ValidationError CreateLogRequest
createProductLogRequest loggedAt productId model =
    if Text.isBlank model.amount then
        Err AmountRequired

    else
        Ok
            { loggedAt = loggedAt
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
            , Ui.input "Amount" model.amount AmountChanged
            , unitDropdown food units model
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


unitDropdown : Maybe ProductDetail -> List UnitItem -> Model -> Element Msg
unitDropdown food units model =
    let
        source : List UnitItem
        source =
            Units.sourceForFood food units
                |> Units.ensureSelected model.unit
    in
    Ui.selectDropdown
        { label = "Unit"
        , selected = model.unit
        , options = List.map (\u -> ( u.code, Units.label u )) source
        , onChange = UnitChanged
        , isOpen = model.unitOpen
        , onToggle = ToggleUnitDropdown
        }
