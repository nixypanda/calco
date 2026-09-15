module Component.FoodEditor exposing
    ( CategoryInput
    , Context(..)
    , FormModel
    , LogFields
    , LogPersistence(..)
    , Msg(..)
    , NutrientBasis(..)
    , NutrientRow
    , NutrientVisibility(..)
    , OpenDropdown
    , OutMsg(..)
    , PortionNutrition(..)
    , ServingRow
    , SubmitState(..)
    , ValidatedLog
    , ValidationError(..)
    , addCategoryTag
    , allowedLogUnitCodes
    , applyAiDraft
    , applyAiLogDraft
    , changeLogQuantity
    , changeLogUnit
    , emptyForm
    , emptyLogForm
    , foodLogFields
    , fromProductDetail
    , hasManualInput
    , isSubmitting
    , logPortionWeight
    , toAdHocLogRequest
    , toCreateFoodRequest
    , toCustomFoodFromLogRequest
    , toInitialCreateFoodRequest
    , toProductLogRequest
    , unitGhostText
    , update
    , validateLog
    , view
    , viewForCreate
    , viewForLog
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
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Data.FoodAssistant exposing (FoodDraft)
import Data.ItemRef exposing (ItemType(..))
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Dict exposing (Dict)
import Element exposing (Device, Element)
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.ListExtra as ListExtra
import Lib.Number as Number
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients
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
    , context : Context
    }


type Context
    = CustomFoodContext
    | FoodLogContext LogFields LogPersistence


type alias LogFields =
    { date : String
    , mealSlot : Maybe MealSlot
    , quantity : String
    , unit : String
    , notes : String
    , nutrition : PortionNutrition
    }


type PortionNutrition
    = IndependentPortion
    | DerivedPortion { weightGrams : String }


type LogPersistence
    = LogAdHocOnly
    | SaveCustomFoodThenLog { portionWeight : String }


type OpenDropdown
    = NoneOpen
    | CategoryOpen
    | DefaultUnitOpen
    | NutrientCodeOpen Int
    | ServingUnitOpen Int
    | LogUnitOpen
    | MealSlotOpen


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
    , amount : String
    , unit : String
    }


type NutrientBasis
    = Per100Grams
    | PerLoggedPortion


type NutrientVisibility
    = AllNutrients
    | CoreNutrientsOnly


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


type alias ValidatedLog =
    { date : LocalDate
    , mealSlot : Maybe MealSlot
    , quantity : Nutrition.Quantity
    , quantityAmount : Float
    , nutrients : List Nutrition.NutrientAmount
    , nutrientTotals : List ( String, Float )
    , notes : Maybe String
    , portionWeight : Maybe Float
    }


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
    , context = CustomFoodContext
    }


emptyLogForm : Maybe String -> Maybe MealSlot -> FormModel
emptyLogForm maybeDate maybeMealSlot =
    { emptyForm
        | nutrients =
            [ { code = "ENERGY_KCAL", amount = "", unit = "kcal" }
            , { code = "PROTEIN_G", amount = "", unit = "g" }
            , { code = "CARBS_G", amount = "", unit = "g" }
            , { code = "FAT_G", amount = "", unit = "g" }
            ]
        , context =
            FoodLogContext
                { date = Maybe.withDefault "" maybeDate
                , mealSlot = maybeMealSlot
                , quantity = "1"
                , unit = "serving"
                , notes = ""
                , nutrition = IndependentPortion
                }
                LogAdHocOnly
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
    , amount = ""
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
                    , amount = nutrient.amountPer100g
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


applyAiLogDraft :
    List NutrientItem
    -> FoodDraft
    -> Data.FoodAssistant.SuggestedLog
    -> FormModel
    -> Result String FormModel
applyAiLogDraft catalog draft suggested form =
    Result.map2
        (\_ rows ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput

                context : Context
                context =
                    case form.context of
                        FoodLogContext logFields persistence ->
                            FoodLogContext
                                { logFields
                                    | quantity = suggested.amount
                                    , unit = suggested.unit
                                    , nutrition =
                                        DerivedPortion
                                            { weightGrams = suggested.totalWeightGrams }
                                }
                                persistence

                        CustomFoodContext ->
                            CustomFoodContext
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
                , nutrients = rows
                , servings =
                    List.map
                        (\serving ->
                            { unit = serving.unit
                            , gramsPerUnit = serving.gramsPerUnit
                            }
                        )
                        draft.servings
                , context = context
            }
        )
        (positiveNumber "Suggested portion weight" suggested.totalWeightGrams)
        (draft.nutrients
            |> List.map (aiLogNutrientRow catalog suggested.totalWeightGrams)
            |> ListExtra.combineErrors
            |> Result.andThen requireCoreNutrients
        )


