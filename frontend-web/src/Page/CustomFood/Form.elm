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
    , applyAiDraft
    , emptyForm
    , fromProductDetail
    , hasManualInput
    , isSubmitting
    , toCreateFoodRequest
    , unitGhostText
    , update
    , view
    , withNutrientCatalog
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
import Data.FoodAssistant exposing (FoodDraft)
import Dict exposing (Dict)
import Element exposing (Device, Element)
import Lib.ListExtra as ListExtra
import Lib.Number as Number
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.QuantityInput



-- MODEL


type alias FormModel =
    { name : String
    , brand : String
    , categoryInput : CategoryInput
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
    , token : Ticket
    }


type alias NutrientRow =
    { code : String
    , amountPer100g : String
    , unit : String
    }


type alias ServingRow =
    { unit : String
    , gramsPerUnit : String
    }


type ValidationError
    = NameRequired
    | InvalidNutrientAmount String
    | InvalidServingGrams String
    | DuplicateServingUnit String
    | InvalidDefaultPortion


type OutMsg
    = NoOutMsg
    | RequestCategorySuggestions Ticket CategorySuggestionRequest


emptyForm : FormModel
emptyForm =
    { name = ""
    , brand = ""
    , categoryInput = emptyCategoryInput
    , defaultQuantity = ""
    , defaultUnit = ""
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
    , token = Ticket.initial
    }


emptyNutrientRow : NutrientRow
emptyNutrientRow =
    { code = ""
    , amountPer100g = ""
    , unit = ""
    }


emptyServingRow : ServingRow
emptyServingRow =
    { unit = "", gramsPerUnit = "" }


noDefaultOption : String
noDefaultOption =
    "__no_default__"


applyAiDraft : FoodDraft -> FormModel -> FormModel
applyAiDraft draft form =
    let
        categoryInput : CategoryInput
        categoryInput =
            form.categoryInput
    in
    { form
        | name = draft.name
        , brand = Maybe.withDefault "" draft.brand
        , categoryInput =
            { categoryInput
                | selected = List.map String.toLower draft.categories
                , query = ""
                , suggestions = []
            }
        , defaultQuantity = Maybe.withDefault "" draft.defaultQuantity
        , defaultUnit = Maybe.withDefault "" draft.defaultUnit
        , nutrients =
            List.map
                (\nutrient ->
                    { code = nutrient.code
                    , amountPer100g = nutrient.amountPer100g
                    , unit =
                        Dict.get nutrient.code form.nutrientCatalog
                            |> Maybe.withDefault ""
                    }
                )
                draft.nutrients
        , servings =
            List.map
                (\serving ->
                    { unit = serving.unit
                    , gramsPerUnit = serving.gramsPerUnit
                    }
                )
                draft.servings
        , submit = Idle
        , openDropdown = NoneOpen
    }


hasManualInput : FormModel -> Bool
hasManualInput form =
    List.any (not << String.isEmpty << String.trim)
        [ form.name
        , form.brand
        , form.categoryInput.query
        , form.defaultQuantity
        ]
        || not (List.isEmpty form.categoryInput.selected)
        || not (String.isEmpty (String.trim form.defaultUnit))
        || List.any
            (\row ->
                not (String.isEmpty (String.trim row.code))
                    || not (String.isEmpty (String.trim row.amountPer100g))
            )
            form.nutrients
        || List.any
            (\row ->
                not (String.isEmpty (String.trim row.gramsPerUnit))
                    || not (String.isEmpty (String.trim row.unit))
            )
            form.servings



-- UPDATE


type Msg
    = NameChanged String
    | BrandChanged String
    | DefaultQuantityChanged String
    | DefaultUnitChanged String
    | ToggleDefaultUnitDropdown
    | NutrientsLoaded (List NutrientItem)
    | CategoryQueryChanged String
    | AddCategory String
    | RemoveCategory String
    | AcceptCategorySuggestion String
    | CategorySuggestionsLoaded Ticket (Result Client.ApiError (List CategorySuggestion))
    | NutrientCodeChanged Int String
    | ToggleNutrientCodeDropdown Int
    | NutrientAmountChanged Int String
    | AddNutrientRow
    | RemoveNutrientRow Int
    | ServingUnitChanged Int String
    | ToggleServingUnitDropdown Int
    | ServingGramsPerUnitChanged Int String
    | AddServingRow
    | RemoveServingRow Int


