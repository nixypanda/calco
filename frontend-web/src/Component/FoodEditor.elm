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
import Element exposing (Element)
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.ListExtra as ListExtra
import Lib.Number as Number
import Lib.Text as Text
import Lib.Ticket as Ticket exposing (Ticket)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Icon as Icon exposing (Icon)
import Ui.Input as UiInput
import Ui.Surface as Surface
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
    { code : String, amount : String, unit : String }


type NutrientBasis
    = Per100Grams
    | PerLoggedPortion


type NutrientVisibility
    = AllNutrients
    | CoreNutrientsOnly


type alias ServingRow =
    { unit : String, gramsPerUnit : String }


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
    { selected = [], query = "", suggestions = [], token = Ticket.initial }


emptyNutrientRow : NutrientRow
emptyNutrientRow =
    { code = "", amount = "", unit = "" }


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
                        Dict.get nutrient.code form.nutrientCatalog |> Maybe.withDefault ""
                    }
                )
                draft.nutrients
        , servings =
            List.map
                (\serving ->
                    { unit = serving.unit, gramsPerUnit = serving.gramsPerUnit }
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
                                        DerivedPortion { weightGrams = suggested.totalWeightGrams }
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
                            { unit = serving.unit, gramsPerUnit = serving.gramsPerUnit }
                        )
                        draft.servings
                , context = context
            }
        )
        (positiveNumber
            (I18n.en TidFoodEditorLabelSuggestedPortionWeight)
            suggested.totalWeightGrams
        )
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
            Err (I18n.en (TidFoodEditorErrorUnsupportedNutrient nutrient.code))

        Just item ->
            Result.map2
                (\weight amountPer100g ->
                    { code = nutrient.code
                    , amount = String.fromFloat (amountPer100g * weight / 100)
                    , unit = item.unit
                    }
                )
                (positiveNumber (I18n.en TidFoodEditorLabelSuggestedPortionWeight) rawWeight)
                (nonNegativeNumber
                    (I18n.en TidFoodEditorLabelEstimatedNutrient)
                    nutrient.amountPer100g
                )


requireCoreNutrients : List NutrientRow -> Result String (List NutrientRow)
requireCoreNutrients rows =
    case
        coreNutrientCodes
            |> List.filter (\code -> not (List.any (\row -> row.code == code) rows))
            |> List.head
    of
        Just _ ->
            Err (I18n.en TidFoodEditorErrorMissingCoreMacros)

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
                                FoodLogContext { logFields | quantity = rawQuantity } persistence
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
                    { form | context = FoodLogContext { logFields | unit = unit } persistence }

        CustomFoodContext ->
            form


scaleLogPortion : Float -> FormModel -> FormModel
scaleLogPortion ratio form =
    { form
        | nutrients =
            List.map (\row -> { row | amount = scaleNumberString ratio row.amount }) form.nutrients
        , context =
            case form.context of
                FoodLogContext logFields persistence ->
                    FoodLogContext
                        { logFields | nutrition = scalePortionNutrition ratio logFields.nutrition }
                        (scalePersistenceWeight ratio persistence)

                other ->
                    other
    }


scaleNumberString : Float -> String -> String
scaleNumberString ratio raw =
    String.toFloat raw |> Maybe.map ((*) ratio >> String.fromFloat) |> Maybe.withDefault raw


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
            DerivedPortion { details | weightGrams = scaleNumberString ratio details.weightGrams }

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
        [ form.name, form.brand, form.categoryInput.query, form.defaultQuantity ]
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
                        { code = n.code, amount = n.amountPer100g, unit = n.unit }
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
                    { unit = s.unit, gramsPerUnit = formatServingGrams s.gramsPerUnit }
                )
                food.servings
    }


formatServingGrams : String -> String
formatServingGrams value =
    value |> String.toFloat |> Maybe.map (Number.toFixedTrimmed 3) |> Maybe.withDefault value


withNutrientCatalog : List NutrientItem -> FormModel -> FormModel
withNutrientCatalog items form =
    let
        catalog : Dict String String
        catalog =
            List.foldl (\item acc -> Dict.insert item.code item.unit acc) form.nutrientCatalog items
    in
    { form | nutrientCatalog = catalog, nutrients = backfillNutrientUnits catalog form.nutrients }


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
    toCreateFoodRequest { form | defaultQuantity = "", defaultUnit = "", servings = [] }


