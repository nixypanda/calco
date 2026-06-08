module Page.CustomFood.Form exposing
    ( CategoryInput
    , FormModel
    , Msg(..)
    , NutrientRow
    , OpenDropdown
    , OutMsg(..)
    , ServingRow
    , SubmitState(..)
    , ValidationError(..)
    , addCategoryTag
    , emptyForm
    , fromProductDetail
    , isSubmitting
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
import Ui.Theme exposing (Theme)
import View.QuantityInput


type alias FormModel =
    { name : String
    , brand : String
    , categoryInput : CategoryInput
    , servingSizeG : String
    , defaultQuantity : String
    , defaultUnit : String
    , nutrientCatalog : Dict String String
    , nutrients : List NutrientRow
    , servings : List ServingRow
    , submit : SubmitState
    , openDropdown : OpenDropdown
    }


type OpenDropdown
    = NoneOpen
    | CategoryOpen
    | DefaultUnitOpen
    | NutrientCodeOpen Int
    | ServingUnitOpen Int


type SubmitState
    = Idle
    | Submitting
    | SubmitFailed String


isSubmitting : SubmitState -> Bool
isSubmitting state =
    case state of
        Submitting ->
            True

        _ ->
            False


submitErrorMessage : SubmitState -> Maybe String
submitErrorMessage state =
    case state of
        SubmitFailed message ->
            Just message

        _ ->
            Nothing


type alias CategoryInput =
    { selected : List String
    , query : String
    , suggestions : List CategorySuggestion
    , token : Int
    }


type alias NutrientRow =
    { code : String
    , amountPer100g : String
    , unit : String
    }


type alias ServingRow =
    { label : String
    , quantity : String
    , unit : String
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
    , nutrientCatalog = Dict.empty
    , nutrients = [ emptyNutrientRow ]
    , servings = []
    , submit = Idle
    , openDropdown = NoneOpen
    }


emptyCategoryInput : CategoryInput
emptyCategoryInput =
    { selected = []
    , query = ""
    , suggestions = []
    , token = 0
    }


emptyNutrientRow : NutrientRow
emptyNutrientRow =
    { code = ""
    , amountPer100g = ""
    , unit = ""
    }


emptyServingRow : ServingRow
emptyServingRow =
    { label = "", quantity = "", unit = defaultCode, grams = "" }


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


clearSubmitError : FormModel -> FormModel
clearSubmitError form =
    case form.submit of
        SubmitFailed _ ->
            { form | submit = Idle }

        _ ->
            form


toggleDropdown : OpenDropdown -> OpenDropdown -> OpenDropdown
toggleDropdown target current =
    if current == target then
        NoneOpen

    else
        target


update : Msg -> FormModel -> ( FormModel, Cmd Msg, OutMsg )
update msg formIn =
    let
        form : FormModel
        form =
            clearSubmitError formIn
    in
    case msg of
        NameChanged value ->
            ( { form | name = value }, Cmd.none, NoOutMsg )

        BrandChanged value ->
            ( { form | brand = value }, Cmd.none, NoOutMsg )

        ServingSizeChanged value ->
            ( { form | servingSizeG = value }, Cmd.none, NoOutMsg )

        DefaultQuantityChanged value ->
            ( { form | defaultQuantity = value }, Cmd.none, NoOutMsg )

        DefaultUnitChanged value ->
            ( { form | defaultUnit = value, openDropdown = NoneOpen }
            , Cmd.none
            , NoOutMsg
            )

        ToggleDefaultUnitDropdown ->
            ( { form | openDropdown = toggleDropdown DefaultUnitOpen form.openDropdown }
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
            ( { form
                | nutrientCatalog = catalog
                , nutrients = backfillNutrientUnits catalog form.nutrients
              }
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
                    }

                trimmed : String
                trimmed =
                    String.trim value
            in
            ( { form | categoryInput = next, openDropdown = CategoryOpen }
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
                    }
                , openDropdown = NoneOpen
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
                    }
                , openDropdown = NoneOpen
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
                            | categoryInput = { categoryInput | suggestions = items }
                            , openDropdown = CategoryOpen
                          }
                        , Cmd.none
                        , NoOutMsg
                        )

                    Err _ ->
                        ( form, Cmd.none, NoOutMsg )

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
                        (\row -> { row | code = value, unit = unit })
                        form.nutrients
                , openDropdown = NoneOpen
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleNutrientCodeDropdown index ->
            ( { form | openDropdown = toggleDropdown (NutrientCodeOpen index) form.openDropdown }
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
              }
            , Cmd.none
            , NoOutMsg
            )

        AddNutrientRow ->
            ( { form
                | nutrients = form.nutrients ++ [ emptyNutrientRow ]
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
              }
            , Cmd.none
            , NoOutMsg
            )

        ServingUnitChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | unit = value })
                        form.servings
                , openDropdown = NoneOpen
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleServingUnitDropdown index ->
            ( { form | openDropdown = toggleDropdown (ServingUnitOpen index) form.openDropdown }
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
              }
            , Cmd.none
            , NoOutMsg
            )

        AddServingRow ->
            ( { form | servings = form.servings ++ [ emptyServingRow ] }
            , Cmd.none
            , NoOutMsg
            )

        RemoveServingRow index ->
            ( { form | servings = ListExtra.removeAt index form.servings }
            , Cmd.none
            , NoOutMsg
            )


