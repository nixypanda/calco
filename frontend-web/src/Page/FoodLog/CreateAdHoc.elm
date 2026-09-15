module Page.FoodLog.CreateAdHoc exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SubmitState(..)
    , init
    , update
    , view
    , viewForAi
    )

import Api.Client as Client
import Api.Foods exposing (CreateFoodRequest, CreateFoodResponse, NutrientItem, UnitItem)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Data.FoodLog exposing (FoodLog)
import Data.LocalContext exposing (LocalContext)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Element exposing (Device, Element)
import Lib.Date as LocalDate
import Lib.ListExtra as ListExtra
import Page.FoodLog.AdHocForm as Form
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type alias Model =
    { form : Form.Model
    , units : List UnitItem
    , nutrients : List NutrientItem
    , unitOpen : Bool
    , nutrientOpen : Maybe Int
    , mealSlotOpen : Bool
    , deviceTimezone : Maybe String
    , submit : SubmitState
    }


type SubmitState
    = SubmitIdle
    | AwaitingLocalContext
    | LoggingAdHoc
    | SavingCustomFood
    | LoggingSavedFood String
    | SubmitFailed String
    | LogFailedAfterFoodSaved { productId : String, message : String }


init : Maybe String -> Maybe MealSlot -> Model
init date mealSlot =
    { form = Form.empty date mealSlot
    , units = []
    , nutrients = []
    , unitOpen = False
    , nutrientOpen = Nothing
    , mealSlotOpen = False
    , deviceTimezone = Nothing
    , submit = SubmitIdle
    }


type Msg
    = UnitsLoaded (Result Client.ApiError Api.Foods.UnitListResponse)
    | NutrientsLoaded (Result Client.ApiError Api.Foods.NutrientListResponse)
    | NameChanged String
    | BrandChanged String
    | AmountChanged String
    | UnitChanged String
    | ToggleUnit
    | MealSlotChanged (Maybe MealSlot)
    | ToggleMealSlot
    | DateChanged String
    | NutrientCodeChanged Int String
    | NutrientAmountChanged Int String
    | ToggleNutrient Int
    | AddNutrient
    | RemoveNutrient Int
    | NotesChanged String
    | SaveToMyFoodsToggled
    | PortionWeightChanged String
    | SubmitClicked
    | LocalContextReceived LocalContext
    | AdHocLogCompleted (Result Client.ApiError FoodLog)
    | CustomFoodCompleted (Result Client.ApiError CreateFoodResponse)
    | ProductLogCompleted (Result Client.ApiError FoodLog)