fromProductDetail : ProductDetail -> FormModel
fromProductDetail food =
    { emptyForm
        | name = food.name
        , brand = Maybe.withDefault "" food.brand
        , categoryInput =
            { emptyCategoryInput | selected = List.map String.toLower food.categories }
        , defaultQuantity = Maybe.withDefault "" food.defaultQuantity
        , defaultUnit = Maybe.withDefault "" food.defaultUnit
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
                    { unit = s.unit
                    , gramsPerUnit = formatServingGrams s.gramsPerUnit
                    }
                )
                food.servings
    }


formatServingGrams : String -> String
formatServingGrams value =
    value
        |> String.toFloat
        |> Maybe.map (Number.toFixedTrimmed 3)
        |> Maybe.withDefault value


withNutrientCatalog : List NutrientItem -> FormModel -> FormModel
withNutrientCatalog items form =
    let
        catalog : Dict String String
        catalog =
            List.foldl
                (\item acc -> Dict.insert item.code item.unit acc)
                form.nutrientCatalog
                items
    in
    { form
        | nutrientCatalog = catalog
        , nutrients = backfillNutrientUnits catalog form.nutrients
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
                    |> ListExtra.combineErrors

            servingsResult : Result ValidationError (List Api.Foods.CreateFoodServingRequest)
            servingsResult =
                form.servings
                    |> List.filter hasServingInput
                    |> List.map toServingRequest
                    |> ListExtra.combineErrors
                    |> Result.andThen uniqueServingUnits

            defaultResult : Result ValidationError ( Maybe String, Maybe String )
            defaultResult =
                toDefaultPortion form
        in
        Result.map3
            (\nutrients servings ( defaultQuantity, defaultUnit ) ->
                { name = name
                , brand = Text.blankToMaybe form.brand
                , categories = form.categoryInput.selected
                , defaultQuantity = defaultQuantity
                , defaultUnit = defaultUnit
                , nutrients = nutrients
                , servings = servings
                }
            )
            nutrientsResult
            servingsResult
            defaultResult


uniqueServingUnits :
    List Api.Foods.CreateFoodServingRequest
    -> Result ValidationError (List Api.Foods.CreateFoodServingRequest)
uniqueServingUnits servings =
    case
        List.foldl
            (\serving ( seen, duplicate ) ->
                if List.member serving.unit seen then
                    ( seen, Just serving.unit )

                else
                    ( serving.unit :: seen, duplicate )
            )
            ( [], Nothing )
            servings
            |> Tuple.second
    of
        Just unit ->
            Err (DuplicateServingUnit unit)

        Nothing ->
            Ok servings


toDefaultPortion : FormModel -> Result ValidationError ( Maybe String, Maybe String )
toDefaultPortion form =
    case ( Text.blankToMaybe form.defaultQuantity, Text.blankToMaybe form.defaultUnit ) of
        ( Nothing, Nothing ) ->
            Ok ( Nothing, Nothing )

        ( Just quantity, Just "g" ) ->
            case String.toFloat quantity of
                Just value ->
                    if value > 0 then
                        Ok ( Just quantity, Just "g" )

                    else
                        Err InvalidDefaultPortion

                Nothing ->
                    Err InvalidDefaultPortion

        ( Just quantity, Just unit ) ->
            if
                (String.toFloat quantity
                    |> Maybe.map ((<) 0)
                    |> Maybe.withDefault False
                )
                    && List.any (\serving -> serving.unit == unit) form.servings
            then
                Ok ( Just quantity, Just unit )

            else
                Err InvalidDefaultPortion

        _ ->
            Err InvalidDefaultPortion


hasNutrientInput : NutrientRow -> Bool
hasNutrientInput row =
    not (String.isEmpty (String.trim row.code))
        && not (String.isEmpty (String.trim row.amountPer100g))


hasServingInput : ServingRow -> Bool
hasServingInput row =
    not (String.isEmpty (String.trim row.unit))
        && not (String.isEmpty (String.trim row.gramsPerUnit))


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
        gramsPerUnit : Result ValidationError Float
        gramsPerUnit =
            case String.toFloat (String.trim row.gramsPerUnit) of
                Just v ->
                    if v > 0 then
                        Ok v

                    else
                        Err (InvalidServingGrams row.gramsPerUnit)

                Nothing ->
                    Err (InvalidServingGrams row.gramsPerUnit)
    in
    Result.map
        (\value ->
            { unit = String.trim row.unit
            , gramsPerUnit = value
            }
        )
        gramsPerUnit


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

        DefaultQuantityChanged value ->
            ( if String.isEmpty form.defaultUnit then
                form

              else
                { form | defaultQuantity = value }
            , Cmd.none
            , NoOutMsg
            )

        DefaultUnitChanged value ->
            let
                selectedUnit : String
                selectedUnit =
                    if value == noDefaultOption then
                        ""

                    else
                        value

                quantity : String
                quantity =
                    if selectedUnit == "" then
                        ""

                    else if selectedUnit == "g" then
                        if form.defaultUnit == "g" && not (String.isEmpty form.defaultQuantity) then
                            form.defaultQuantity

                        else
                            "100"

                    else
                        "1"
            in
            ( { form
                | defaultUnit = selectedUnit
                , defaultQuantity = quantity
                , openDropdown = NoneOpen
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleDefaultUnitDropdown ->
            ( { form | openDropdown = toggleDropdown DefaultUnitOpen form.openDropdown }
            , Cmd.none
            , NoOutMsg
            )

        NutrientsLoaded items ->
            ( withNutrientCatalog items form
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
                        , token = Ticket.next categoryInput.token
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

        ServingUnitChanged index value ->
            let
                oldUnit : Maybe String
                oldUnit =
                    servingAt index form.servings |> Maybe.map .unit
            in
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | unit = value })
                        form.servings
                , openDropdown = NoneOpen
                , defaultUnit =
                    if oldUnit == Just form.defaultUnit then
                        value

                    else
                        form.defaultUnit
              }
            , Cmd.none
            , NoOutMsg
            )

        ToggleServingUnitDropdown index ->
            ( { form | openDropdown = toggleDropdown (ServingUnitOpen index) form.openDropdown }
            , Cmd.none
            , NoOutMsg
            )

        ServingGramsPerUnitChanged index value ->
            ( { form
                | servings =
                    ListExtra.updateAt
                        index
                        (\row -> { row | gramsPerUnit = value })
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
            let
                removesDefault : Bool
                removesDefault =
                    servingAt index form.servings
                        |> Maybe.map (\row -> row.unit == form.defaultUnit)
                        |> Maybe.withDefault False
            in
            ( { form
                | servings = ListExtra.removeAt index form.servings
                , defaultQuantity =
                    if removesDefault then
                        ""

                    else
                        form.defaultQuantity
                , defaultUnit =
                    if removesDefault then
                        ""

                    else
                        form.defaultUnit
              }
            , Cmd.none
            , NoOutMsg
            )


servingAt : Int -> List ServingRow -> Maybe ServingRow
servingAt index servings =
    servings |> List.drop index |> List.head


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



-- VIEW


view : Theme -> Device -> List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view theme device nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Ui.maybeErrorBanner theme (submitErrorMessage form.submit)
        , basicInfoCard theme device form
        , nutrientsCard theme device form nutrients
        , servingsCard theme device form units
        , defaultPortionCard theme device units form
        ]


basicInfoCard : Theme -> Device -> FormModel -> Element Msg
basicInfoCard theme device form =
    Ui.formSection theme
        "Basic Info"
        [ Ui.input theme { label = "Name", value = form.name, onChange = NameChanged }
        , Ui.input theme { label = "Brand", value = form.brand, onChange = BrandChanged }
        , categoryInputView theme device (form.openDropdown == CategoryOpen) form.categoryInput
        ]


defaultPortionCard : Theme -> Device -> List UnitItem -> FormModel -> Element Msg
defaultPortionCard theme device units form =
    Ui.formSection theme
        "Default Portion"
        [ defaultPortionFields theme device units form
        , Typography.mutedCaption theme
            (if form.defaultUnit == "" then
                if List.isEmpty form.servings then
                    "Optional. Food logging will start at 100 g."

                else
                    "Optional. Food logging will start with the first serving."

             else if form.defaultUnit == "g" then
                "Enter the gram amount to prefill when logging this food."

             else
                "Enter how many of the selected serving to prefill."
            )
        ]


defaultPortionFields : Theme -> Device -> List UnitItem -> FormModel -> Element Msg
defaultPortionFields theme device units form =
    let
        unitSelector : Element Msg
        unitSelector =
            Ui.selectDropdown device
                theme
                { label = "Default Unit"
                , selected = form.defaultUnit
                , options = defaultPortionOptions units form
                , onChange = DefaultUnitChanged
                , isOpen = form.openDropdown == DefaultUnitOpen
                , onToggle = ToggleDefaultUnitDropdown
                }

        quantityInput : Element Msg
        quantityInput =
            if String.isEmpty form.defaultUnit then
                Element.none

            else
                Ui.decimalInput theme
                    { label = "Default Quantity"
                    , value = form.defaultQuantity
                    , onChange = DefaultQuantityChanged
                    }

        attributes : List (Element.Attribute Msg)
        attributes =
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
    in
    if Ui.isSmall device then
        Element.column attributes [ unitSelector, quantityInput ]

    else
        Element.row attributes [ unitSelector, quantityInput ]


defaultPortionOptions : List UnitItem -> FormModel -> List ( String, String )
defaultPortionOptions units form =
    ( noDefaultOption, "No default" )
        :: ( "g", "Grams" )
        :: List.map
            (\serving ->
                ( serving.unit
                , servingUnitLabel units serving.unit
                )
            )
            (List.filter hasServingInput form.servings)


servingUnitLabel : List UnitItem -> String -> String
servingUnitLabel units code =
    case List.filter (\unit -> unit.code == code) units |> List.head of
        Just unit ->
            if unit.name == unit.code then
                unit.code

            else
                unit.name ++ " (" ++ unit.code ++ ")"

        Nothing ->
            code


nutrientsCard : Theme -> Device -> FormModel -> List NutrientItem -> Element Msg
nutrientsCard theme device form nutrients =
    Ui.section theme
        { header =
            Just
                (Element.column [ Element.spacing DesignTokens.space8 ]
                    [ Typography.subsectionTitle theme "Nutrients", addRowHint theme ]
                )
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                (List.indexedMap
                    (nutrientRowView theme device nutrients form.openDropdown)
                    form.nutrients
                )
            ]
        , footer = Just (Ui.fullWidthGhostButton device theme "+ Add Nutrient" AddNutrientRow)
        }


