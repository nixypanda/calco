module View.CustomFoodForm exposing
    ( CategoryInput
    , FormModel
    , Msg(..)
    , NutrientRow
    , OutMsg(..)
    , ServingRow
    , ValidationError(..)
    , addCategoryTag
    , emptyForm
    , fromProductDetail
    , padUnitLabel
    , toCreateFoodRequest
    , update
    , view
    )

import Api.Client as Client
import Api.Foods
    exposing
        ( CategorySuggestion
        , CategorySuggestionRequest
        , CreateFoodRequest
        , NutrientItem
        , ProductDetail
        , UnitItem
        )
import Data.Nutrition exposing (defaultCode)
import Dict exposing (Dict)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.ListExtra as ListExtra
import Lib.Text as Text
import Ui
import View.QuantityInput


type alias FormModel =
    { name : String
    , brand : String
    , categoryInput : CategoryInput
    , servingSizeG : String
    , defaultQuantity : String
    , defaultUnit : String
    , defaultUnitOpen : Bool
    , nutrientCatalog : Dict String String
    , nutrients : List NutrientRow
    , servings : List ServingRow
    , submitting : Bool
    , error : Maybe String
    }


type alias CategoryInput =
    { selected : List String
    , query : String
    , suggestions : List CategorySuggestion
    , token : Int
    , open : Bool
    }


type alias NutrientRow =
    { code : String
    , codeOpen : Bool
    , amountPer100g : String
    , unit : String
    }


type alias ServingRow =
    { label : String
    , quantity : String
    , unit : String
    , unitOpen : Bool
    , grams : String
    }


type ValidationError
    = NameRequired
    | InvalidNutrientAmount String
    | InvalidServingQuantity String
    | InvalidServingGrams String


type Msg
    = NameChanged String
    | BrandChanged String
    | ServingSizeChanged String
    | DefaultQuantityChanged String
    | DefaultUnitChanged String
    | ToggleDefaultUnitDropdown
    | NutrientsLoaded (List NutrientItem)
    | CategoryQueryChanged String
    | AddCategory String
    | RemoveCategory String
    | AcceptCategorySuggestion String
    | CategorySuggestionsLoaded Int (Result Client.ApiError (List CategorySuggestion))
    | NutrientCodeChanged Int String
    | ToggleNutrientCodeDropdown Int
    | NutrientAmountChanged Int String
    | AddNutrientRow
    | RemoveNutrientRow Int
    | ServingLabelChanged Int String
    | ServingQuantityChanged Int String
    | ServingUnitChanged Int String
    | ToggleServingUnitDropdown Int
    | ServingGramsChanged Int String
    | AddServingRow
    | RemoveServingRow Int


type OutMsg
    = NoOutMsg
    | RequestCategorySuggestions Int CategorySuggestionRequest


emptyForm : FormModel
emptyForm =
    { name = ""
    , brand = ""
    , categoryInput = emptyCategoryInput
    , servingSizeG = ""
    , defaultQuantity = ""
    , defaultUnit = defaultCode
    , defaultUnitOpen = False
    , nutrientCatalog = Dict.empty
    , nutrients = [ emptyNutrientRow ]
    , servings = []
    , submitting = False
    , error = Nothing
    }


emptyCategoryInput : CategoryInput
emptyCategoryInput =
    { selected = []
    , query = ""
    , suggestions = []
    , token = 0
    , open = False
    }


emptyNutrientRow : NutrientRow
emptyNutrientRow =
    { code = ""
    , codeOpen = False
    , amountPer100g = ""
    , unit = ""
    }


emptyServingRow : ServingRow
emptyServingRow =
    { label = "", quantity = "", unit = defaultCode, unitOpen = False, grams = "" }