aiLogNutrientRow :
    List NutrientItem
    -> String
    -> Data.FoodAssistant.DraftNutrient
    -> Result String NutrientRow
aiLogNutrientRow catalog rawWeight nutrient =
    case List.filter (\item -> item.code == nutrient.code) catalog |> List.head of
        Nothing ->
            Err ("The estimate contains an unsupported nutrient: " ++ nutrient.code)

        Just item ->
            Result.map2
                (\weight amountPer100g ->
                    { code = nutrient.code
                    , amount = String.fromFloat (amountPer100g * weight / 100)
                    , unit = item.unit
                    }
                )
                (positiveNumber "Suggested portion weight" rawWeight)
                (nonNegativeNumber "Estimated nutrient" nutrient.amountPer100g)


requireCoreNutrients : List NutrientRow -> Result String (List NutrientRow)
requireCoreNutrients rows =
    case
        coreNutrientCodes
            |> List.filter (\code -> not (List.any (\row -> row.code == code) rows))
            |> List.head
    of
        Just _ ->
            Err "The estimate is missing calories or a required macronutrient."

        Nothing ->
            Ok rows


changeLogQuantity : String -> FormModel -> FormModel
changeLogQuantity rawQuantity form =
    case form.context of
        FoodLogContext logFields persistence ->
            case ( String.toFloat logFields.quantity, String.toFloat rawQuantity ) of
                ( Just oldQuantity, Just newQuantity ) ->
                    if oldQuantity > 0 && newQuantity > 0 then
                        scaleLogPortion (newQuantity / oldQuantity)
                            { form
                                | context =
                                    FoodLogContext
                                        { logFields | quantity = rawQuantity }
                                        persistence
                            }

                    else
                        { form
                            | context =
                                FoodLogContext
                                    { logFields | quantity = rawQuantity }
                                    persistence
                        }

                _ ->
                    { form
                        | context =
                            FoodLogContext { logFields | quantity = rawQuantity } persistence
                    }

        CustomFoodContext ->
            form


changeLogUnit : FoodDraft -> String -> FormModel -> FormModel
changeLogUnit draft unit form =
    case form.context of
        FoodLogContext logFields persistence ->
            case
                ( String.toFloat logFields.quantity
                , gramsPerLogUnit draft unit
                , effectivePortionWeight logFields persistence
                )
            of
                ( Just quantity, Just grams, Just oldWeight ) ->
                    let
                        changed : FormModel
                        changed =
                            { form
                                | context =
                                    FoodLogContext { logFields | unit = unit } persistence
                            }
                    in
                    if quantity > 0 && grams > 0 && oldWeight > 0 then
                        scaleLogPortion (quantity * grams / oldWeight) changed

                    else
                        changed

                _ ->
                    { form
                        | context = FoodLogContext { logFields | unit = unit } persistence
                    }

        CustomFoodContext ->
            form


scaleLogPortion : Float -> FormModel -> FormModel
scaleLogPortion ratio form =
    { form
        | nutrients =
            List.map
                (\row -> { row | amount = scaleNumberString ratio row.amount })
                form.nutrients
        , context =
            case form.context of
                FoodLogContext logFields persistence ->
                    FoodLogContext
                        { logFields
                            | nutrition = scalePortionNutrition ratio logFields.nutrition
                        }
                        (scalePersistenceWeight ratio persistence)

                other ->
                    other
    }


scaleNumberString : Float -> String -> String
scaleNumberString ratio raw =
    String.toFloat raw
        |> Maybe.map ((*) ratio >> String.fromFloat)
        |> Maybe.withDefault raw


effectivePortionWeight : LogFields -> LogPersistence -> Maybe Float
effectivePortionWeight logFields persistence =
    case logFields.nutrition of
        DerivedPortion details ->
            String.toFloat details.weightGrams

        IndependentPortion ->
            case persistence of
                SaveCustomFoodThenLog details ->
                    String.toFloat details.portionWeight

                LogAdHocOnly ->
                    Nothing