servingsCard : Theme -> Device -> FormModel -> List UnitItem -> Element Msg
servingsCard theme device form units =
    Ui.section theme
        { header = Just (Typography.subsectionTitle theme "Servings")
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space12
                ]
                (if List.isEmpty form.servings then
                    [ Typography.mutedParagraph theme
                        "Add a serving to define portions in cups, pieces, or other units."
                    ]

                 else
                    List.indexedMap
                        (servingRowView theme device units form.openDropdown)
                        form.servings
                )
            ]
        , footer = Just (Ui.fullWidthGhostButton device theme "+ Add Serving" AddServingRow)
        }


categoryInputView : Theme -> Device -> Bool -> CategoryInput -> Element Msg
categoryInputView theme device open input =
    Element.column [ Element.width Element.fill ]
        [ Element.row [ Element.spacing DesignTokens.space4 ]
            [ Ui.fieldLabel theme "Categories"
            , Typography.mutedCaption theme "Enter (or click Add) to tag this food."
            ]
        , Element.row [ Element.width Element.fill ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.input theme
                    { label = ""
                    , value = input.query
                    , onChange = CategoryQueryChanged
                    }
                )
            , Element.el
                [ Element.paddingEach
                    { top = DesignTokens.space4, left = DesignTokens.space4, bottom = 0, right = 0 }
                ]
                (addCategoryButton theme device input)
            ]
        , suggestionRowView theme open input
        , chipRowView theme device input.selected
        ]


