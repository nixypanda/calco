module Page.FoodLog.CreateAdHoc exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SubmitState(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods exposing (CreateFoodRequest, CreateFoodResponse, UnitItem)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Data.FoodLog exposing (FoodLog)
import Data.LocalContext exposing (LocalContext)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Element exposing (Device, Element)
import Lib.Date as LocalDate
import Page.FoodLog.AdHocForm as Form
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type alias Model =
    { form : Form.Model
    , units : List UnitItem
    , unitOpen : Bool
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
    , unitOpen = False
    , mealSlotOpen = False
    , deviceTimezone = Nothing
    , submit = SubmitIdle
    }


type Msg
    = UnitsLoaded (Result Client.ApiError Api.Foods.UnitListResponse)
    | NameChanged String
    | BrandChanged String
    | AmountChanged String
    | UnitChanged String
    | ToggleUnit
    | MealSlotChanged (Maybe MealSlot)
    | ToggleMealSlot
    | DateChanged String
    | CaloriesChanged String
    | ProteinChanged String
    | CarbohydratesChanged String
    | FatChanged String
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

        NameChanged value ->
            changed (\form -> { form | name = value }) model

        BrandChanged value ->
            changed (\form -> { form | brand = value }) model

        AmountChanged value ->
            changed (\form -> { form | amount = value }) model

        UnitChanged value ->
            changed (\form -> { form | unit = value }) { model | unitOpen = False }

        ToggleUnit ->
            ( { model | unitOpen = not model.unitOpen, mealSlotOpen = False }
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

        CaloriesChanged value ->
            changed (\form -> { form | calories = value }) model

        ProteinChanged value ->
            changed (\form -> { form | protein = value }) model

        CarbohydratesChanged value ->
            changed (\form -> { form | carbohydrates = value }) model

        FatChanged value ->
            changed (\form -> { form | fat = value }) model

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
view { model, device, theme } =
    Ui.pageContainer device
        [ Ui.maybeErrorBanner theme (submitError model.submit)
        , Ui.card theme
            [ Typography.sectionTitle theme "Logged portion"
            , Typography.mutedParagraph theme
                "Enter nutrition totals for the entire amount you are logging."
            , Ui.input theme
                { label = "Food name"
                , value = model.form.name
                , onChange = NameChanged
                }
            , Ui.input theme
                { label = "Brand (optional)"
                , value = model.form.brand
                , onChange = BrandChanged
                }
            , Ui.decimalInput theme
                { label = "Amount"
                , value = model.form.amount
                , onChange = AmountChanged
                }
            , unitDropdown theme device model
            , Ui.input theme
                { label = "Date (YYYY-MM-DD)"
                , value = model.form.date
                , onChange = DateChanged
                }
            , mealSlotDropdown theme device model
            , Ui.decimalInput theme
                { label = "Calories for this portion (kcal)"
                , value = model.form.calories
                , onChange = CaloriesChanged
                }
            , Ui.decimalInput theme
                { label = "Protein for this portion (g)"
                , value = model.form.protein
                , onChange = ProteinChanged
                }
            , Ui.decimalInput theme
                { label = "Carbohydrates for this portion (g)"
                , value = model.form.carbohydrates
                , onChange = CarbohydratesChanged
                }
            , Ui.decimalInput theme
                { label = "Fat for this portion (g)"
                , value = model.form.fat
                , onChange = FatChanged
                }
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