validateLog : FormModel -> Result String ValidatedLog
validateLog form =
    case form.context of
        CustomFoodContext ->
            Err (I18n.en TidFoodEditorErrorNotConfigured)

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
                                    Err (I18n.en TidFoodEditorErrorSelectNutrient)

                                else
                                    nonNegativeNumber
                                        (View.Nutrients.nutrientLabel I18n.defaultLanguage row.code)
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
                            positiveNumber
                                (I18n.en TidFoodEditorLabelPortionWeight)
                                details.portionWeight
                                |> Result.map Just
            in
            case LocalDate.fromString logFields.date of
                Nothing ->
                    Err (I18n.en TidFoodEditorErrorInvalidDate)

                Just date ->
                    if String.isEmpty (String.trim form.name) then
                        Err (I18n.en TidFoodEditorErrorFoodNameRequired)

                    else if duplicate /= Nothing then
                        Err (I18n.en TidFoodEditorErrorDuplicateNutrient)

                    else
                        case missingRequired of
                            Just code ->
                                Err
                                    (I18n.en
                                        (TidFoodEditorErrorNutrientRequired
                                            (View.Nutrients.nutrientLabel I18n.defaultLanguage code)
                                        )
                                    )

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
                                    (positiveNumber
                                        (I18n.en TidNutrientTableAmount)
                                        logFields.quantity
                                    )
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
                        Err (I18n.en TidFoodEditorErrorPortionWeightRequired)

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
                            Err (I18n.en TidFoodEditorErrorPortionTooLarge)

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
    not (String.isEmpty (String.trim row.code)) && not (String.isEmpty (String.trim row.amount))


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
                Ok { code = String.trim row.code, amountPer100g = amount }

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
            { unit = String.trim row.unit, gramsPerUnit = value }
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
            ( withNutrientCatalog items form, Cmd.none, NoOutMsg )

        CategoryQueryChanged value ->
            let
                categoryInput : CategoryInput
                categoryInput =
                    form.categoryInput

                next : CategoryInput
                next =
                    { categoryInput | query = value, token = Ticket.next categoryInput.token }

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
                    { categoryInput | selected = List.filter ((/=) value) categoryInput.selected }
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
                    Dict.get value form.nutrientCatalog |> Maybe.withDefault ""
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
                    ListExtra.updateAt index (\row -> { row | amount = value }) form.nutrients
              }
            , Cmd.none
            , NoOutMsg
            )

        AddNutrientRow ->
            ( { form | nutrients = form.nutrients ++ [ emptyNutrientRow ] }, Cmd.none, NoOutMsg )

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
                    ListExtra.updateAt index (\row -> { row | unit = value }) form.servings
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
                    ListExtra.updateAt index (\row -> { row | gramsPerUnit = value }) form.servings
              }
            , Cmd.none
            , NoOutMsg
            )

        AddServingRow ->
            ( { form | servings = form.servings ++ [ emptyServingRow ] }, Cmd.none, NoOutMsg )

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
            ( mapLogFields (\logFields -> { logFields | date = value }) form, Cmd.none, NoOutMsg )

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
            ( mapLogFields (\logFields -> { logFields | notes = value }) form, Cmd.none, NoOutMsg )

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
            ( setPortionWeight value form, Cmd.none, NoOutMsg )


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
                Err (I18n.en (TidFoodEditorErrorGreaterThanZero label))

        Nothing ->
            Err (I18n.en (TidFoodEditorErrorNumberGreaterThanZero label))


nonNegativeNumber : String -> String -> Result String Float
nonNegativeNumber label raw =
    case String.toFloat (String.trim raw) of
        Just value ->
            if value >= 0 && finite value then
                Ok value

            else
                Err (I18n.en (TidFoodEditorErrorZeroOrGreater label))

        Nothing ->
            Err (I18n.en (TidFoodEditorErrorRequiredNumber label))


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
            I18n.en TidFoodEditorErrorNameRequired

        InvalidNutrientAmount value ->
            I18n.en (TidFoodEditorErrorNutrientAmountNonNegative value)

        InvalidServingGrams value ->
            I18n.en (TidFoodEditorErrorServingGramsPositive value)

        DuplicateServingUnit unit ->
            I18n.en (TidFoodEditorErrorDuplicateServingUnit unit)

        InvalidDefaultPortion ->
            I18n.en TidFoodEditorErrorInvalidDefaultPortion



