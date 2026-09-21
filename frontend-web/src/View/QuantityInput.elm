module View.QuantityInput exposing (dropdown, unitOptions)

import Data.Food exposing (UnitItem)
import Data.Nutrition exposing (defaultCode)
import Element exposing (Device, Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.DesignTokens as DesignTokens
import Ui.Input as UiInput
import Ui.Theme exposing (Theme)


dropdown :
    Theme
    -> Language
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
dropdown theme language device config =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ UiInput.numericInput theme
            { label = config.amountLabel
            , value = config.amount
            , onChange = config.onAmountChange
            }
        , UiInput.selectDropdown device
            theme
            language
            { label = config.unitLabel
            , selected = config.unit
            , options = unitOptions language config.unit config.units
            , onChange = config.onUnitChange
            , isOpen = config.unitOpen
            , onToggle = config.onUnitToggle
            }
        ]


unitOptions : Language -> String -> List UnitItem -> List ( String, String )
unitOptions language selected units =
    units
        |> ensureSelected selected
        |> options language


ensureSelected : String -> List UnitItem -> List UnitItem
ensureSelected selectedUnit units =
    if String.isEmpty selectedUnit || List.any (\unit -> unit.code == selectedUnit) units then
        units

    else
        { code = selectedUnit, name = selectedUnit, kind = "" } :: units


options : Language -> List UnitItem -> List ( String, String )
options language units =
    case units of
        [] ->
            [ ( defaultCode, defaultCode ) ]

        _ ->
            List.map (\unit -> ( unit.code, label language unit )) units


label : Language -> UnitItem -> String
label language unit =
    if unit.name == unit.code then
        unit.code

    else
        I18n.t language (TidUiUnitWithCode unit.name unit.code)