fromProductDetail : ProductDetail -> FormModel
fromProductDetail food =
    { emptyForm
        | name = food.name
        , brand = Maybe.withDefault "" food.brand
        , categoryInput =
            { emptyCategoryInput | selected = List.map String.toLower food.categories }
        , servingSizeG = Maybe.withDefault "" food.servingSizeG
        , defaultQuantity = Maybe.withDefault "" food.defaultQuantity
        , defaultUnit = Maybe.withDefault defaultCode food.defaultUnit
        , nutrients =
            case
                List.map
                    (\n ->
                        { code = n.code
                        , codeOpen = False
                        , amountPer100g = n.amountPer100g
                        , unit = n.unit
                        }
                    )
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
                    , unitOpen = False
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
        let
            nutrientsResult : Result ValidationError (List Api.Foods.CreateFoodNutrientRequest)
            nutrientsResult =
                form.nutrients
                    |> List.filter hasNutrientInput
                    |> List.map toNutrientRequest
                    |> combineErrors

            servingsResult : Result ValidationError (List Api.Foods.CreateFoodServingRequest)
            servingsResult =
                form.servings
                    |> List.filter hasServingInput
                    |> List.map toServingRequest
                    |> combineErrors
        in
        Result.map2
            (\nutrients servings ->
                { name = name
                , brand = Text.blankToMaybe form.brand
                , categories = form.categoryInput.selected
                , servingSizeG = Text.blankToMaybe form.servingSizeG
                , defaultQuantity = Text.blankToMaybe form.defaultQuantity
                , defaultUnit = Text.blankToMaybe form.defaultUnit
                , nutrients = nutrients
                , servings = servings
                }
            )
            nutrientsResult
            servingsResult


hasNutrientInput : NutrientRow -> Bool
hasNutrientInput row =
    not (String.isEmpty (String.trim row.code))
        && not (String.isEmpty (String.trim row.amountPer100g))


hasServingInput : ServingRow -> Bool
hasServingInput row =
    not (String.isEmpty (String.trim row.label))
        && not (String.isEmpty (String.trim row.quantity))
        && not (String.isEmpty (String.trim row.grams))


toNutrientRequest : NutrientRow -> Result ValidationError Api.Foods.CreateFoodNutrientRequest
toNutrientRequest row =
    case String.toFloat (String.trim row.amountPer100g) of
        Just amount ->
            if amount < 0 then
                Err (InvalidNutrientAmount row.amountPer100g)

            else
                Ok
                    { code = String.trim row.code
                    , amountPer100g = amount
                    }

        Nothing ->
            Err (InvalidNutrientAmount row.amountPer100g)


toServingRequest : ServingRow -> Result ValidationError Api.Foods.CreateFoodServingRequest
toServingRequest row =
    let
        quantity : Result ValidationError Float
        quantity =
            case String.toFloat (String.trim row.quantity) of
                Just v ->
                    if v > 0 then
                        Ok v

                    else
                        Err (InvalidServingQuantity row.quantity)

                Nothing ->
                    Err (InvalidServingQuantity row.quantity)

        grams : Result ValidationError Float
        grams =
            case String.toFloat (String.trim row.grams) of
                Just v ->
                    if v > 0 then
                        Ok v

                    else
                        Err (InvalidServingGrams row.grams)

                Nothing ->
                    Err (InvalidServingGrams row.grams)
    in
    Result.map2
        (\q g ->
            { label = String.trim row.label
            , quantity = q
            , unit = String.trim row.unit
            , grams = g
            }
        )
        quantity
        grams


combineErrors : List (Result e a) -> Result e (List a)
combineErrors results =
    case results of
        [] ->
            Ok []

        x :: xs ->
            case x of
                Err e ->
                    Err e

                Ok v ->
                    combineErrors xs |> Result.map (\rest -> v :: rest)


categorySuggestionsRequest : String -> CategorySuggestionRequest
categorySuggestionsRequest query =
    { query = String.trim query, limit = 8 }


update : Msg -> FormModel -> ( FormModel, Cmd Msg, OutMsg )
update msg form =
    case msg of
        NameChanged value ->
            ( { form | name = value, error = Nothing }, Cmd.none, NoOutMsg )

        BrandChanged value ->
            ( { form | brand = value, error = Nothing }, Cmd.none, NoOutMsg )

        ServingSizeChanged value ->
            ( { form | servingSizeG = value, error = Nothing }, Cmd.none, NoOutMsg )

        DefaultQuantityChanged value ->
            ( { form | defaultQuantity = value, error = Nothing }, Cmd.none, NoOutMsg )

        DefaultUnitChanged value ->
            ( { form | defaultUnit = value, defaultUnitOpen = False, error = Nothing }
            , Cmd.none
            , NoOutMsg
            )

        ToggleDefaultUnitDropdown ->
            ( { form | defaultUnitOpen = not form.defaultUnitOpen, error = Nothing }
            , Cmd.none
            , NoOutMsg
            )

        NutrientsLoaded items ->
            let
                catalog : Dict String String
                catalog =
                    List.foldl
                        (\item acc -> Dict.insert item.code item.unit acc)
                        form.nutrientCatalog
                        items
            in
            ( { form | nutrientCatalog = catalog, error = Nothing }
            , Cmd.none
            , NoOutMsg
            )

        CategoryQueryChanged value ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput

                next : CategoryInput
                next =
                    { categoryInput
                        | query = value
                        , token = categoryInput.token + 1
                        , open = True
                    }

                trimmed : String
                trimmed =
                    String.trim value
            in
            ( { form | categoryInput = next, error = Nothing }
            , Cmd.none
            , if String.isEmpty trimmed then
                NoOutMsg

              else
                RequestCategorySuggestions next.token (categorySuggestionsRequest trimmed)
            )

        AddCategory value ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput
            in
            ( { form
                | categoryInput =
                    { categoryInput
                        | selected = addCategoryTag value categoryInput.selected
                        , query = ""
                        , suggestions = []
                        , open = False
                    }
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        RemoveCategory value ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput
            in
            ( { form
                | categoryInput =
                    { categoryInput
                        | selected = List.filter ((/=) value) categoryInput.selected
                    }
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        AcceptCategorySuggestion value ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput
            in
            ( { form
                | categoryInput =
                    { categoryInput
                        | selected = addCategoryTag value categoryInput.selected
                        , query = ""
                        , suggestions = []
                        , open = False
                    }
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        CategorySuggestionsLoaded token result ->
            if token /= form.categoryInput.token then
                ( form, Cmd.none, NoOutMsg )

            else
                case result of
                    Ok items ->
                        let
                            categoryInput : CategoryInput
                            categoryInput =
                                form.categoryInput
                        in
                        ( { form
                            | categoryInput = { categoryInput | suggestions = items, open = True }
                            , error = Nothing
                          }
                        , Cmd.none
                        , NoOutMsg
                        )

                    Err _ ->
                        ( { form | error = Nothing }, Cmd.none, NoOutMsg )

        NutrientCodeChanged index value ->
            let
                unit : String
                unit =
                    Dict.get value form.nutrientCatalog
                        |> Maybe.withDefault ""
            in
            ( { form
                | nutrients =
                    ListExtra.updateAt
                        index
                        (\row -> { row | code = value, codeOpen = False, unit = unit })
                        form.nutrients
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleNutrientCodeDropdown index ->
            ( { form
                | nutrients =
                    ListExtra.updateAt
                        index
                        (\row -> { row | codeOpen = not row.codeOpen })
                        form.nutrients
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        NutrientAmountChanged index value ->
            ( { form
                | nutrients =
                    ListExtra.updateAt
                        index
                        (\row -> { row | amountPer100g = value })
                        form.nutrients
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        AddNutrientRow ->
            ( { form
                | nutrients = form.nutrients ++ [ emptyNutrientRow ]
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        RemoveNutrientRow index ->
            ( { form
                | nutrients =
                    if List.length form.nutrients <= 1 then
                        form.nutrients

                    else
                        ListExtra.removeAt index form.nutrients
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ServingLabelChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | label = value })
                        form.servings
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ServingQuantityChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | quantity = value })
                        form.servings
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ServingUnitChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | unit = value, unitOpen = False })
                        form.servings
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleServingUnitDropdown index ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | unitOpen = not row.unitOpen })
                        form.servings
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        ServingGramsChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | grams = value })
                        form.servings
                , error = Nothing
              }
            , Cmd.none
            , NoOutMsg
            )

        AddServingRow ->
            ( { form | servings = form.servings ++ [ emptyServingRow ], error = Nothing }
            , Cmd.none
            , NoOutMsg
            )

        RemoveServingRow index ->
            ( { form | servings = ListExtra.removeAt index form.servings, error = Nothing }
            , Cmd.none
            , NoOutMsg
            )


addCategoryTag : String -> List String -> List String
addCategoryTag raw selected =
    case Text.blankToMaybe (String.toLower raw) of
        Just tag ->
            if List.member tag selected then
                selected

            else
                selected ++ [ tag ]

        Nothing ->
            selected


view : Device -> List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view _ nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ Ui.maybeErrorBanner form.error
        , basicInfoCard form
        , portionInfoCard form units
        , nutrientsCard form nutrients
        , servingsCard form units
        ]


basicInfoCard : FormModel -> Element Msg
basicInfoCard form =
    Ui.formSection "Basic Info"
        [ Ui.input "Name" form.name NameChanged
        , Ui.input "Brand" form.brand BrandChanged
        , categoryInputView form.categoryInput
        ]


portionInfoCard : FormModel -> List UnitItem -> Element Msg
portionInfoCard form units =
    Ui.formSection "Portion Info"
        [ Ui.input "Serving Size (g)" form.servingSizeG ServingSizeChanged
        , View.QuantityInput.dropdown
            { amountLabel = "Default Quantity"
            , amount = form.defaultQuantity
            , onAmountChange = DefaultQuantityChanged
            , unitLabel = "Default Unit"
            , unit = form.defaultUnit
            , units = units
            , onUnitChange = DefaultUnitChanged
            , unitOpen = form.defaultUnitOpen
            , onUnitToggle = ToggleDefaultUnitDropdown
            }
        ]


nutrientsCard : FormModel -> List NutrientItem -> Element Msg
nutrientsCard form nutrients =
    Ui.formSection "Nutrients (per 100g)"
        [ addRowHint
        , Element.column
            [ Element.width Element.fill
            , Element.spacing Ui.space12
            ]
            (List.indexedMap (nutrientRowView nutrients) form.nutrients
                ++ [ Ui.hairline
                   , Ui.ghostButton "+ Add Nutrient" AddNutrientRow
                   ]
            )
        ]


servingsCard : FormModel -> List UnitItem -> Element Msg
servingsCard form units =
    Ui.formSection "Servings"
        [ Element.column
            [ Element.width Element.fill
            , Element.spacing Ui.space12
            ]
            (if List.isEmpty form.servings then
                [ Ui.mutedParagraph
                    "Add a serving to define portions in cups, pieces, or other units."
                ]

             else
                List.indexedMap (servingRowView units) form.servings
            )
        , Ui.ghostButton "+ Add Serving" AddServingRow
        ]


categoryInputView : CategoryInput -> Element Msg
categoryInputView input =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space8 ]
        [ Element.el [ Ui.caption, Font.medium, Font.color Ui.darkColor ]
            (Element.text "Categories")
        , Element.el
            [ Ui.caption
            , Font.color Ui.mutedColor
            ]
            (Element.text "Type and press Enter (or click Add) to tag this food.")
        , Ui.input "" input.query CategoryQueryChanged
        , suggestionRowView input
        , addCategoryButton input
        , chipRowView input.selected
        ]


addCategoryButton : CategoryInput -> Element Msg
addCategoryButton input =
    Ui.ghostButton "Add" (AddCategory input.query)


chipRowView : List String -> Element Msg
chipRowView tags =
    if List.isEmpty tags then
        Element.el
            [ Ui.caption
            , Font.color Ui.mutedColor
            ]
            (Element.text "No categories yet")

    else
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.spacing 6
            ]
            (List.map chipView tags)


chipView : String -> Element Msg
chipView tag =
    Element.row
        [ Background.color (Ui.chipBackground True)
        , Font.color (Ui.chipForeground True)
        , Border.rounded 999
        , Element.paddingEach { top = 4, right = 4, bottom = 4, left = 10 }
        , Element.spacing 6
        , Ui.caption
        , Font.medium
        ]
        [ Element.text tag
        , Input.button
            [ Element.width (Element.px 18)
            , Element.height (Element.px 18)
            , Border.rounded 999
            , Background.color (Ui.chipBackground True)
            , Font.center
            , Font.bold
            ]
            { onPress = Just (RemoveCategory tag)
            , label = Element.text "×"
            }
        ]


suggestionRowView : CategoryInput -> Element Msg
suggestionRowView input =
    let
        open_ : Bool
        open_ =
            input.open && not (List.isEmpty input.suggestions)

        trimmed : String
        trimmed =
            String.trim input.query

        matching : List CategorySuggestion
        matching =
            input.suggestions
                |> List.filter
                    (\s ->
                        not (List.member s.value input.selected)
                            && (String.isEmpty trimmed
                                    || String.contains (String.toLower trimmed) s.value
                               )
                    )
    in
    if not open_ then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.spacing Ui.space4
            , Border.rounded 12
            , Background.color Ui.cardBg
            , Border.width 1
            , Border.color Ui.borderGray
            , Element.padding Ui.space8
            ]
            (List.map suggestionPill matching)


suggestionPill : CategorySuggestion -> Element Msg
suggestionPill s =
    Input.button
        [ Element.padding Ui.space4
        , Element.width Element.fill
        ]
        { onPress = Just (AcceptCategorySuggestion s.value)
        , label =
            Element.row
                [ Element.width Element.fill
                , Element.spacing Ui.space8
                , Element.paddingEach { top = 4, right = 8, bottom = 4, left = 8 }
                ]
                [ Element.el [ Ui.caption, Font.medium ] (Element.text s.value)
                , Element.el
                    [ Ui.caption
                    , Font.color Ui.mutedColor
                    , Element.alignRight
                    ]
                    (Element.text (String.fromInt s.count ++ " uses"))
                ]
        }


nutrientRowView : List NutrientItem -> Int -> NutrientRow -> Element Msg
nutrientRowView nutrients index row =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 6
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space8
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.selectDropdown
                    { label = "Nutrient"
                    , selected = row.code
                    , options =
                        ( "", "Select nutrient..." )
                            :: List.map (\n -> ( n.code, n.name )) nutrients
                    , onChange = NutrientCodeChanged index
                    , isOpen = row.codeOpen
                    , onToggle = ToggleNutrientCodeDropdown index
                    }
                )
            , Ui.dangerIconButton
                { label = "×"
                , title = "Remove"
                , onPress = RemoveNutrientRow index
                }
            ]
        , Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space8
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input "Amount" row.amountPer100g (NutrientAmountChanged index))
            , unitLabelView row.unit
            ]
        ]