portionWeightFromNutrition : PortionNutrition -> String
portionWeightFromNutrition nutrition =
    case nutrition of
        DerivedPortion details ->
            details.weightGrams

        IndependentPortion ->
            ""


scalePortionNutrition : Float -> PortionNutrition -> PortionNutrition
scalePortionNutrition ratio nutrition =
    case nutrition of
        DerivedPortion details ->
            DerivedPortion
                { details | weightGrams = scaleNumberString ratio details.weightGrams }

        IndependentPortion ->
            IndependentPortion


scalePersistenceWeight : Float -> LogPersistence -> LogPersistence
scalePersistenceWeight ratio persistence =
    case persistence of
        SaveCustomFoodThenLog details ->
            SaveCustomFoodThenLog
                { details | portionWeight = scaleNumberString ratio details.portionWeight }

        LogAdHocOnly ->
            LogAdHocOnly


gramsPerLogUnit : FoodDraft -> String -> Maybe Float
gramsPerLogUnit draft unit =
    if unit == "g" then
        Just 1

    else
        draft.servings
            |> List.filter (\serving -> serving.unit == unit)
            |> List.head
            |> Maybe.andThen (.gramsPerUnit >> String.toFloat)


allowedLogUnitCodes : FoodDraft -> List String
allowedLogUnitCodes draft =
    "g" :: List.map .unit draft.servings


foodLogFields : FormModel -> Maybe LogFields
foodLogFields form =
    case form.context of
        FoodLogContext fields _ ->
            Just fields

        CustomFoodContext ->
            Nothing


logPortionWeight : FormModel -> Maybe String
logPortionWeight form =
    case form.context of
        FoodLogContext fields persistence ->
            case fields.nutrition of
                DerivedPortion details ->
                    Just details.weightGrams

                IndependentPortion ->
                    case persistence of
                        SaveCustomFoodThenLog details ->
                            Just details.portionWeight

                        LogAdHocOnly ->
                            Nothing

        CustomFoodContext ->
            Nothing


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
                    || not (String.isEmpty (String.trim row.amount))
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
    | LogQuantityChanged String
    | LogUnitChanged String
    | ToggleLogUnitDropdown
    | LogDateChanged String
    | LogMealSlotChanged (Maybe MealSlot)
    | ToggleMealSlotDropdown
    | LogNotesChanged String
    | LogPersistenceToggled
    | PortionWeightChanged String


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
                        , amount = n.amountPer100g
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


toInitialCreateFoodRequest : FormModel -> Result ValidationError CreateFoodRequest
toInitialCreateFoodRequest form =
    toCreateFoodRequest
        { form
            | defaultQuantity = ""
            , defaultUnit = ""
            , servings = []
        }


validateLog : FormModel -> Result String ValidatedLog
validateLog form =
    case form.context of
        CustomFoodContext ->
            Err "This editor is not configured for food logging."

        FoodLogContext logFields persistence ->
            let
                enteredRows : List NutrientRow
                enteredRows =
                    List.filter hasNutrientInput form.nutrients

                duplicate : Maybe String
                duplicate =
                    firstDuplicate (List.map (.code >> String.trim) enteredRows)

                missingRequired : Maybe String
                missingRequired =
                    coreNutrientCodes
                        |> List.filter
                            (\code -> not (List.any (\row -> row.code == code) enteredRows))
                        |> List.head

                parsedNutrients : Result String (List ( NutrientRow, Float ))
                parsedNutrients =
                    enteredRows
                        |> List.map
                            (\row ->
                                if String.isEmpty (String.trim row.code) then
                                    Err "Select a nutrient for every entered amount."

                                else
                                    nonNegativeNumber
                                        (View.Nutrients.nutrientLabel row.code)
                                        row.amount
                                        |> Result.map (Tuple.pair row)
                            )
                        |> ListExtra.combineErrors

                portionWeight : Result String (Maybe Float)
                portionWeight =
                    case persistence of
                        LogAdHocOnly ->
                            Ok Nothing

                        SaveCustomFoodThenLog details ->
                            positiveNumber "Weight of this logged portion" details.portionWeight
                                |> Result.map Just
            in
            case LocalDate.fromString logFields.date of
                Nothing ->
                    Err "Enter a valid date in YYYY-MM-DD format."

                Just date ->
                    if String.isEmpty (String.trim form.name) then
                        Err "Food name is required."

                    else if duplicate /= Nothing then
                        Err "Each nutrient can only be added once."

                    else
                        case missingRequired of
                            Just code ->
                                Err (View.Nutrients.nutrientLabel code ++ " is required.")

                            Nothing ->
                                Result.map3
                                    (\quantityAmount parsed weight ->
                                        { date = date
                                        , mealSlot = logFields.mealSlot
                                        , quantity =
                                            { amount = String.trim logFields.quantity
                                            , unit = String.trim logFields.unit
                                            }
                                        , quantityAmount = quantityAmount
                                        , nutrients =
                                            List.map
                                                (\( row, _ ) ->
                                                    { code = String.trim row.code
                                                    , amount = String.trim row.amount
                                                    , unit = row.unit
                                                    }
                                                )
                                                parsed
                                        , nutrientTotals =
                                            List.map
                                                (\( row, amount ) ->
                                                    ( String.trim row.code, amount )
                                                )
                                                parsed
                                        , notes = Text.blankToMaybe logFields.notes
                                        , portionWeight = weight
                                        }
                                    )
                                    (positiveNumber "Amount" logFields.quantity)
                                    parsedNutrients
                                    portionWeight