type OutMsg
    = NoOp
    | RequestLocalContext
    | RequestAdHocLog CreateAdHocLogRequest
    | RequestCreateFood CreateFoodRequest
    | RequestProductLog CreateLogRequest
    | LogCreated FoodLog
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = response.items }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | nutrients = response.items
                        , form = Form.withNutrientCatalog response.items model.form
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    failure error model

        NameChanged value ->
            changed (\form -> { form | name = value }) model

        BrandChanged value ->
            changed (\form -> { form | brand = value }) model

        AmountChanged value ->
            changed (\form -> { form | amount = value }) model

        UnitChanged value ->
            changed (\form -> { form | unit = value }) { model | unitOpen = False }

        ToggleUnit ->
            ( { model
                | unitOpen = not model.unitOpen
                , mealSlotOpen = False
                , nutrientOpen = Nothing
              }
            , Cmd.none
            , NoOp
            )

        MealSlotChanged value ->
            changed (\form -> { form | mealSlot = value }) { model | mealSlotOpen = False }

        ToggleMealSlot ->
            ( { model | mealSlotOpen = not model.mealSlotOpen, unitOpen = False }
            , Cmd.none
            , NoOp
            )

        DateChanged value ->
            changed (\form -> { form | date = value }) model

        NutrientCodeChanged index code ->
            let
                unit : String
                unit =
                    model.nutrients
                        |> List.filter (\item -> item.code == code)
                        |> List.head
                        |> Maybe.map .unit
                        |> Maybe.withDefault ""
            in
            changed
                (\form ->
                    { form
                        | nutrients =
                            ListExtra.updateAt
                                index
                                (\row -> { row | code = code, unit = unit })
                                form.nutrients
                    }
                )
                { model | nutrientOpen = Nothing }

        NutrientAmountChanged index value ->
            changed
                (\form ->
                    { form
                        | nutrients =
                            ListExtra.updateAt
                                index
                                (\row -> { row | amount = value })
                                form.nutrients
                    }
                )
                model

        ToggleNutrient index ->
            ( { model
                | nutrientOpen =
                    if model.nutrientOpen == Just index then
                        Nothing

                    else
                        Just index
                , unitOpen = False
                , mealSlotOpen = False
              }
            , Cmd.none
            , NoOp
            )

        AddNutrient ->
            changed
                (\form ->
                    { form
                        | nutrients =
                            form.nutrients ++ [ { code = "", amount = "", unit = "" } ]
                    }
                )
                model

        RemoveNutrient index ->
            changed
                (\form ->
                    { form | nutrients = ListExtra.removeAt index form.nutrients }
                )
                { model | nutrientOpen = Nothing }

        NotesChanged value ->
            changed (\form -> { form | notes = value }) model

        SaveToMyFoodsToggled ->
            changed
                (\form -> { form | saveToMyFoods = not form.saveToMyFoods })
                model

        PortionWeightChanged value ->
            changed (\form -> { form | portionWeight = value }) model

        SubmitClicked ->
            submit model

        LocalContextReceived context ->
            if model.submit == AwaitingLocalContext then
                startSubmission
                    { model
                        | form = setDateIfBlank context.date model.form
                        , deviceTimezone = Just context.timezone
                    }

            else
                ( model, Cmd.none, NoOp )

        AdHocLogCompleted result ->
            case result of
                Ok log ->
                    ( { model | submit = SubmitIdle }, Cmd.none, LogCreated log )

                Err error ->
                    failure error model

        CustomFoodCompleted result ->
            case result of
                Ok response ->
                    requestProductLog response.id model

                Err error ->
                    failure error model

        ProductLogCompleted result ->
            case result of
                Ok log ->
                    ( { model | submit = SubmitIdle }, Cmd.none, LogCreated log )

                Err error ->
                    if Client.isUnauthorized error then
                        ( model, Cmd.none, SessionExpired )

                    else
                        case savedProductId model.submit of
                            Just productId ->
                                ( { model
                                    | submit =
                                        LogFailedAfterFoodSaved
                                            { productId = productId
                                            , message =
                                                "Food was saved to My Foods,"
                                                    ++ " but it could not be logged."
                                            }
                                  }
                                , Cmd.none
                                , NoOp
                                )

                            Nothing ->
                                failure error model


changed : (Form.Model -> Form.Model) -> Model -> ( Model, Cmd Msg, OutMsg )
changed transform model =
    ( { model | form = transform model.form, submit = clearFailure model.submit }
    , Cmd.none
    , NoOp
    )


clearFailure : SubmitState -> SubmitState
clearFailure state =
    case state of
        SubmitFailed _ ->
            SubmitIdle

        _ ->
            state


submit : Model -> ( Model, Cmd Msg, OutMsg )
submit model =
    case model.submit of
        LogFailedAfterFoodSaved saved ->
            requestProductLog saved.productId model

        SubmitIdle ->
            if String.isEmpty (String.trim model.form.date) then
                ( { model | submit = AwaitingLocalContext }, Cmd.none, RequestLocalContext )

            else
                startSubmission model

        SubmitFailed _ ->
            startSubmission model

        _ ->
            ( model, Cmd.none, NoOp )


startSubmission : Model -> ( Model, Cmd Msg, OutMsg )
startSubmission model =
    case ( LocalDate.fromString model.form.date, Form.validate model.form ) of
        ( Nothing, _ ) ->
            validationFailure "Enter a valid date in YYYY-MM-DD format." model

        ( _, Err message ) ->
            validationFailure message model

        ( Just date, Ok validated ) ->
            if model.form.saveToMyFoods then
                case Form.toCustomFoodRequest validated of
                    Ok request ->
                        ( { model | submit = SavingCustomFood }
                        , Cmd.none
                        , RequestCreateFood request
                        )

                    Err message ->
                        validationFailure message model

            else
                ( { model | submit = LoggingAdHoc }
                , Cmd.none
                , RequestAdHocLog (Form.toAdHocRequest date model.deviceTimezone validated)
                )


