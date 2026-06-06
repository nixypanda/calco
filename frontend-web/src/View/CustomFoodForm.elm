module View.CustomFoodForm exposing
    ( FormModel
    , Msg(..)
    , NutrientRow
    , ServingRow
    , ValidationError(..)
    , emptyForm
    , fromProductDetail
    , toCreateFoodRequest
    , update
    , view
    )

import Api.Foods exposing (CreateFoodRequest, NutrientItem, ProductDetail, UnitItem)
import Data.Nutrition exposing (defaultCode)
import Element exposing (Element)
import Element.Font as Font
import Lib.ListExtra as ListExtra
import Lib.Text as Text
import Ui
import View.QuantityInput


type alias FormModel =
    { name : String
    , brand : String
    , categories : String
    , servingSizeG : String
    , defaultQuantity : String
    , defaultUnit : String
    , nutrients : List NutrientRow
    , servings : List ServingRow
    , submitting : Bool
    , error : Maybe String
    }


type alias NutrientRow =
    { code : String
    , amountPer100g : String
    }


type alias ServingRow =
    { label : String
    , quantity : String
    , unit : String
    , grams : String
    }


type ValidationError
    = NameRequired


type Msg
    = NameChanged String
    | BrandChanged String
    | CategoriesChanged String
    | ServingSizeChanged String
    | DefaultQuantityChanged String
    | DefaultUnitChanged String
    | NutrientCodeChanged Int String
    | NutrientAmountChanged Int String
    | AddNutrientRow
    | RemoveNutrientRow Int
    | ServingLabelChanged Int String
    | ServingQuantityChanged Int String
    | ServingUnitChanged Int String
    | ServingGramsChanged Int String
    | AddServingRow
    | RemoveServingRow Int


emptyForm : FormModel
emptyForm =
    { name = ""
    , brand = ""
    , categories = ""
    , servingSizeG = ""
    , defaultQuantity = ""
    , defaultUnit = defaultCode
    , nutrients = [ emptyNutrientRow ]
    , servings = []
    , submitting = False
    , error = Nothing
    }


emptyNutrientRow : NutrientRow
emptyNutrientRow =
    { code = "", amountPer100g = "" }


emptyServingRow : ServingRow
emptyServingRow =
    { label = "", quantity = "", unit = defaultCode, grams = "" }


fromProductDetail : ProductDetail -> FormModel
fromProductDetail food =
    { emptyForm
        | name = food.name
        , brand = Maybe.withDefault "" food.brand
        , categories = formatInput food.categories
        , servingSizeG = Maybe.withDefault "" food.servingSizeG
        , defaultQuantity = Maybe.withDefault "" food.defaultQuantity
        , defaultUnit = Maybe.withDefault defaultCode food.defaultUnit
        , nutrients =
            case
                List.map
                    (\n -> { code = n.code, amountPer100g = n.amountPer100g })
                    food.nutrients
            of
                [] ->
                    [ emptyNutrientRow ]

                rows ->
                    rows
        , servings =
            List.map
                (\s ->
                    { label = s.label
                    , quantity = s.quantity
                    , unit = s.unit
                    , grams = s.grams
                    }
                )
                food.servings
    }


toCreateFoodRequest : FormModel -> Result ValidationError CreateFoodRequest
toCreateFoodRequest form =
    let
        name : String
        name =
            String.trim form.name
    in
    if String.isEmpty name then
        Err NameRequired

    else
        Ok
            { name = name
            , brand = Text.blankToMaybe form.brand
            , categories = parseInput form.categories
            , servingSizeG = Text.blankToMaybe form.servingSizeG
            , defaultQuantity = Text.blankToMaybe form.defaultQuantity
            , defaultUnit = Text.blankToMaybe form.defaultUnit
            , nutrients =
                form.nutrients
                    |> List.filter
                        (\row ->
                            not (String.isEmpty (String.trim row.code))
                                && not (String.isEmpty (String.trim row.amountPer100g))
                        )
                    |> List.map
                        (\row ->
                            { code = String.trim row.code
                            , amountPer100g = String.trim row.amountPer100g
                            }
                        )
            , servings =
                form.servings
                    |> List.filter
                        (\row ->
                            not (String.isEmpty (String.trim row.label))
                                && not (String.isEmpty (String.trim row.quantity))
                                && not (String.isEmpty (String.trim row.grams))
                        )
                    |> List.map
                        (\row ->
                            { label = String.trim row.label
                            , quantity = String.trim row.quantity
                            , unit =
                                if String.isEmpty (String.trim row.unit) then
                                    defaultCode

                                else
                                    String.trim row.unit
                            , grams = String.trim row.grams
                            }
                        )
            }