toAdHocLogRequest : Maybe String -> FormModel -> Result String CreateAdHocLogRequest
toAdHocLogRequest timezone form =
    validateLog form
        |> Result.map
            (\validated ->
                { logDate = validated.date
                , deviceTimezone = timezone
                , mealSlot = Maybe.map MealSlot.toString validated.mealSlot
                , name = String.trim form.name
                , brand = Text.blankToMaybe form.brand
                , quantity = validated.quantity
                , nutrients = validated.nutrients
                , notes = validated.notes
                }
            )


toCustomFoodFromLogRequest : FormModel -> Result String CreateFoodRequest
toCustomFoodFromLogRequest form =
    validateLog form
        |> Result.andThen
            (\validated ->
                case validated.portionWeight of
                    Nothing ->
                        Err "Weight of this logged portion is required."

                    Just weight ->
                        let
                            per100g : List Api.Foods.CreateFoodNutrientRequest
                            per100g =
                                List.map
                                    (\( code, amount ) ->
                                        { code = code, amountPer100g = amount * 100 / weight }
                                    )
                                    validated.nutrientTotals

                            gramsPerUnit : Float
                            gramsPerUnit =
                                weight / validated.quantityAmount

                            derivedServing : List Api.Foods.CreateFoodServingRequest
                            derivedServing =
                                if isMassUnit validated.quantity.unit then
                                    []

                                else
                                    [ { unit = validated.quantity.unit
                                      , gramsPerUnit = gramsPerUnit
                                      }
                                    ]

                            suppliedServings :
                                Result
                                    ValidationError
                                    (List Api.Foods.CreateFoodServingRequest)
                            suppliedServings =
                                form.servings
                                    |> List.filter hasServingInput
                                    |> List.map toServingRequest
                                    |> ListExtra.combineErrors
                                    |> Result.andThen uniqueServingUnits
                        in
                        if
                            not (List.all (.amountPer100g >> finite) per100g)
                                || not (finite gramsPerUnit)
                        then
                            Err "The portion values are too large to calculate safely."

                        else
                            suppliedServings
                                |> Result.mapError validationErrorMessage
                                |> Result.map
                                    (\servings ->
                                        { name = String.trim form.name
                                        , brand = Text.blankToMaybe form.brand
                                        , categories = form.categoryInput.selected
                                        , defaultQuantity = Just validated.quantity.amount
                                        , defaultUnit = Just validated.quantity.unit
                                        , nutrients = per100g
                                        , servings =
                                            if List.isEmpty servings then
                                                derivedServing

                                            else
                                                servings
                                        }
                                    )
            )


toProductLogRequest : Maybe String -> String -> FormModel -> Result String CreateLogRequest
toProductLogRequest timezone productId form =
    validateLog form
        |> Result.map
            (\validated ->
                { logDate = validated.date
                , deviceTimezone = timezone
                , mealSlot = Maybe.map MealSlot.toString validated.mealSlot
                , item = { itemType = Product, id = productId }
                , quantity = validated.quantity
                , notes = validated.notes
                }
            )


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
        && not (String.isEmpty (String.trim row.amount))


hasServingInput : ServingRow -> Bool
hasServingInput row =
    not (String.isEmpty (String.trim row.unit))
        && not (String.isEmpty (String.trim row.gramsPerUnit))