addCategoryButton : Theme -> Device -> CategoryInput -> Element Msg
addCategoryButton theme device input =
    Ui.iconButton device
        theme
        { icon = Icon.Plus, title = "Add category", onPress = AddCategory input.query }


chipRowView : Theme -> Device -> List String -> Element Msg
chipRowView theme device tags =
    if List.isEmpty tags then
        Typography.mutedCaption theme "No categories yet"

    else
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.paddingXY 0 DesignTokens.space4
            , Element.spacing DesignTokens.space8
            ]
            (List.map (chipView theme device) tags)


chipView : Theme -> Device -> String -> Element Msg
chipView theme device tag =
    Ui.removableChip device
        theme
        { label = tag
        , onRemove = RemoveCategory tag
        }


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
        Ui.suggestionList theme (List.map (suggestionRow theme) matching)


suggestionRow : Theme -> CategorySuggestion -> Element Msg
suggestionRow theme s =
    Ui.optionRow theme
        { label = s.value
        , trailing = Just (Typography.mutedCaption theme (String.fromInt s.count ++ " uses"))
        , selected = False
        , onPress = AcceptCategorySuggestion s.value
        }


nutrientRowView :
    Theme
    -> Device
    -> List NutrientItem
    -> OpenDropdown
    -> Int
    -> NutrientRow
    -> Element Msg