-- VIEW


view : Env -> List NutrientItem -> List UnitItem -> FormModel -> Element Msg
view env nutrients units form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Feedback.maybeErrorBanner env.theme (submitErrorMessage form.submit)
        , basicInfoCard env True form
        , nutrientsCard env Per100Grams AllNutrients form nutrients
        , servingsCard env form units
        , defaultPortionCard env units form
        ]


viewForCreate : Env -> List NutrientItem -> FormModel -> Element Msg
viewForCreate env nutrients form =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Feedback.maybeErrorBanner env.theme (submitErrorMessage form.submit)
        , basicInfoCard env True form
        , nutrientsCard env Per100Grams AllNutrients form nutrients
        ]


viewForLog :
    Env
    -> NutrientVisibility
    -> List NutrientItem
    -> List UnitItem
    -> FormModel
    -> Element Msg
viewForLog env visibility nutrients units form =
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
                ([ basicInfoCard env saving form
                 , loggedPortionCard env units form logFields
                 , nutrientsCard env PerLoggedPortion visibility form nutrients
                 , logDetailsCard env form logFields
                 , saveToFoodsCard env persistence
                 ]
                    ++ (if saving then
                            [ servingsCard env form units ]

                        else
                            []
                       )
                )


basicInfoCard : Env -> Bool -> FormModel -> Element Msg
basicInfoCard env showCategories form =
    Surface.formSection env.theme
        (I18n.t env.language TidFoodEditorBasicInfo)
        [ UiInput.input env.theme
            { label = I18n.t env.language TidFoodEditorName
            , value = form.name
            , onChange = NameChanged
            }
        , UiInput.input env.theme
            { label = I18n.t env.language TidFoodEditorBrand
            , value = form.brand
            , onChange = BrandChanged
            }
        , if showCategories then
            categoryInputView env (form.openDropdown == CategoryOpen) form.categoryInput

          else
            Element.none
        ]


loggedPortionCard : Env -> List UnitItem -> FormModel -> LogFields -> Element Msg
loggedPortionCard env units form logFields =
    Surface.formSection env.theme
        (I18n.t env.language TidFoodEditorLoggedPortion)
        [ Typography.mutedParagraph env.theme (I18n.t env.language TidFoodEditorLoggedPortionHint)
        , UiInput.numericInput env.theme
            { label = I18n.t env.language TidNutrientTableAmount
            , value = logFields.quantity
            , onChange = LogQuantityChanged
            }
        , UiInput.selectDropdown env.device
            env.theme
            env.language
            { label = I18n.t env.language TidFoodEditorPortionUnit
            , selected = logFields.unit
            , options = List.map (\unit -> ( unit.code, unit.name )) units
            , onChange = LogUnitChanged
            , isOpen = form.openDropdown == LogUnitOpen
            , onToggle = ToggleLogUnitDropdown
            }
        ]


logDetailsCard : Env -> FormModel -> LogFields -> Element Msg
logDetailsCard env form logFields =
    Surface.formSection env.theme
        (I18n.t env.language TidFoodEditorLogDetails)
        [ UiInput.input env.theme
            { label = I18n.t env.language TidFoodEditorDateLabel
            , value = logFields.date
            , onChange = LogDateChanged
            }
        , UiInput.selectDropdown env.device
            env.theme
            env.language
            { label = I18n.t env.language TidTitleMeal
            , selected = logFields.mealSlot
            , options =
                [ ( Nothing, I18n.t env.language TidFoodEditorMealNone )
                , ( Just Breakfast, MealSlot.label env.language Breakfast )
                , ( Just Lunch, MealSlot.label env.language Lunch )
                , ( Just Dinner, MealSlot.label env.language Dinner )
                , ( Just Snack, MealSlot.label env.language Snack )
                , ( Just LateNightSnack, MealSlot.label env.language LateNightSnack )
                ]
            , onChange = LogMealSlotChanged
            , isOpen = form.openDropdown == MealSlotOpen
            , onToggle = ToggleMealSlotDropdown
            }
        , UiInput.input env.theme
            { label = I18n.t env.language TidFoodEditorNotes
            , value = logFields.notes
            , onChange = LogNotesChanged
            }
        ]