toNutrientRequest : NutrientRow -> Result ValidationError Api.Foods.CreateFoodNutrientRequest
toNutrientRequest row =
    case String.toFloat (String.trim row.amount) of
        Just amount ->
            if amount < 0 then
                Err (InvalidNutrientAmount row.amount)

            else
                Ok
                    { code = String.trim row.code
                    , amountPer100g = amount
                    }

        Nothing ->
            Err (InvalidNutrientAmount row.amount)


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
                        (\row -> { row | amount = value })
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

        LogQuantityChanged value ->
            ( mapLogFields (\logFields -> { logFields | quantity = value }) form
            , Cmd.none
            , NoOutMsg
            )

        LogUnitChanged value ->
            ( mapLogFields (\logFields -> { logFields | unit = value })
                { form | openDropdown = NoneOpen }
            , Cmd.none
            , NoOutMsg
            )

        ToggleLogUnitDropdown ->
            ( { form | openDropdown = toggleDropdown LogUnitOpen form.openDropdown }
            , Cmd.none
            , NoOutMsg
            )

        LogDateChanged value ->
            ( mapLogFields (\logFields -> { logFields | date = value }) form
            , Cmd.none
            , NoOutMsg
            )

        LogMealSlotChanged value ->
            ( mapLogFields (\logFields -> { logFields | mealSlot = value })
                { form | openDropdown = NoneOpen }
            , Cmd.none
            , NoOutMsg
            )

        ToggleMealSlotDropdown ->
            ( { form | openDropdown = toggleDropdown MealSlotOpen form.openDropdown }
            , Cmd.none
            , NoOutMsg
            )

        LogNotesChanged value ->
            ( mapLogFields (\logFields -> { logFields | notes = value }) form
            , Cmd.none
            , NoOutMsg
            )

        LogPersistenceToggled ->
            ( { form
                | context =
                    case form.context of
                        FoodLogContext logFields LogAdHocOnly ->
                            FoodLogContext logFields
                                (SaveCustomFoodThenLog
                                    { portionWeight =
                                        portionWeightFromNutrition logFields.nutrition
                                    }
                                )

                        FoodLogContext logFields (SaveCustomFoodThenLog _) ->
                            FoodLogContext logFields LogAdHocOnly

                        CustomFoodContext ->
                            CustomFoodContext
              }
            , Cmd.none
            , NoOutMsg
            )

        PortionWeightChanged value ->
            ( setPortionWeight value form
            , Cmd.none
            , NoOutMsg
            )


mapLogFields : (LogFields -> LogFields) -> FormModel -> FormModel
mapLogFields transform form =
    case form.context of
        FoodLogContext logFields persistence ->
            { form | context = FoodLogContext (transform logFields) persistence }

        CustomFoodContext ->
            form


setPortionWeight : String -> FormModel -> FormModel
setPortionWeight value form =
    case form.context of
        FoodLogContext logFields (SaveCustomFoodThenLog details) ->
            { form
                | context =
                    FoodLogContext
                        { logFields
                            | nutrition =
                                case logFields.nutrition of
                                    DerivedPortion _ ->
                                        DerivedPortion { weightGrams = value }

                                    IndependentPortion ->
                                        IndependentPortion
                        }
                        (SaveCustomFoodThenLog { details | portionWeight = value })
            }

        _ ->
            form


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


coreNutrientCodes : List String
coreNutrientCodes =
    [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]


positiveNumber : String -> String -> Result String Float
positiveNumber label raw =
    case String.toFloat (String.trim raw) of
        Just value ->
            if value > 0 && finite value then
                Ok value

            else
                Err (label ++ " must be greater than zero.")

        Nothing ->
            Err (label ++ " must be a number greater than zero.")


nonNegativeNumber : String -> String -> Result String Float
nonNegativeNumber label raw =
    case String.toFloat (String.trim raw) of
        Just value ->
            if value >= 0 && finite value then
                Ok value

            else
                Err (label ++ " must be zero or greater.")

        Nothing ->
            Err (label ++ " is required and must be a number.")


finite : Float -> Bool
finite value =
    not (isNaN value) && not (isInfinite value)


firstDuplicate : List String -> Maybe String
firstDuplicate values =
    values
        |> List.foldl
            (\value ( seen, duplicate ) ->
                if duplicate /= Nothing then
                    ( seen, duplicate )

                else if List.member value seen then
                    ( seen, Just value )

                else
                    ( value :: seen, Nothing )
            )
            ( [], Nothing )
        |> Tuple.second


