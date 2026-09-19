module View.QuantityInput exposing (dropdown, unitOptions)

import Data.Food exposing (UnitItem)
import Data.Nutrition exposing (defaultCode)
import Element exposing (Device, Element)
import Ui.DesignTokens as DesignTokens
import Ui.Input as UiInput
import Ui.Theme exposing (Theme)


dropdown :
    Theme
    -> Device
    ->
        { amountLabel : String
        , amount : String
        , onAmountChange : String -> msg
        , unitLabel : String
        , unit : String
        , units : List UnitItem
        , onUnitChange : String -> msg
        , unitOpen : Bool
        , onUnitToggle : msg
        }
    -> Element msg
dropdown theme device config =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ UiInput.decimalInput theme
            { label = config.amountLabel
            , value = config.amount
            , onChange = config.onAmountChange
            }
        , UiInput.selectDropdown device
            theme
            { label = config.unitLabel
            , selected = config.unit
            , options = unitOptions config.unit config.units
            , onChange = config.onUnitChange
            , isOpen = config.unitOpen
            , onToggle = config.onUnitToggle
            }
        ]


unitOptions : String -> List UnitItem -> List ( String, String )
unitOptions selected units =
    units
        |> ensureSelected selected
        |> options


ensureSelected : String -> List UnitItem -> List UnitItem
ensureSelected selectedUnit units =
    if String.isEmpty selectedUnit || List.any (\unit -> unit.code == selectedUnit) units then
        units

    else
        { code = selectedUnit, name = selectedUnit, kind = "" } :: units


options : List UnitItem -> List ( String, String )
options units =
    case units of
        [] ->
            [ ( defaultCode, defaultCode ) ]

        _ ->
            List.map (\unit -> ( unit.code, label unit )) units


label : UnitItem -> String
label unit =
    if unit.name == unit.code then
        unit.code

    else
        unit.name ++ " (" ++ unit.code ++ ")"