saveToFoodsCard : Env -> LogPersistence -> Element Msg
saveToFoodsCard env persistence =
    Surface.section env.theme
        { header =
            Just
                (Surface.sectionHeader
                    { title =
                        Typography.sectionTitle env.theme
                            (I18n.t env.language TidFoodEditorSaveToFoods)
                    , description =
                        Just
                            (Typography.mutedParagraph env.theme
                                (I18n.t env.language TidFoodEditorSaveToFoodsDescription)
                            )
                    , trailing =
                        Just
                            (UiInput.toggleSwitch env.theme
                                { label = I18n.t env.language TidFoodEditorSaveToFoods
                                , isActive =
                                    case persistence of
                                        LogAdHocOnly ->
                                            False

                                        SaveCustomFoodThenLog _ ->
                                            True
                                , onToggle = LogPersistenceToggled
                                }
                            )
                    }
                )
        , body =
            case persistence of
                LogAdHocOnly ->
                    []

                SaveCustomFoodThenLog details ->
                    [ UiInput.numericInput env.theme
                        { label = I18n.t env.language TidFoodEditorPortionWeightLabel
                        , value = details.portionWeight
                        , onChange = PortionWeightChanged
                        }
                    ]
        , footer = Nothing
        }


defaultPortionCard : Env -> List UnitItem -> FormModel -> Element Msg
defaultPortionCard env units form =
    Surface.formSection env.theme
        (I18n.t env.language TidFoodEditorDefaultPortion)
        [ defaultPortionFields env units form
        , Typography.mutedCaption env.theme
            (if form.defaultUnit == "" then
                if List.isEmpty form.servings then
                    I18n.t env.language TidFoodEditorDefaultPortionHint100g

                else
                    I18n.t env.language TidFoodEditorDefaultPortionHintServing

             else if form.defaultUnit == "g" then
                I18n.t env.language TidFoodEditorDefaultPortionHintGrams

             else
                I18n.t env.language TidFoodEditorDefaultPortionHintCount
            )
        ]


defaultPortionFields : Env -> List UnitItem -> FormModel -> Element Msg
defaultPortionFields env units form =
    let
        unitSelector : Element Msg
        unitSelector =
            UiInput.selectDropdown env.device
                env.theme
                env.language
                { label = I18n.t env.language TidFoodEditorDefaultUnit
                , selected = form.defaultUnit
                , options = defaultPortionOptions env.language units form
                , onChange = DefaultUnitChanged
                , isOpen = form.openDropdown == DefaultUnitOpen
                , onToggle = ToggleDefaultUnitDropdown
                }

        quantityInput : Element Msg
        quantityInput =
            if String.isEmpty form.defaultUnit then
                Element.none

            else
                UiInput.numericInput env.theme
                    { label = I18n.t env.language TidFoodEditorDefaultQuantity
                    , value = form.defaultQuantity
                    , onChange = DefaultQuantityChanged
                    }

        attributes : List (Element.Attribute Msg)
        attributes =
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
    in
    if UiCommon.isSmall env.device then
        Element.column attributes [ unitSelector, quantityInput ]

    else
        Element.row attributes [ unitSelector, quantityInput ]


defaultPortionOptions : Language -> List UnitItem -> FormModel -> List ( String, String )
defaultPortionOptions language units form =
    ( noDefaultOption, I18n.t language TidFoodEditorNoDefault )
        :: ( "g", I18n.t language TidFoodEditorGrams )
        :: List.map
            (\serving ->
                ( serving.unit, servingUnitLabel language units serving.unit )
            )
            (List.filter hasServingInput form.servings)


servingUnitLabel : Language -> List UnitItem -> String -> String
servingUnitLabel language units code =
    case List.filter (\unit -> unit.code == code) units |> List.head of
        Just unit ->
            if unit.name == unit.code then
                unit.code

            else
                I18n.t language (TidUiUnitWithCode unit.name unit.code)

        Nothing ->
            code