isMassUnit : String -> Bool
isMassUnit raw =
    List.member (String.toLower (String.trim raw))
        [ "g", "gram", "grams", "kg", "kilogram", "kilograms", "mg" ]


validationErrorMessage : ValidationError -> String
validationErrorMessage error =
    case error of
        NameRequired ->
            "Name is required"

        InvalidNutrientAmount value ->
            "Nutrient amount must be a non-negative number (got: " ++ value ++ ")"

        InvalidServingGrams value ->
            "Grams per serving unit must be a positive number (got: " ++ value ++ ")"

        DuplicateServingUnit unit ->
            "Each serving must use a unique unit (duplicate: " ++ unit ++ ")"

        InvalidDefaultPortion ->
            "Default portion must be grams or use a configured serving unit"



-- VIEW


view : Theme -> Device -> List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view theme device nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Ui.maybeErrorBanner theme (submitErrorMessage form.submit)
        , basicInfoCard True theme device form
        , nutrientsCard Per100Grams AllNutrients theme device form nutrients
        , servingsCard theme device form units
        , defaultPortionCard theme device units form
        ]


viewForCreate : Theme -> Device -> List NutrientItem -> FormModel -> Element Msg
viewForCreate theme device nutrients form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Ui.maybeErrorBanner theme (submitErrorMessage form.submit)
        , basicInfoCard True theme device form
        , nutrientsCard Per100Grams AllNutrients theme device form nutrients
        ]


viewForLog :
    NutrientVisibility
    -> Theme
    -> Device
    -> List NutrientItem
    -> List UnitItem
    -> FormModel
    -> Element Msg
viewForLog visibility theme device nutrients units form =
    case form.context of
        CustomFoodContext ->
            Element.none

        FoodLogContext logFields persistence ->
            let
                saving : Bool
                saving =
                    case persistence of
                        LogAdHocOnly ->
                            False

                        SaveCustomFoodThenLog _ ->
                            True
            in
            Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                ([ basicInfoCard saving theme device form
                 , loggedPortionCard theme device units form logFields
                 , nutrientsCard PerLoggedPortion visibility theme device form nutrients
                 , logDetailsCard theme device form logFields
                 , saveToFoodsCard theme device persistence
                 ]
                    ++ (if saving then
                            [ servingsCard theme device form units ]

                        else
                            []
                       )
                )


basicInfoCard : Bool -> Theme -> Device -> FormModel -> Element Msg
basicInfoCard showCategories theme device form =
    Ui.formSection theme
        "Basic Info"
        [ Ui.input theme { label = "Name", value = form.name, onChange = NameChanged }
        , Ui.input theme { label = "Brand", value = form.brand, onChange = BrandChanged }
        , if showCategories then
            categoryInputView theme device (form.openDropdown == CategoryOpen) form.categoryInput

          else
            Element.none
        ]


loggedPortionCard : Theme -> Device -> List UnitItem -> FormModel -> LogFields -> Element Msg
loggedPortionCard theme device units form logFields =
    Ui.formSection theme
        "Logged Portion"
        [ Typography.mutedParagraph theme "Describe the entire amount you are logging."
        , Ui.decimalInput theme
            { label = "Amount"
            , value = logFields.quantity
            , onChange = LogQuantityChanged
            }
        , Ui.selectDropdown device
            theme
            { label = "Portion unit"
            , selected = logFields.unit
            , options = List.map (\unit -> ( unit.code, unit.name )) units
            , onChange = LogUnitChanged
            , isOpen = form.openDropdown == LogUnitOpen
            , onToggle = ToggleLogUnitDropdown
            }
        ]


logDetailsCard : Theme -> Device -> FormModel -> LogFields -> Element Msg
logDetailsCard theme device form logFields =
    Ui.formSection theme
        "Log Details"
        [ Ui.input theme
            { label = "Date (YYYY-MM-DD)"
            , value = logFields.date
            , onChange = LogDateChanged
            }
        , Ui.selectDropdown device
            theme
            { label = "Meal"
            , selected = logFields.mealSlot
            , options =
                [ ( Nothing, "None" )
                , ( Just Breakfast, MealSlot.label Breakfast )
                , ( Just Lunch, MealSlot.label Lunch )
                , ( Just Dinner, MealSlot.label Dinner )
                , ( Just Snack, MealSlot.label Snack )
                , ( Just LateNightSnack, MealSlot.label LateNightSnack )
                ]
            , onChange = LogMealSlotChanged
            , isOpen = form.openDropdown == MealSlotOpen
            , onToggle = ToggleMealSlotDropdown
            }
        , Ui.input theme
            { label = "Notes (optional)"
            , value = logFields.notes
            , onChange = LogNotesChanged
            }
        ]