backfillNutrientUnits : Dict String String -> List NutrientRow -> List NutrientRow
backfillNutrientUnits catalog rows =
    List.map (backfillNutrientUnit catalog) rows


backfillNutrientUnit : Dict String String -> NutrientRow -> NutrientRow
backfillNutrientUnit catalog row =
    if String.isEmpty (String.trim row.unit) then
        Dict.get row.code catalog
            |> Maybe.map (\unit -> { row | unit = unit })
            |> Maybe.withDefault row

    else
        row


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


view : Theme -> Device -> List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view theme _ nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ Ui.maybeErrorBanner theme (submitErrorMessage form.submit)
        , basicInfoCard theme form
        , portionInfoCard theme form units
        , nutrientsCard theme form nutrients
        , servingsCard theme form units
        ]


basicInfoCard : Theme -> FormModel -> Element Msg
basicInfoCard theme form =
    Ui.formSection theme
        "Basic Info"
        [ Ui.input theme { label = "Name", value = form.name, onChange = NameChanged }
        , Ui.input theme { label = "Brand", value = form.brand, onChange = BrandChanged }
        , categoryInputView theme (form.openDropdown == CategoryOpen) form.categoryInput
        ]


portionInfoCard : Theme -> FormModel -> List UnitItem -> Element Msg
portionInfoCard theme form units =
    Ui.formSection theme
        "Portion Info"
        [ Ui.input theme { label = "Serving Size (g)", value = form.servingSizeG, onChange = ServingSizeChanged }
        , View.QuantityInput.dropdown theme
            { amountLabel = "Default Quantity"
            , amount = form.defaultQuantity
            , onAmountChange = DefaultQuantityChanged
            , unitLabel = "Default Unit"
            , unit = form.defaultUnit
            , units = units
            , onUnitChange = DefaultUnitChanged
            , unitOpen = form.openDropdown == DefaultUnitOpen
            , onUnitToggle = ToggleDefaultUnitDropdown
            }
        ]


nutrientsCard : Theme -> FormModel -> List NutrientItem -> Element Msg
nutrientsCard theme form nutrients =
    Ui.section theme
        { header =
            Just
                (Element.column [ Element.spacing Ui.space8 ]
                    [ Ui.subsectionTitle theme "Nutrients", addRowHint theme ]
                )
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing Ui.space8
                ]
                (List.indexedMap (nutrientRowView theme nutrients form.openDropdown) form.nutrients
                    ++ [ Ui.hairline theme
                       , Ui.ghostButton theme "+ Add Nutrient" AddNutrientRow
                       ]
                )
            ]
        , footer = Nothing
        }


servingsCard : Theme -> FormModel -> List UnitItem -> Element Msg
servingsCard theme form units =
    Ui.section theme
        { header = Just (Ui.subsectionTitle theme "Servings")
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing Ui.space12
                ]
                (if List.isEmpty form.servings then
                    [ Ui.mutedParagraph theme
                        "Add a serving to define portions in cups, pieces, or other units."
                    ]

                 else
                    List.indexedMap (servingRowView theme units form.openDropdown) form.servings
                )
            ]
        , footer = Just (Ui.ghostButton theme "+ Add Serving" AddServingRow)
        }


categoryInputView : Theme -> Bool -> CategoryInput -> Element Msg
categoryInputView theme open input =
    Element.column [ Element.width Element.fill ]
        [ Element.row [ Element.spacing Ui.space4 ]
            [ Ui.fieldLabel theme "Categories"
            , Ui.mutedCaption theme "Type and press Enter (or click Add) to tag this food."
            ]
        , Element.row [ Element.width Element.fill ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input theme { label = "", value = input.query, onChange = CategoryQueryChanged })
            , Element.el
                [ Element.paddingEach
                    { top = Ui.space4, left = Ui.space4, bottom = 0, right = 0 }
                ]
                (addCategoryButton theme input)
            ]
        , suggestionRowView theme open input
        , chipRowView theme input.selected
        ]


addCategoryButton : Theme -> CategoryInput -> Element Msg
addCategoryButton theme input =
    Ui.iconButton theme { label = "+", title = "Edit", onPress = AddCategory input.query }


