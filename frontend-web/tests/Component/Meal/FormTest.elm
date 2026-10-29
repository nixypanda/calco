module Component.Meal.FormTest exposing (tests)

import Component.Meal.Form as Form
    exposing
        ( ComponentRow
        , FormFields
        )
import Data.ItemRef as ItemRef
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Component.Meal.Form" [ validation, payloadBranches, componentFiltering ]


validation : Test
validation =
    test "a meal requires a non-blank name and at least one non-blank product" <|
        \_ ->
            Expect.all
                [ \_ ->
                    Form.toMealRequest (form "" "" [ row 1 "food-1" "100" "g" ])
                        |> Expect.equal (Err Form.MealNameRequired)
                , \_ ->
                    Form.toMealRequest (form "   " "" [ row 1 "food-1" "100" "g" ])
                        |> Expect.equal (Err Form.MealNameRequired)
                , \_ ->
                    Form.toMealRequest (form "Lunch" "" [])
                        |> Expect.equal (Err Form.ComponentRequired)
                , \_ ->
                    Form.toMealRequest
                        (form "Lunch"
                            ""
                            [ row 1 "" "100" "g"
                            , row 2 "   " "100" "g"
                            ]
                        )
                        |> Expect.equal (Err Form.ComponentRequired)
                ]
                ()


{-| Payload branches: trim the name/notes/component fields, omit a blank total
portion, and default a blank component quantity/unit to 100 g.
-}
payloadBranches : Test
payloadBranches =
    test "a valid form trims fields, omits a blank total, and defaults components" <|
        \_ ->
            let
                base : FormFields
                base =
                    form "  Lunch  " " 500 " [ row 1 "  food-1  " "  2 " " piece " ]

                mapped : FormFields
                mapped =
                    { base
                        | notes = "  note  "
                        , totalUnit = "  ml "
                    }
            in
            Expect.all
                [ \_ ->
                    Form.toMealRequest mapped
                        |> Expect.equal
                            (Ok
                                { name = "Lunch"
                                , notes = Just "note"
                                , totalQuantity = Just { amount = "500", unit = "ml" }
                                , components =
                                    [ { item = { itemType = ItemRef.Product, id = "food-1" }
                                      , quantity = { amount = "2", unit = "piece" }
                                      }
                                    ]
                                }
                            )
                , \_ ->
                    Form.toMealRequest (form "Meal" "   " [ row 1 "food-1" "100" "g" ])
                        |> Result.map .totalQuantity
                        |> Expect.equal (Ok Nothing)
                , \_ ->
                    Form.toMealRequest (form "Meal" "" [ row 1 "food-1" "   " "   " ])
                        |> Result.map (.components >> List.head)
                        |> Expect.equal
                            (Ok
                                (Just
                                    { item = { itemType = ItemRef.Product, id = "food-1" }
                                    , quantity = { amount = "100", unit = "g" }
                                    }
                                )
                            )
                ]
                ()


{-| Property: the payload keeps exactly the rows whose product ID is non-blank
after trimming, in input order.
-}
componentFiltering : Test
componentFiltering =
    fuzz (Fuzz.list componentInput)
        "component payload includes only rows with non-blank product IDs"
    <|
        \inputs ->
            let
                rows : List ComponentRow
                rows =
                    List.indexedMap
                        (\index ( productId, quantityValue ) ->
                            let
                                base : ComponentRow
                                base =
                                    Form.emptyComponentRow (index + 1)
                            in
                            { base
                                | productId = productId
                                , quantity = quantityValue
                            }
                        )
                        inputs

                expectedIds : List String
                expectedIds =
                    inputs
                        |> List.map Tuple.first
                        |> List.map String.trim
                        |> List.filter (not << String.isEmpty)
            in
            Form.toMealRequest (form "Meal" "" rows)
                |> Result.map (.components >> List.map (.item >> .id))
                |> Expect.equal
                    (if List.isEmpty expectedIds then
                        Err Form.ComponentRequired

                     else
                        Ok expectedIds
                    )



-- HELPERS


form : String -> String -> List ComponentRow -> FormFields
form name totalQuantity components =
    let
        base : FormFields
        base =
            Form.emptyFormFields
    in
    { base
        | name = name
        , totalQuantity = totalQuantity
        , components = components
    }


row : Form.RowId -> String -> String -> String -> ComponentRow
row rowId productId quantityValue unit =
    let
        base : ComponentRow
        base =
            Form.emptyComponentRow rowId
    in
    { base
        | productId = productId
        , quantity = quantityValue
        , unit = unit
    }


componentInput : Fuzz.Fuzzer ( String, String )
componentInput =
    Fuzz.map2 Tuple.pair
        (Fuzz.oneOfValues [ "", "   ", "food-1", "  food-2  " ])
        (Fuzz.oneOfValues [ "100", "  1.5 ", "" ])