update : Msg -> FormModel -> FormModel
update msg form =
    case msg of
        NameChanged value ->
            { form | name = value }

        BrandChanged value ->
            { form | brand = value }

        CategoriesChanged value ->
            { form | categories = value }

        ServingSizeChanged value ->
            { form | servingSizeG = value }

        DefaultQuantityChanged value ->
            { form | defaultQuantity = value }

        DefaultUnitChanged value ->
            { form | defaultUnit = value }

        NutrientCodeChanged index value ->
            { form
                | nutrients =
                    ListExtra.updateAt
                        index
                        (\row -> { row | code = value })
                        form.nutrients
            }

        NutrientAmountChanged index value ->
            { form
                | nutrients =
                    ListExtra.updateAt
                        index
                        (\row -> { row | amountPer100g = value })
                        form.nutrients
            }

        AddNutrientRow ->
            { form | nutrients = form.nutrients ++ [ emptyNutrientRow ] }

        RemoveNutrientRow index ->
            if List.length form.nutrients <= 1 then
                form

            else
                { form | nutrients = ListExtra.removeAt index form.nutrients }

        ServingLabelChanged index value ->
            { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | label = value })
                        form.servings
            }

        ServingQuantityChanged index value ->
            { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | quantity = value })
                        form.servings
            }

        ServingUnitChanged index value ->
            { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | unit = value })
                        form.servings
            }

        ServingGramsChanged index value ->
            { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | grams = value })
                        form.servings
            }

        AddServingRow ->
            { form | servings = form.servings ++ [ emptyServingRow ] }

        RemoveServingRow index ->
            { form | servings = ListExtra.removeAt index form.servings }


view : List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing 14 ]
        [ Ui.maybeErrorBanner form.error
        , section "Basic Info"
            [ Ui.input "Name" form.name NameChanged
            , Ui.input "Brand" form.brand BrandChanged
            , Ui.input "Categories" form.categories CategoriesChanged
            ]
        , section "Portion Info"
            [ Ui.input "Serving Size (g)" form.servingSizeG ServingSizeChanged
            , View.QuantityInput.select
                { amountLabel = "Default Quantity"
                , amount = form.defaultQuantity
                , onAmountChange = DefaultQuantityChanged
                , unitLabel = "Default Unit"
                , unit = form.defaultUnit
                , units = units
                , onUnitChange = DefaultUnitChanged

                -- , unitOpen = False
                -- , onUnitToggle = DefaultUnitChanged
                }
            ]
        , section "Nutrients (per 100g)"
            (List.indexedMap (nutrientRowView nutrients) form.nutrients
                ++ [ Ui.button "+ Add Nutrient" AddNutrientRow ]
            )
        , section "Servings"
            (List.indexedMap (servingRowView units) form.servings
                ++ [ Ui.button "+ Add Serving" AddServingRow ]
            )
        ]


section : String -> List (Element msg) -> Element msg
section title children =
    Element.column [ Element.width Element.fill, Element.spacing 8 ]
        (Element.el [ Ui.heading3, Font.bold ] (Element.text title) :: children)


nutrientRowView : List NutrientItem -> Int -> NutrientRow -> Element Msg
nutrientRowView nutrients index row =
    Element.wrappedRow [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.select
            "Nutrient"
            row.code
            (( "", "Select nutrient..." )
                :: List.map (\n -> ( n.code, n.name )) nutrients
            )
            (NutrientCodeChanged index)
        , Ui.input "Amount" row.amountPer100g (NutrientAmountChanged index)
        , Ui.dangerIconButton
            { label = "×"
            , title = "Remove"
            , onPress = RemoveNutrientRow index
            }
        ]


servingRowView : List UnitItem -> Int -> ServingRow -> Element Msg
servingRowView units index row =
    Element.wrappedRow [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.input "Label" row.label (ServingLabelChanged index)
        , View.QuantityInput.select
            { amountLabel = "Qty"
            , amount = row.quantity
            , onAmountChange = ServingQuantityChanged index
            , unitLabel = "Unit"
            , unit = row.unit
            , units = units
            , onUnitChange = ServingUnitChanged index
            }
        , Ui.input "Grams" row.grams (ServingGramsChanged index)
        , Ui.dangerIconButton
            { label = "×"
            , title = "Remove"
            , onPress = RemoveServingRow index
            }
        ]


parseInput : String -> List String
parseInput raw =
    Text.commaSeparatedUniqueLower raw


formatInput : List String -> String
formatInput categories =
    String.join ", " categories