chipRowView : Theme -> List String -> Element Msg
chipRowView theme tags =
    if List.isEmpty tags then
        Ui.mutedCaption theme "No categories yet"

    else
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.paddingXY 0 Ui.space4
            , Element.spacing 6
            ]
            (List.map (chipView theme) tags)


chipView : Theme -> String -> Element Msg
chipView theme tag =
    Element.row
        [ Background.color (Ui.chipBackground theme False)
        , Font.color (Ui.chipForeground theme False)
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
            , Background.color theme.cardBg
            , Font.color theme.dangerFg
            , Font.center
            , Border.rounded 999
            , Border.width 1
            , Border.color theme.dangerFg
            , Element.mouseOver
                [ Background.color theme.dangerSolid
                , Font.color (Element.rgb255 255 255 255)
                , Border.color theme.dangerSolid
                ]
            ]
            { onPress = Just (RemoveCategory tag)
            , label = Element.text "×"
            }
        ]


suggestionRowView : Theme -> Bool -> CategoryInput -> Element Msg
suggestionRowView theme open input =
    let
        open_ : Bool
        open_ =
            open && not (List.isEmpty input.suggestions)

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
            , Background.color theme.cardBg
            , Border.width 1
            , Border.color theme.divider
            , Element.padding Ui.space8
            ]
            (List.map (suggestionPill theme) matching)


suggestionPill : Theme -> CategorySuggestion -> Element Msg
suggestionPill theme s =
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
                [ Ui.fieldLabel theme s.value
                , Element.el [ Element.alignRight ]
                    (Ui.mutedCaption theme (String.fromInt s.count ++ " uses"))
                ]
        }


nutrientRowView : Theme -> List NutrientItem -> OpenDropdown -> Int -> NutrientRow -> Element Msg
nutrientRowView theme nutrients openDropdown index row =
    Element.row
        [ Element.width Element.fill
        , Element.spacing Ui.space8
        ]
        [ Ui.selectDropdown theme
            { label = "Nutrient"
            , selected = row.code
            , options =
                ( "", "Select nutrient..." )
                    :: List.map (\n -> ( n.code, n.name )) nutrients
            , onChange = NutrientCodeChanged index
            , isOpen = openDropdown == NutrientCodeOpen index
            , onToggle = ToggleNutrientCodeDropdown index
            }
        , Ui.input theme { label = "Amount", value = row.amountPer100g, onChange = NutrientAmountChanged index }
        , unitLabelView theme row.unit
        , rowActionButton theme
            { label = "×"
            , title = "Remove"
            , onPress = RemoveNutrientRow index
            }
        ]


{-| Read-only label that displays the unit a given nutrient uses. The label
column is always exactly 4 characters wide (left-padded with spaces) so the
form keeps a tidy vertical rhythm: empty rows show "none", "g" becomes "g ",
"mg" becomes "mg ", and "kcal" stays as "kcal".
-}
unitLabelView : Theme -> String -> Element msg
unitLabelView theme unit =
    Element.el
        [ Element.width (Element.px unitLabelWidth)
        , Element.alignRight
        , Element.paddingEach { top = Ui.space16, left = 0, bottom = 0, right = Ui.space4 }
        ]
        (Ui.mutedCaption theme (padUnitLabel unit))


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


servingRowView : Theme -> List UnitItem -> OpenDropdown -> Int -> ServingRow -> Element Msg
servingRowView theme units openDropdown index row =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 6
        ]
        [ Ui.input theme { label = "Label", value = row.label, onChange = ServingLabelChanged index }
        , Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space8
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input theme { label = "Qty", value = row.quantity, onChange = ServingQuantityChanged index })
            , Element.el
                [ Element.width (Element.fill |> Element.maximum 160) ]
                (Ui.selectDropdown theme
                    { label = "Unit"
                    , selected = row.unit
                    , options = unitOptions row.unit units
                    , onChange = ServingUnitChanged index
                    , isOpen = openDropdown == ServingUnitOpen index
                    , onToggle = ToggleServingUnitDropdown index
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Ui.input theme { label = "Grams", value = row.grams, onChange = ServingGramsChanged index })
            , rowActionButton theme
                { label = "×"
                , title = "Remove"
                , onPress = RemoveServingRow index
                }
            ]
        ]


rowActionButton : Theme -> { label : String, title : String, onPress : msg } -> Element msg
rowActionButton theme config =
    Element.el
        [ Element.width (Element.px 40)
        , Element.paddingEach { top = 18, right = 0, bottom = 0, left = 0 }
        ]
        (Ui.dangerIconButton theme config)


unitOptions : String -> List UnitItem -> List ( String, String )
unitOptions selected units =
    View.QuantityInput.unitOptions selected units


addRowHint : Theme -> Element msg
addRowHint theme =
    Ui.mutedCaption theme "Enter calories and macros (per 100g) to save."



-- unusual-other-purpose-rural
