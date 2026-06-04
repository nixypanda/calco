module Page.CustomFood.Form exposing
    ( FormModel
    , Msg(..)
    , NutrientRow
    , ServingRow
    , ValidationError(..)
    , emptyForm
    , formatCategoriesInput
    , fromProductDetail
    , parseCategoriesInput
    , toCreateFoodRequest
    , update
    , view
    )

import Api.Foods as Foods exposing (CreateFoodRequest, NutrientItem, ProductDetail, UnitItem)
import Element exposing (Element)
import Element.Font as Font
import Element.Input as Input
import Ui


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
    , defaultUnit = "g"
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
    { label = "", quantity = "", unit = "g", grams = "" }


fromProductDetail : ProductDetail -> FormModel
fromProductDetail food =
    { emptyForm
        | name = food.name
        , brand = Maybe.withDefault "" food.brand
        , categories = formatCategoriesInput food.categories
        , servingSizeG = Maybe.withDefault "" food.servingSizeG
        , defaultQuantity = Maybe.withDefault "" food.defaultQuantity
        , defaultUnit = Maybe.withDefault "g" food.defaultUnit
        , nutrients =
            case List.map (\n -> { code = n.code, amountPer100g = n.amountPer100g }) food.nutrients of
                [] ->
                    [ emptyNutrientRow ]

                rows ->
                    rows
        , servings = List.map (\s -> { label = s.label, quantity = s.quantity, unit = s.unit, grams = s.grams }) food.servings
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
            , brand = blankToMaybe form.brand
            , categories = parseCategoriesInput form.categories
            , servingSizeG = blankToMaybe form.servingSizeG
            , defaultQuantity = blankToMaybe form.defaultQuantity
            , defaultUnit = blankToMaybe form.defaultUnit
            , nutrients =
                form.nutrients
                    |> List.filter (\row -> not (String.isEmpty (String.trim row.code)) && not (String.isEmpty (String.trim row.amountPer100g)))
                    |> List.map (\row -> { code = String.trim row.code, amountPer100g = String.trim row.amountPer100g })
            , servings =
                form.servings
                    |> List.filter (\row -> not (String.isEmpty (String.trim row.label)) && not (String.isEmpty (String.trim row.quantity)) && not (String.isEmpty (String.trim row.grams)))
                    |> List.map
                        (\row ->
                            { label = String.trim row.label
                            , quantity = String.trim row.quantity
                            , unit =
                                if String.isEmpty (String.trim row.unit) then
                                    "g"

                                else
                                    String.trim row.unit
                            , grams = String.trim row.grams
                            }
                        )
            }


parseCategoriesInput : String -> List String
parseCategoriesInput raw =
    raw
        |> String.split ","
        |> List.foldl addCategory []
        |> List.reverse


addCategory : String -> List String -> List String
addCategory raw categories =
    let
        normalized : String
        normalized =
            raw |> String.trim |> String.toLower
    in
    if String.isEmpty normalized || List.member normalized categories then
        categories

    else
        normalized :: categories


formatCategoriesInput : List String -> String
formatCategoriesInput categories =
    String.join ", " categories


blankToMaybe : String -> Maybe String
blankToMaybe raw =
    let
        trimmed : String
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just trimmed


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
            { form | nutrients = updateAt index (\row -> { row | code = value }) form.nutrients }

        NutrientAmountChanged index value ->
            { form | nutrients = updateAt index (\row -> { row | amountPer100g = value }) form.nutrients }

        AddNutrientRow ->
            { form | nutrients = form.nutrients ++ [ emptyNutrientRow ] }

        RemoveNutrientRow index ->
            if List.length form.nutrients <= 1 then
                form

            else
                { form | nutrients = removeAt index form.nutrients }

        ServingLabelChanged index value ->
            { form | servings = updateAt index (\row -> { row | label = value }) form.servings }

        ServingQuantityChanged index value ->
            { form | servings = updateAt index (\row -> { row | quantity = value }) form.servings }

        ServingUnitChanged index value ->
            { form | servings = updateAt index (\row -> { row | unit = value }) form.servings }

        ServingGramsChanged index value ->
            { form | servings = updateAt index (\row -> { row | grams = value }) form.servings }

        AddServingRow ->
            { form | servings = form.servings ++ [ emptyServingRow ] }

        RemoveServingRow index ->
            { form | servings = removeAt index form.servings }


updateAt : Int -> (a -> a) -> List a -> List a
updateAt target change items =
    items
        |> List.indexedMap
            (\index item ->
                if index == target then
                    change item

                else
                    item
            )


removeAt : Int -> List a -> List a
removeAt target items =
    items
        |> List.indexedMap Tuple.pair
        |> List.filter (\( index, _ ) -> index /= target)
        |> List.map Tuple.second


view : List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing 14 ]
        [ case form.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , section "Basic Info"
            [ Ui.input "Name" form.name NameChanged
            , Ui.input "Brand" form.brand BrandChanged
            , Ui.input "Categories" form.categories CategoriesChanged
            ]
        , section "Portion Info"
            [ Ui.input "Serving Size (g)" form.servingSizeG ServingSizeChanged
            , Ui.input "Default Quantity" form.defaultQuantity DefaultQuantityChanged
            , simpleSelect "Default Unit" form.defaultUnit DefaultUnitChanged (unitOptions units)
            ]
        , section "Nutrients (per 100g)"
            (List.indexedMap (nutrientRowView nutrients) form.nutrients ++ [ Ui.button "+ Add Nutrient" AddNutrientRow ])
        , section "Servings"
            (List.indexedMap (servingRowView units) form.servings ++ [ Ui.button "+ Add Serving" AddServingRow ])
        ]


section : String -> List (Element msg) -> Element msg
section title children =
    Element.column [ Element.width Element.fill, Element.spacing 8 ]
        (Element.el [ Font.size 18, Font.bold ] (Element.text title) :: children)


nutrientRowView : List NutrientItem -> Int -> NutrientRow -> Element Msg
nutrientRowView nutrients index row =
    Element.row [ Element.width Element.fill, Element.spacing 8 ]
        [ simpleSelect "Nutrient" row.code (NutrientCodeChanged index) (( "", "Select nutrient..." ) :: List.map (\n -> ( n.code, n.name )) nutrients)
        , Ui.input "Amount" row.amountPer100g (NutrientAmountChanged index)
        , Ui.button "Remove" (RemoveNutrientRow index)
        ]


servingRowView : List UnitItem -> Int -> ServingRow -> Element Msg
servingRowView units index row =
    Element.row [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.input "Label" row.label (ServingLabelChanged index)
        , Ui.input "Qty" row.quantity (ServingQuantityChanged index)
        , simpleSelect "Unit" row.unit (ServingUnitChanged index) (unitOptions units)
        , Ui.input "Grams" row.grams (ServingGramsChanged index)
        , Ui.button "Remove" (RemoveServingRow index)
        ]


simpleSelect : String -> String -> (String -> msg) -> List ( String, String ) -> Element msg
simpleSelect label value onChange options =
    Input.radio
        [ Element.spacing 4 ]
        { onChange = onChange
        , selected = Just value
        , label = Input.labelAbove [ Font.size 14, Font.medium ] (Element.text label)
        , options = List.map (\( code, name ) -> Input.option code (Element.text name)) options
        }


unitOptions : List UnitItem -> List ( String, String )
unitOptions units =
    case units of
        [] ->
            [ ( "g", "g" ) ]

        _ ->
            List.map (\unit -> ( unit.code, unit.name ++ " (" ++ unit.code ++ ")" )) units