nutrientRowView theme device nutrients openDropdown index row =
    let
        selector : Element Msg
        selector =
            Ui.selectDropdown device
                theme
                { label = "Nutrient"
                , selected = row.code
                , options =
                    ( "", "Select nutrient..." )
                        :: List.map (\n -> ( n.code, n.name )) nutrients
                , onChange = NutrientCodeChanged index
                , isOpen = openDropdown == NutrientCodeOpen index
                , onToggle = ToggleNutrientCodeDropdown index
                }

        removeButton : Element Msg
        removeButton =
            rowActionButton theme
                device
                { icon = Icon.Close
                , title = "Remove"
                , onPress = RemoveNutrientRow index
                }
    in
    if Ui.isSmall device then
        Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ selector
            , Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ amountInputWithUnit theme index row
                , removeButton
                ]
            ]

    else
        Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ selector
            , amountInputWithUnit theme index row
            , removeButton
            ]


amountInputWithUnit : Theme -> Int -> NutrientRow -> Element Msg
amountInputWithUnit theme index row =
    Ui.decimalInputWithSuffix theme
        { label = "Amount"
        , text = row.amountPer100g
        , suffix = unitGhostText row.unit
        , onChange = NutrientAmountChanged index
        }


{-| Muted unit text shown inside the amount input. Empty units fall back to a
neutral placeholder so the field still communicates that the suffix depends on
the selected nutrient.
-}
unitGhostText : String -> String
unitGhostText unit =
    if String.isEmpty (String.trim unit) then
        "unit"

    else
        unit


servingRowView :
    Theme
    -> Device
    -> List UnitItem
    -> OpenDropdown
    -> Int
    -> ServingRow
    -> Element Msg
servingRowView theme device units openDropdown index row =
    let
        selector : Element Msg
        selector =
            Ui.selectDropdown device
                theme
                { label = "Unit"
                , selected = row.unit
                , options = View.QuantityInput.unitOptions row.unit units
                , onChange = ServingUnitChanged index
                , isOpen = openDropdown == ServingUnitOpen index
                , onToggle = ToggleServingUnitDropdown index
                }

        gramsInput : Element Msg
        gramsInput =
            Ui.decimalInputWithSuffix theme
                { label = "Grams per unit"
                , text = row.gramsPerUnit
                , suffix = "g"
                , onChange = ServingGramsPerUnitChanged index
                }

        removeButton : Element Msg
        removeButton =
            rowActionButton theme
                device
                { icon = Icon.Close
                , title = "Remove"
                , onPress = RemoveServingRow index
                }
    in
    if Ui.isSmall device then
        Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ selector
            , Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ gramsInput, removeButton ]
            ]

    else
        Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ selector, gramsInput, removeButton ]


rowActionButton :
    Theme
    -> Device
    -> { icon : Icon, title : String, onPress : msg }
    -> Element msg
rowActionButton theme device config =
    Element.el
        [ Element.width (Element.px 44)
        , Element.paddingEach { top = DesignTokens.space16, right = 0, bottom = 0, left = 0 }
        ]
        (Ui.dangerIconButton device theme config)


addRowHint : Theme -> Element msg
addRowHint theme =
    Typography.mutedCaption theme "Enter calories and macros (per 100g) to save."
