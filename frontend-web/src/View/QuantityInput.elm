module View.QuantityInput exposing (dropdown, select)

import Api.Foods exposing (UnitItem)
import Data.Nutrition exposing (defaultCode)
import Element exposing (Element)
import Ui


dropdown :
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
dropdown config =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.input config.amountLabel config.amount config.onAmountChange
        , Ui.selectDropdown
            { label = config.unitLabel
            , selected = config.unit
            , options = unitOptions config.unit config.units
            , onChange = config.onUnitChange
            , isOpen = config.unitOpen
            , onToggle = config.onUnitToggle
            }
        ]


select :
    { amountLabel : String
    , amount : String
    , onAmountChange : String -> msg
    , unitLabel : String
    , unit : String
    , units : List UnitItem
    , onUnitChange : String -> msg
    }
    -> Element msg
select config =
    Element.row [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.input config.amountLabel config.amount config.onAmountChange
        , Ui.select config.unitLabel
            config.unit
            (unitOptions config.unit config.units)
            config.onUnitChange
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