saveToFoodsCard : Theme -> Device -> LogPersistence -> Element Msg
saveToFoodsCard theme _ persistence =
    Ui.card theme
        ([ Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ Element.el [ Element.width Element.fill ]
                (Typography.sectionTitle theme "Save to My Foods")
            , Ui.toggleSwitch theme
                { isActive =
                    case persistence of
                        LogAdHocOnly ->
                            False

                        SaveCustomFoodThenLog _ ->
                            True
                , onToggle = LogPersistenceToggled
                }
            ]
         , Typography.mutedParagraph theme
            "Save this as a reusable custom food before logging it."
         ]
            ++ (case persistence of
                    LogAdHocOnly ->
                        []

                    SaveCustomFoodThenLog details ->
                        [ Ui.decimalInput theme
                            { label = "Weight of this logged portion (g)"
                            , value = details.portionWeight
                            , onChange = PortionWeightChanged
                            }
                        ]
               )
        )


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


nutrientsCard :
    NutrientBasis
    -> NutrientVisibility
    -> Theme
    -> Device
    -> FormModel
    -> List NutrientItem
    -> Element Msg
nutrientsCard basis visibility theme device form nutrients =
    Ui.section theme
        { header =
            Just
                (Element.column [ Element.spacing DesignTokens.space8 ]
                    [ Typography.subsectionTitle theme
                        (case basis of
                            Per100Grams ->
                                "Nutrients"

                            PerLoggedPortion ->
                                "Portion Nutrition"
                        )
                    , nutrientHint basis theme
                    ]
                )
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                (form.nutrients
                    |> List.indexedMap Tuple.pair
                    |> List.filter
                        (\( _, row ) ->
                            case visibility of
                                AllNutrients ->
                                    True

                                CoreNutrientsOnly ->
                                    List.member row.code coreNutrientCodes
                        )
                    |> List.map
                        (\( index, row ) ->
                            nutrientRowView basis
                                theme
                                device
                                nutrients
                                form.openDropdown
                                index
                                row
                        )
                )
            ]
        , footer =
            Just
                (Ui.textButton device
                    theme
                    { tone = Ui.Ghost
                    , width = Ui.FullWidth
                    , label = "+ Add Nutrient"
                    , onPress = AddNutrientRow
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
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
        , footer =
            Just
                (Ui.textButton device
                    theme
                    { tone = Ui.Ghost
                    , width = Ui.FullWidth
                    , label = "+ Add Serving"
                    , onPress = AddServingRow
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
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
        { icon = Icon.Plus
        , title = "Add category"
        , onPress = Just (AddCategory input.query)
        , tone = Ui.Primary
        }


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
    NutrientBasis
    -> Theme
    -> Device
    -> List NutrientItem
    -> OpenDropdown
    -> Int
    -> NutrientRow
    -> Element Msg
nutrientRowView basis theme device nutrients openDropdown index row =
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
                [ amountInputWithUnit basis theme index row
                , removeButton
                ]
            ]

    else
        Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]
            [ selector
            , amountInputWithUnit basis theme index row
            , removeButton
            ]


amountInputWithUnit : NutrientBasis -> Theme -> Int -> NutrientRow -> Element Msg
amountInputWithUnit basis theme index row =
    Ui.decimalInputWithSuffix theme
        { label =
            case basis of
                Per100Grams ->
                    "Amount per 100 g"

                PerLoggedPortion ->
                    "Amount for this portion"
        , text = row.amount
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
        (Ui.iconButton device
            theme
            { icon = config.icon
            , title = config.title
            , onPress = Just config.onPress
            , tone = Ui.Danger
            }
        )


addRowHint : Theme -> Element msg
addRowHint theme =
    Typography.mutedCaption theme "Enter calories and macros (per 100g) to save."


nutrientHint : NutrientBasis -> Theme -> Element msg
nutrientHint basis theme =
    case basis of
        Per100Grams ->
            addRowHint theme

        PerLoggedPortion ->
            Typography.mutedCaption theme
                ("Enter totals for the entire logged portion. Calories, protein, "
                    ++ "carbohydrates, and fat are required."
                )
