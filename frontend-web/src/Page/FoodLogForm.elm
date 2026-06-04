module Page.FoodLogForm exposing
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
import Data.Text as Text
import Data.Units as Units
import Element exposing (Element)
import Element.Font as Font
import Element.Input as Input
import Ui


type alias Model =
    { amount : String
    , unit : String
    , mealSlot : Maybe MealSlot
    , notes : String
    , error : Maybe String
    , submitting : Bool
    }


type Msg
    = AmountChanged String
    | UnitChanged String
    | MealSlotChanged (Maybe MealSlot)
    | NotesChanged String


type ValidationError
    = AmountRequired


initLogFormFromFood : Maybe MealSlot -> ProductDetail -> Model
initLogFormFromFood mealSlot food =
    { amount = food.defaultQuantity |> Maybe.withDefault "1"
    , unit = food.defaultUnit |> Maybe.withDefault "g"
    , mealSlot = mealSlot
    , notes = ""
    , error = Nothing
    , submitting = False
    }


initLogFormFromLog : FoodLog -> Model
initLogFormFromLog log =
    { amount = log.quantity.amount
    , unit = log.quantity.unit
    , mealSlot = Maybe.andThen MealSlot.fromString log.mealSlot
    , notes = log.notes |> Maybe.withDefault ""
    , error = Nothing
    , submitting = False
    }


update : Msg -> Model -> Model
update msg model =
    case msg of
        AmountChanged value ->
            { model | amount = value, error = Nothing }

        UnitChanged value ->
            { model | unit = value, error = Nothing }

        MealSlotChanged value ->
            { model | mealSlot = value, error = Nothing }

        NotesChanged value ->
            { model | notes = value, error = Nothing }


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
            [ mealSlotInput model
            , Ui.input "Amount" model.amount AmountChanged
            , unitInput food units model
            , Ui.input "Notes" model.notes NotesChanged
            ]
        ]


mealSlotInput : Model -> Element Msg
mealSlotInput model =
    Input.radio
        [ Element.spacing 8 ]
        { onChange = MealSlotChanged
        , selected = Just model.mealSlot
        , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Meal")
        , options =
            [ Input.option Nothing (Element.text "None")
            , Input.option (Just Breakfast) (Element.text (MealSlot.label Breakfast))
            , Input.option (Just Lunch) (Element.text (MealSlot.label Lunch))
            , Input.option (Just Dinner) (Element.text (MealSlot.label Dinner))
            , Input.option (Just Snack) (Element.text (MealSlot.label Snack))
            ]
        }


unitInput : Maybe ProductDetail -> List UnitItem -> Model -> Element Msg
unitInput food units model =
    Input.radio
        [ Element.spacing 8 ]
        { onChange = UnitChanged
        , selected = Just model.unit
        , label = Input.labelAbove [ Ui.body, Font.medium ] (Element.text "Unit")
        , options =
            unitOptions food units model.unit
                |> List.map (\unit -> Input.option unit.code (Element.text (Units.label unit)))
        }


unitOptions : Maybe ProductDetail -> List UnitItem -> String -> List UnitItem
unitOptions food units selectedUnit =
    Units.sourceForFood food units
        |> Units.ensureSelected selectedUnit