requestProductLog : String -> Model -> ( Model, Cmd Msg, OutMsg )
requestProductLog productId model =
    case ( LocalDate.fromString model.form.date, Form.validate model.form ) of
        ( Just date, Ok validated ) ->
            ( { model | submit = LoggingSavedFood productId }
            , Cmd.none
            , RequestProductLog
                (Form.toProductLogRequest date model.deviceTimezone productId validated)
            )

        ( Nothing, _ ) ->
            validationFailure "Enter a valid date in YYYY-MM-DD format." model

        ( _, Err message ) ->
            validationFailure message model


savedProductId : SubmitState -> Maybe String
savedProductId state =
    case state of
        LoggingSavedFood productId ->
            Just productId

        LogFailedAfterFoodSaved saved ->
            Just saved.productId

        _ ->
            Nothing


setDateIfBlank : String -> Form.Model -> Form.Model
setDateIfBlank date form =
    if String.isEmpty (String.trim form.date) then
        { form | date = date }

    else
        form


validationFailure : String -> Model -> ( Model, Cmd Msg, OutMsg )
validationFailure message model =
    ( { model | submit = SubmitFailed message }, Cmd.none, NoOp )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( model, Cmd.none, SessionExpired )

    else
        validationFailure (Client.displayError error) model


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view =
    viewWithOptionalNutrients True


viewForAi : Bool -> { model : Model, device : Device, theme : Theme } -> Element Msg
viewForAi =
    viewWithOptionalNutrients


viewWithOptionalNutrients :
    Bool
    -> { model : Model, device : Device, theme : Theme }
    -> Element Msg
viewWithOptionalNutrients showOptional { model, device, theme } =
    Ui.pageContainer device
        [ Ui.maybeErrorBanner theme (submitError model.submit)
        , Ui.formSection theme
            "Basic Info"
            [ Ui.input theme
                { label = "Food name"
                , value = model.form.name
                , onChange = NameChanged
                }
            , Ui.input theme
                { label = "Brand (optional)"
                , value = model.form.brand
                , onChange = BrandChanged
                }
            ]
        , Ui.formSection theme
            "Logged Portion"
            [ Typography.mutedParagraph theme
                "Describe the entire amount you are logging."
            , Ui.decimalInput theme
                { label = "Amount"
                , value = model.form.amount
                , onChange = AmountChanged
                }
            , unitDropdown theme device model
            ]
        , nutrientsSection showOptional theme device model
        , Ui.formSection theme
            "Log Details"
            [ Ui.input theme
                { label = "Date (YYYY-MM-DD)"
                , value = model.form.date
                , onChange = DateChanged
                }
            , mealSlotDropdown theme device model
            , Ui.input theme
                { label = "Notes (optional)"
                , value = model.form.notes
                , onChange = NotesChanged
                }
            ]
        , Ui.card theme
            ([ Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ Element.el [ Element.width Element.fill ]
                    (Typography.sectionTitle theme "Save to My Foods")
                , Ui.toggleSwitch theme
                    { isActive = model.form.saveToMyFoods
                    , onToggle = SaveToMyFoodsToggled
                    }
                ]
             , Typography.mutedParagraph theme
                "Save this as a reusable custom food before logging it."
             ]
                ++ (if model.form.saveToMyFoods then
                        [ Ui.decimalInput theme
                            { label = "Weight of this logged portion (g)"
                            , value = model.form.portionWeight
                            , onChange = PortionWeightChanged
                            }
                        ]

                    else
                        []
                   )
            )
        , Ui.textButton device
            theme
            { tone = Ui.Primary
            , width = Ui.FullWidth
            , label =
                case model.submit of
                    LogFailedAfterFoodSaved _ ->
                        "Retry logging"

                    _ ->
                        "Log Food"
            , onPress = SubmitClicked
            , submitState = Just (Ui.submittingOrIdle (isSubmitting model.submit))
            , submittingLabel = Just "Logging..."
            , trailing = Nothing
            }
        ]


