module View.QuantityInput exposing (dropdown, select, text)

import Api.Foods exposing (UnitItem)
import Data.Units as Units
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
        , Ui.select config.unitLabel config.unit (unitOptions config.unit config.units) config.onUnitChange
        ]


text :
    { amountLabel : String
    , amount : String
    , onAmountChange : String -> msg
    , unitLabel : String
    , unit : String
    , onUnitChange : String -> msg
    }
    -> Element msg
text config =
    Element.row [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.input config.amountLabel config.amount config.onAmountChange
        , Ui.input config.unitLabel config.unit config.onUnitChange
        ]


unitOptions : String -> List UnitItem -> List ( String, String )
unitOptions selected units =
    units
        |> Units.ensureSelected selected
        |> Units.options
