module Data.Units exposing (ensureSelected, label, options, sourceForFood)

import Api.Foods exposing (ProductDetail, UnitItem)


label : UnitItem -> String
label unit =
    if unit.name == unit.code then
        unit.code

    else
        unit.name ++ " (" ++ unit.code ++ ")"


options : List UnitItem -> List ( String, String )
options units =
    case units of
        [] ->
            [ ( "g", "g" ) ]

        _ ->
            List.map (\unit -> ( unit.code, label unit )) units


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


ensureSelected : String -> List UnitItem -> List UnitItem
ensureSelected selectedUnit units =
    if String.isEmpty selectedUnit || List.any (\unit -> unit.code == selectedUnit) units then
        units

    else
        { code = selectedUnit, name = selectedUnit, kind = "" } :: units
