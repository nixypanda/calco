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
import Data.Quantity exposing (Quantity)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Route exposing (MealSlot(..))
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
    , mealSlot = Maybe.andThen mealSlotFromString log.mealSlot
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
    if String.isEmpty (String.trim model.amount) then
        Err AmountRequired

    else
        Ok
            { loggedAt = loggedAt
            , mealSlot = Maybe.map mealSlotToString model.mealSlot
            , item = { itemType = "product", id = productId }
            , quantity = Quantity model.amount model.unit
            , notes = blankToNothing model.notes
            }


createUpdateLogRequest : Model -> Result ValidationError UpdateLogRequest
createUpdateLogRequest model =
    if String.isEmpty (String.trim model.amount) then
        Err AmountRequired

    else
        Ok
            { mealSlot = Maybe.map mealSlotToString model.mealSlot
            , quantity = Quantity model.amount model.unit
            , notes = blankToNothing model.notes
            }


blankToNothing : String -> Maybe String
blankToNothing value =
    let
        trimmed : String
        trimmed =
            String.trim value
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just trimmed


mealSlotToString : MealSlot -> String
mealSlotToString slot =
    case slot of
        Breakfast ->
            "breakfast"

        Lunch ->
            "lunch"

        Dinner ->
            "dinner"

        Snack ->
            "snack"

        Other ->
            "other"


mealSlotFromString : String -> Maybe MealSlot
mealSlotFromString raw =
    case raw of
        "breakfast" ->
            Just Breakfast

        "lunch" ->
            Just Lunch

        "dinner" ->
            Just Dinner

        "snack" ->
            Just Snack

        "other" ->
            Just Other

        _ ->
            Nothing


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
        , Element.column
            [ Element.width Element.fill
            , Element.spacing 14
            , Element.padding 16
            , Background.color (Element.rgb255 255 255 255)
            , Border.rounded 8
            , Border.width 1
            , Border.color (Element.rgb255 229 231 235)
            ]
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
        , label = Input.labelAbove [ Font.size 14, Font.medium ] (Element.text "Meal")
        , options =
            [ Input.option Nothing (Element.text "None")
            , Input.option (Just Breakfast) (Element.text "Breakfast")
            , Input.option (Just Lunch) (Element.text "Lunch")
            , Input.option (Just Dinner) (Element.text "Dinner")
            , Input.option (Just Snack) (Element.text "Snack")
            ]
        }


unitInput : Maybe ProductDetail -> List UnitItem -> Model -> Element Msg
unitInput food units model =
    Input.radio
        [ Element.spacing 8 ]
        { onChange = UnitChanged
        , selected = Just model.unit
        , label = Input.labelAbove [ Font.size 14, Font.medium ] (Element.text "Unit")
        , options =
            unitOptions food units model.unit
                |> List.map (\unit -> Input.option unit.code (Element.text (unitLabel unit)))
        }


unitOptions : Maybe ProductDetail -> List UnitItem -> String -> List UnitItem
unitOptions food units selectedUnit =
    let
        source : List UnitItem
        source =
            case Maybe.map .allowedUnits food of
                Just allowed ->
                    if List.isEmpty allowed then
                        units

                    else
                        allowed

                _ ->
                    units
    in
    if String.isEmpty selectedUnit || List.any (\unit -> unit.code == selectedUnit) source then
        source

    else
        { code = selectedUnit, name = selectedUnit, kind = "" } :: source


unitLabel : UnitItem -> String
unitLabel unit =
    if unit.name == unit.code then
        unit.code

    else
        unit.name ++ " (" ++ unit.code ++ ")"
