module Component.FoodEditorTest exposing (tests)

import Component.FoodEditor as Form
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz2, test)


tests : Test
tests =
    describe "Component.FoodEditor custom-food mode"
        [ nameAndRowValidation
        , defaultPortionBranches
        , payloadTrimsAndFilters
        , categoryNormalization
        ]


nameAndRowValidation : Test
nameAndRowValidation =
    test "name, nutrient amounts, and serving grams are validated" <|
        \_ ->
            let
                base : Form.FormModel
                base =
                    Form.emptyForm

                named : Form.FormModel
                named =
                    { base | name = "Paneer" }
            in
            Expect.all
                [ \_ ->
                    Form.toCreateFoodRequest Form.emptyForm
                        |> Expect.equal (Err Form.NameRequired)
                , \_ ->
                    Form.toCreateFoodRequest { named | name = "   " }
                        |> Expect.equal (Err Form.NameRequired)
                , \_ ->
                    Form.toCreateFoodRequest
                        { named
                            | nutrients =
                                [ { code = "ENERGY_KCAL"
                                  , amount = "abc"
                                  , unit = "kcal"
                                  }
                                ]
                        }
                        |> Expect.equal (Err (Form.InvalidNutrientAmount "abc"))
                , \_ ->
                    Form.toCreateFoodRequest
                        { named
                            | nutrients =
                                [ { code = "ENERGY_KCAL"
                                  , amount = "-1"
                                  , unit = "kcal"
                                  }
                                ]
                        }
                        |> Expect.equal (Err (Form.InvalidNutrientAmount "-1"))
                , \_ ->
                    Form.toCreateFoodRequest
                        { named
                            | servings =
                                [ { unit = "piece", gramsPerUnit = "0" } ]
                        }
                        |> Expect.equal (Err (Form.InvalidServingGrams "0"))
                , \_ ->
                    Form.toCreateFoodRequest
                        { named
                            | servings =
                                [ { unit = "cup", gramsPerUnit = "180" }
                                , { unit = "cup", gramsPerUnit = "360" }
                                ]
                        }
                        |> Expect.equal (Err (Form.DuplicateServingUnit "cup"))
                ]
                ()


defaultPortionBranches : Test
defaultPortionBranches =
    test "default portions accept grams or a configured serving unit" <|
        \_ ->
            let
                empty : Form.FormModel
                empty =
                    Form.emptyForm

                base : Form.FormModel
                base =
                    { empty | name = "Paneer" }

                portion :
                    Form.FormModel
                    -> Result Form.ValidationError ( Maybe String, Maybe String )
                portion form =
                    Form.toCreateFoodRequest form
                        |> Result.map (\request -> ( request.defaultQuantity, request.defaultUnit ))
            in
            Expect.all
                [ \_ ->
                    portion { base | defaultQuantity = "100", defaultUnit = "g" }
                        |> Expect.equal (Ok ( Just "100", Just "g" ))
                , \_ ->
                    portion
                        { base
                            | defaultQuantity = "1"
                            , defaultUnit = "piece"
                            , servings = [ { unit = "piece", gramsPerUnit = "50" } ]
                        }
                        |> Expect.equal (Ok ( Just "1", Just "piece" ))
                , \_ ->
                    portion { base | defaultQuantity = "1", defaultUnit = "cup" }
                        |> Expect.equal (Err Form.InvalidDefaultPortion)
                ]
                ()


payloadTrimsAndFilters : Test
payloadTrimsAndFilters =
    test "create payload trims fields, filters incomplete rows, and lowercases categories" <|
        \_ ->
            let
                empty : Form.FormModel
                empty =
                    Form.emptyForm

                categoryBase : Form.CategoryInput
                categoryBase =
                    empty.categoryInput

                categoryInput : Form.CategoryInput
                categoryInput =
                    { categoryBase
                        | selected = Form.addCategoryTag "Dairy" []
                    }
            in
            Form.toCreateFoodRequest
                { empty
                    | name = "  Paneer  "
                    , brand = " "
                    , categoryInput = categoryInput
                    , nutrients =
                        [ { code = "PROTEIN_G", amount = "18", unit = "g" }
                        , { code = "", amount = "4", unit = "g" }
                        ]
                    , servings =
                        [ { unit = "piece", gramsPerUnit = "50" }
                        , { unit = "", gramsPerUnit = "5" }
                        ]
                }
                |> Result.map
                    (\request ->
                        { name = request.name
                        , brand = request.brand
                        , categories = request.categories
                        , defaultQuantity = request.defaultQuantity
                        , nutrients = request.nutrients
                        , servings = request.servings
                        }
                    )
                |> Expect.equal
                    (Ok
                        { name = "Paneer"
                        , brand = Nothing
                        , categories = [ "dairy" ]
                        , defaultQuantity = Nothing
                        , nutrients =
                            [ { code = "PROTEIN_G", amountPer100g = 18 } ]
                        , servings =
                            [ { unit = "piece", gramsPerUnit = 50 } ]
                        }
                    )


{-| Property: a new category is appended in first-occurrence order, normalized
to trimmed lowercase, never duplicates an existing tag, and is idempotent.
-}
categoryNormalization : Test
categoryNormalization =
    fuzz2 Fuzz.string
        (Fuzz.list Fuzz.string)
        "category tags preserve order, normalize text, and are idempotent"
    <|
        \raw selected ->
            let
                appended : String
                appended =
                    String.trim (String.toLower raw)

                result : List String
                result =
                    Form.addCategoryTag raw selected

                alreadyPresent : Bool
                alreadyPresent =
                    String.isEmpty appended || List.member appended selected
            in
            Expect.all
                [ \_ ->
                    List.take (List.length selected) result
                        |> Expect.equal selected
                , \_ ->
                    case List.drop (List.length selected) result of
                        [] ->
                            Expect.equal True alreadyPresent

                        [ tag ] ->
                            Expect.all
                                [ \_ -> Expect.equal appended tag
                                , \_ -> Expect.equal False (String.isEmpty appended)
                                , \_ -> Expect.equal False (List.member appended selected)
                                ]
                                ()

                        _ ->
                            Expect.fail "addCategoryTag appended more than one tag"
                , \_ ->
                    Form.addCategoryTag raw result
                        |> Expect.equal result
                ]
                ()