nutrientsCard :
    Env
    -> NutrientBasis
    -> NutrientVisibility
    -> FormModel
    -> List NutrientItem
    -> Element Msg
nutrientsCard env basis visibility form nutrients =
    Surface.section env.theme
        { header =
            Just
                (Element.column [ Element.spacing DesignTokens.space8 ]
                    [ Typography.subsectionTitle env.theme
                        (case basis of
                            Per100Grams ->
                                I18n.t env.language TidFoodEditorNutrientsTitle

                            PerLoggedPortion ->
                                I18n.t env.language TidFoodEditorPortionNutrition
                        )
                    , nutrientHint env basis
                    ]
                )
        , body =
            [ Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
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
                            nutrientRowView env basis nutrients form.openDropdown index row
                        )
                )
            ]
        , footer =
            Just
                (Button.textButton env.device
                    env.theme
                    { tone = Button.Ghost
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidFoodEditorAddNutrient
                    , onPress = AddNutrientRow
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
        }


servingsCard : Env -> FormModel -> List UnitItem -> Element Msg
servingsCard env form units =
    Surface.section env.theme
        { header =
            Just (Typography.subsectionTitle env.theme (I18n.t env.language TidFoodEditorServings))
        , body =
            [ Element.column
                [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                (if List.isEmpty form.servings then
                    [ Typography.mutedParagraph env.theme
                        (I18n.t env.language TidFoodEditorServingsEmpty)
                    ]

                 else
                    List.indexedMap (servingRowView env units form.openDropdown) form.servings
                )
            ]
        , footer =
            Just
                (Button.textButton env.device
                    env.theme
                    { tone = Button.Ghost
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidFoodEditorAddServing
                    , onPress = AddServingRow
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
        }


categoryInputView : Env -> Bool -> CategoryInput -> Element Msg
categoryInputView env open input =
    Element.column [ Element.width Element.fill ]
        [ Element.row [ Element.spacing DesignTokens.space4 ]
            [ UiInput.fieldLabel env.theme (I18n.t env.language TidFoodEditorCategories)
            , Typography.mutedCaption env.theme (I18n.t env.language TidFoodEditorCategoriesHint)
            ]
        , Element.row [ Element.width Element.fill ]
            [ Element.el [ Element.width Element.fill ]
                (UiInput.input env.theme
                    { label = "", value = input.query, onChange = CategoryQueryChanged }
                )
            , Element.el
                [ Element.paddingEach
                    { top = DesignTokens.space4, left = DesignTokens.space4, bottom = 0, right = 0 }
                ]
                (addCategoryButton env input)
            ]
        , suggestionRowView env open input
        , chipRowView env input.selected
        ]


addCategoryButton : Env -> CategoryInput -> Element Msg
addCategoryButton env input =
    Button.iconButton env.device
        env.theme
        { icon = Icon.Plus
        , title = I18n.t env.language TidFoodEditorAddCategory
        , onPress = Just (AddCategory input.query)
        , tone = Button.Primary
        }


chipRowView : Env -> List String -> Element Msg
chipRowView env tags =
    if List.isEmpty tags then
        Typography.mutedCaption env.theme (I18n.t env.language TidFoodEditorNoCategories)

    else
        Element.wrappedRow
            [ Element.width Element.fill
            , Element.paddingXY 0 DesignTokens.space4
            , Element.spacing DesignTokens.space8
            ]
            (List.map (chipView env) tags)


chipView : Env -> String -> Element Msg
chipView env tag =
    Chip.removableChip env.theme env.language { label = tag, onRemove = RemoveCategory tag }


suggestionRowView : Env -> Bool -> CategoryInput -> Element Msg
suggestionRowView env open input =
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
        UiInput.suggestionList env.theme (List.map (suggestionRow env) matching)


suggestionRow : Env -> CategorySuggestion -> Element Msg
suggestionRow env s =
    UiInput.optionRow env.theme
        { label = s.value
        , trailing =
            Just
                (Typography.mutedCaption env.theme
                    (I18n.t env.language (TidFoodEditorUses (String.fromInt s.count)))
                )
        , selected = False
        , onPress = AcceptCategorySuggestion s.value
        }


nutrientRowView :
    Env
    -> NutrientBasis
    -> List NutrientItem
    -> OpenDropdown
    -> Int
    -> NutrientRow
    -> Element Msg
nutrientRowView env basis nutrients openDropdown index row =
    let
        selector : Element Msg
        selector =
            UiInput.selectDropdown env.device
                env.theme
                env.language
                { label = I18n.t env.language TidNutrientTableNutrient
                , selected = row.code
                , options =
                    ( "", I18n.t env.language TidFoodEditorSelectNutrient )
                        :: List.map (\n -> ( n.code, n.name )) nutrients
                , onChange = NutrientCodeChanged index
                , isOpen = openDropdown == NutrientCodeOpen index
                , onToggle = ToggleNutrientCodeDropdown index
                }

        removeButton : Element Msg
        removeButton =
            rowActionButton env
                { icon = Icon.Close
                , title = I18n.t env.language TidFoodEditorRemove
                , onPress = RemoveNutrientRow index
                }
    in
    if UiCommon.isSmall env.device then
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector
            , Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ amountInputWithUnit env basis index row, removeButton ]
            ]

    else
        Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector, amountInputWithUnit env basis index row, removeButton ]


amountInputWithUnit : Env -> NutrientBasis -> Int -> NutrientRow -> Element Msg
amountInputWithUnit env basis index row =
    UiInput.decimalInputWithSuffix env.theme
        { label =
            case basis of
                Per100Grams ->
                    I18n.t env.language TidFoodEditorAmountPer100g

                PerLoggedPortion ->
                    I18n.t env.language TidFoodEditorAmountForPortion
        , text = row.amount
        , suffix = unitGhostText env.language row.unit
        , onChange = NutrientAmountChanged index
        }


{-| Muted unit text shown inside the amount input. Empty units fall back to a
neutral placeholder so the field still communicates that the suffix depends on
the selected nutrient.
-}
unitGhostText : Language -> String -> String
unitGhostText language unit =
    if String.isEmpty (String.trim unit) then
        I18n.t language TidFoodEditorUnitPlaceholder

    else
        unit


servingRowView : Env -> List UnitItem -> OpenDropdown -> Int -> ServingRow -> Element Msg
servingRowView env units openDropdown index row =
    let
        selector : Element Msg
        selector =
            UiInput.selectDropdown env.device
                env.theme
                env.language
                { label = I18n.t env.language TidNutrientTableUnit
                , selected = row.unit
                , options = View.QuantityInput.unitOptions env.language row.unit units
                , onChange = ServingUnitChanged index
                , isOpen = openDropdown == ServingUnitOpen index
                , onToggle = ToggleServingUnitDropdown index
                }

        gramsInput : Element Msg
        gramsInput =
            UiInput.decimalInputWithSuffix env.theme
                { label = I18n.t env.language TidFoodEditorGramsPerUnit
                , text = row.gramsPerUnit
                , suffix = "g"
                , onChange = ServingGramsPerUnitChanged index
                }

        removeButton : Element Msg
        removeButton =
            rowActionButton env
                { icon = Icon.Close
                , title = I18n.t env.language TidFoodEditorRemove
                , onPress = RemoveServingRow index
                }
    in
    if UiCommon.isSmall env.device then
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector
            , Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ gramsInput, removeButton ]
            ]

    else
        Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector, gramsInput, removeButton ]


rowActionButton : Env -> { icon : Icon, title : String, onPress : msg } -> Element msg
rowActionButton env config =
    Element.el
        [ Element.width (Element.px 44)
        , Element.paddingEach { top = DesignTokens.space16, right = 0, bottom = 0, left = 0 }
        ]
        (Button.iconButton env.device
            env.theme
            { icon = config.icon
            , title = config.title
            , onPress = Just config.onPress
            , tone = Button.Danger
            }
        )


addRowHint : Env -> Element msg
addRowHint env =
    Typography.mutedCaption env.theme (I18n.t env.language TidFoodEditorAddRowHint)


nutrientHint : Env -> NutrientBasis -> Element msg
nutrientHint env basis =
    case basis of
        Per100Grams ->
            addRowHint env

        PerLoggedPortion ->
            Typography.mutedCaption env.theme (I18n.t env.language TidFoodEditorPortionHint)