nutrientsSection : Bool -> Theme -> Device -> Model -> Element Msg
nutrientsSection showOptional theme device model =
    Ui.section theme
        { header =
            Just
                (Element.column [ Element.spacing DesignTokens.space8 ]
                    [ Typography.subsectionTitle theme "Portion Nutrition"
                    , Typography.mutedCaption theme
                        ("Enter totals for the entire logged portion. Calories, protein, "
                            ++ "carbohydrates, and fat are required."
                        )
                    ]
                )
        , body =
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                (model.form.nutrients
                    |> List.indexedMap Tuple.pair
                    |> List.filter
                        (\( _, row ) -> showOptional || isCoreNutrient row.code)
                    |> List.map
                        (\( index, row ) -> nutrientRow theme device model index row)
                )
            ]
        , footer =
            Just
                (Ui.textButton device
                    theme
                    { tone = Ui.Ghost
                    , width = Ui.FullWidth
                    , label = "+ Add Nutrient"
                    , onPress = AddNutrient
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )
        }


isCoreNutrient : String -> Bool
isCoreNutrient code =
    List.member code [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]


nutrientRow : Theme -> Device -> Model -> Int -> Form.NutrientRow -> Element Msg
nutrientRow theme device model index row =
    let
        selector : Element Msg
        selector =
            Ui.selectDropdown device
                theme
                { label = "Nutrient"
                , selected = row.code
                , options =
                    ( "", "Select nutrient..." )
                        :: List.map (\item -> ( item.code, item.name )) model.nutrients
                , onChange = NutrientCodeChanged index
                , isOpen = model.nutrientOpen == Just index
                , onToggle = ToggleNutrient index
                }

        amountInput : Element Msg
        amountInput =
            Ui.decimalInputWithSuffix theme
                { label = "Amount for this portion"
                , text = row.amount
                , suffix =
                    if String.isEmpty row.unit then
                        "unit"

                    else
                        row.unit
                , onChange = NutrientAmountChanged index
                }

        removeButton : Element Msg
        removeButton =
            Element.el
                [ Element.width (Element.px 44)
                , Element.paddingEach
                    { top = DesignTokens.space16, right = 0, bottom = 0, left = 0 }
                ]
                (Ui.iconButton device
                    theme
                    { icon = Icon.Close
                    , title = "Remove nutrient"
                    , onPress = Just (RemoveNutrient index)
                    , tone = Ui.Danger
                    }
                )
    in
    if Ui.isSmall device then
        Element.column
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector
            , Element.row
                [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ amountInput, removeButton ]
            ]

    else
        Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ selector, amountInput, removeButton ]


unitDropdown : Theme -> Device -> Model -> Element Msg
unitDropdown theme device model =
    Ui.selectDropdown device
        theme
        { label = "Portion unit"
        , selected = model.form.unit
        , options = List.map (\unit -> ( unit.code, unit.name )) model.units
        , onChange = UnitChanged
        , isOpen = model.unitOpen
        , onToggle = ToggleUnit
        }


mealSlotDropdown : Theme -> Device -> Model -> Element Msg
mealSlotDropdown theme device model =
    Ui.selectDropdown device
        theme
        { label = "Meal"
        , selected = model.form.mealSlot
        , options =
            [ ( Nothing, "None" )
            , ( Just Breakfast, MealSlot.label Breakfast )
            , ( Just Lunch, MealSlot.label Lunch )
            , ( Just Dinner, MealSlot.label Dinner )
            , ( Just Snack, MealSlot.label Snack )
            , ( Just LateNightSnack, MealSlot.label LateNightSnack )
            ]
        , onChange = MealSlotChanged
        , isOpen = model.mealSlotOpen
        , onToggle = ToggleMealSlot
        }


submitError : SubmitState -> Maybe String
submitError state =
    case state of
        SubmitFailed message ->
            Just message

        LogFailedAfterFoodSaved saved ->
            Just saved.message

        _ ->
            Nothing


isSubmitting : SubmitState -> Bool
isSubmitting state =
    case state of
        AwaitingLocalContext ->
            True

        LoggingAdHoc ->
            True

        SavingCustomFood ->
            True

        LoggingSavedFood _ ->
            True

        _ ->
            False