{-| Read-only label that displays the unit a given nutrient uses. The label
column is always exactly 4 characters wide (left-padded with spaces) so the
form keeps a tidy vertical rhythm: empty rows show "none", "g" becomes "g ",
"mg" becomes "mg ", and "kcal" stays as "kcal".
-}
unitLabelView : String -> Element msg
unitLabelView unit =
    Element.el
        [ Element.width (Element.px unitLabelWidth)
        , Element.alignRight
        , Ui.caption
        , Font.color Ui.mutedColor
        ]
        (Element.text (padUnitLabel unit))


unitLabelWidth : Int
unitLabelWidth =
    32


padUnitLabel : String -> String
padUnitLabel unit =
    let
        display : String
        display =
            if String.isEmpty (String.trim unit) then
                "none"

            else
                unit
    in
    String.left unitLabelMax display
        |> String.padRight unitLabelMax ' '


unitLabelMax : Int
unitLabelMax =
    4


servingRowView : List UnitItem -> Int -> ServingRow -> Element Msg
servingRowView units index row =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 6
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space8
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input "Label" row.label (ServingLabelChanged index))
            , Ui.dangerIconButton
                { label = "×"
                , title = "Remove"
                , onPress = RemoveServingRow index
                }
            ]
        , Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space8
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input "Qty" row.quantity (ServingQuantityChanged index))
            , Element.el
                [ Element.width (Element.fill |> Element.maximum 160) ]
                (Ui.selectDropdown
                    { label = "Unit"
                    , selected = row.unit
                    , options = unitOptions row.unit units
                    , onChange = ServingUnitChanged index
                    , isOpen = row.unitOpen
                    , onToggle = ToggleServingUnitDropdown index
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Ui.input "Grams" row.grams (ServingGramsChanged index))
            ]
        ]


unitOptions : String -> List UnitItem -> List ( String, String )
unitOptions selected units =
    View.QuantityInput.unitOptions selected units


addRowHint : Element msg
addRowHint =
    Element.el
        [ Ui.caption
        , Font.color Ui.mutedColor
        ]
        (Element.text "Enter calories and macros to save.")
