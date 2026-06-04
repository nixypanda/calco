module Page.MealDetail exposing
    ( LogMealForm
    , Model
    , Msg(..)
    , OutMsg(..)
    , createMealLogRequest
    , init
    , uniqueProductIds
    , update
    , validPreviewAmount
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest)
import Api.Meals as Meals exposing (Meal, MealNutritionResponse)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef exposing (ItemRef)
import Data.Nutrition exposing (NutrientAmount)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Route exposing (Route(..))
import Ui


type alias LogMealForm =
    { amount : String
    , unit : String
    , nutrients : Maybe (List NutrientAmount)
    , previewToken : Int
    , previewLoading : Bool
    , logging : Bool
    , error : Maybe String
    }


type alias Model =
    { mealId : String
    , meal : Maybe Meal
    , productNames : List ( String, String )
    , units : List UnitItem
    , logForm : LogMealForm
    , nextPreviewToken : Int
    , error : Maybe String
    , confirmDeleteOpen : Bool
    , deleting : Bool
    , deleteError : Maybe String
    }


type Msg
    = MealLoaded (Result Client.ApiError Meal)
    | ProductDetailLoaded String (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | AmountChanged String
    | UnitChanged String
    | NutrientPreviewLoaded Int (Result Client.ApiError MealNutritionResponse)
    | LogClicked
    | LocalTimestampReceived String
    | LogCompleted (Result Client.ApiError FoodLog)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditClicked
    | BackClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestNutrientPreview String String String Int
    | RequestLocalTimestamp
    | RequestCreateLog CreateLogRequest
    | RequestDeleteMeal String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init mealId =
    ( { mealId = mealId
      , meal = Nothing
      , productNames = []
      , units = []
      , logForm =
            { amount = "100"
            , unit = "g"
            , nutrients = Nothing
            , previewToken = 0
            , previewLoading = False
            , logging = False
            , error = Nothing
            }
      , nextPreviewToken = 1
      , error = Nothing
      , confirmDeleteOpen = False
      , deleting = False
      , deleteError = Nothing
      }
    , RequestInitialData mealId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        MealLoaded result ->
            case result of
                Ok meal ->
                    ( { model | meal = Just meal, error = Nothing }, Cmd.none, requestProductNames (uniqueProductIds meal) )

                Err error ->
                    failure error model

        ProductDetailLoaded productId result ->
            case result of
                Ok product ->
                    ( { model | productNames = upsertName productId product.name model.productNames }, Cmd.none, nextProductNameRequest productId model )

                Err _ ->
                    ( model, Cmd.none, nextProductNameRequest productId model )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    previewAfterChange { model | units = response.items, error = Nothing }

                Err _ ->
                    previewAfterChange model

        AmountChanged amount ->
            previewAfterChange (mapLogForm (\form -> { form | amount = amount }) model)

        UnitChanged unit ->
            previewAfterChange (mapLogForm (\form -> { form | unit = unit }) model)

        NutrientPreviewLoaded token result ->
            if token /= model.logForm.previewToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( mapLogForm (\form -> { form | nutrients = Just response.nutrients, previewLoading = False, error = Nothing }) model, Cmd.none, NoOp )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( mapLogForm (\form -> { form | previewLoading = False, error = Just (Client.displayError error) }) model, Cmd.none, SessionExpired )

                        else
                            ( mapLogForm (\form -> { form | nutrients = Nothing, previewLoading = False, error = Just (Client.displayError error) }) model, Cmd.none, NoOp )

        LogClicked ->
            case validPreviewAmount model.logForm.amount of
                Just _ ->
                    ( mapLogForm (\form -> { form | logging = True, error = Nothing }) model, Cmd.none, RequestLocalTimestamp )

                Nothing ->
                    ( mapLogForm (\form -> { form | nutrients = Nothing, error = Just "Amount is required." }) model, Cmd.none, NoOp )

        LocalTimestampReceived loggedAt ->
            case createMealLogRequest loggedAt model.mealId model.logForm of
                Ok request ->
                    ( model, Cmd.none, RequestCreateLog request )

                Err _ ->
                    ( mapLogForm (\form -> { form | logging = False, error = Just "Amount is required." }) model, Cmd.none, NoOp )

        LogCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate (Diary Nothing) )

                Err error ->
                    if Client.isUnauthorized error then
                        ( mapLogForm (\form -> { form | logging = False, error = Just (Client.displayError error) }) model, Cmd.none, SessionExpired )

                    else
                        ( mapLogForm (\form -> { form | logging = False, error = Just (Client.displayError error) }) model, Cmd.none, NoOp )

        DeleteClicked ->
            ( { model | confirmDeleteOpen = True, deleteError = Nothing }, Cmd.none, NoOp )

        CancelDeleteClicked ->
            ( { model | confirmDeleteOpen = False, deleteError = Nothing }, Cmd.none, NoOp )

        ConfirmDeleteClicked ->
            ( { model | deleting = True, deleteError = Nothing }, Cmd.none, RequestDeleteMeal model.mealId )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate Meals )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | deleting = False, confirmDeleteOpen = True, deleteError = Just (Client.displayError error) }, Cmd.none, SessionExpired )

                    else
                        ( { model | deleting = False, confirmDeleteOpen = True, deleteError = Just (Client.displayError error) }, Cmd.none, NoOp )

        EditClicked ->
            ( model, Cmd.none, Navigate (MealEdit model.mealId) )

        BackClicked ->
            ( model, Cmd.none, Navigate Meals )


previewAfterChange : Model -> ( Model, Cmd Msg, OutMsg )
previewAfterChange model =
    case validPreviewAmount model.logForm.amount of
        Just _ ->
            let
                token : Int
                token =
                    model.nextPreviewToken

                form : LogMealForm
                form =
                    model.logForm
            in
            ( { model
                | nextPreviewToken = token + 1
                , logForm = { form | previewToken = token, previewLoading = True, nutrients = Nothing, error = Nothing }
              }
            , Cmd.none
            , RequestNutrientPreview model.mealId model.logForm.amount model.logForm.unit token
            )

        Nothing ->
            ( mapLogForm (\form -> { form | nutrients = Nothing, previewLoading = False, error = Nothing }) model, Cmd.none, NoOp )


mapLogForm : (LogMealForm -> LogMealForm) -> Model -> Model
mapLogForm change model =
    { model | logForm = change model.logForm }


startPreview : Model -> OutMsg
startPreview model =
    case validPreviewAmount model.logForm.amount of
        Just _ ->
            RequestNutrientPreview model.mealId model.logForm.amount model.logForm.unit model.logForm.previewToken

        Nothing ->
            NoOp


uniqueProductIds : Meal -> List String
uniqueProductIds meal =
    meal.components
        |> List.filterMap
            (\component ->
                if component.item.itemType == "product" then
                    Just component.item.id

                else
                    Nothing
            )
        |> List.foldl
            (\id ids ->
                if List.member id ids then
                    ids

                else
                    ids ++ [ id ]
            )
            []


validPreviewAmount : String -> Maybe Float
validPreviewAmount raw =
    case String.toFloat (String.trim raw) of
        Just amount ->
            if amount > 0 then
                Just amount

            else
                Nothing

        Nothing ->
            Nothing


createMealLogRequest : String -> String -> LogMealForm -> Result String CreateLogRequest
createMealLogRequest loggedAt mealId form =
    case validPreviewAmount form.amount of
        Just _ ->
            Ok
                { loggedAt = loggedAt
                , mealSlot = Nothing
                , item = { itemType = "meal", id = mealId }
                , quantity = { amount = String.trim form.amount, unit = String.trim form.unit }
                , notes = Nothing
                }

        Nothing ->
            Err "invalid amount"


requestProductNames : List String -> OutMsg
requestProductNames ids =
    ids
        |> List.head
        |> Maybe.map RequestProductDetail
        |> Maybe.withDefault NoOp


nextProductNameRequest : String -> Model -> OutMsg
nextProductNameRequest completedId model =
    case model.meal of
        Just meal ->
            uniqueProductIds meal
                |> List.filter (\id -> id /= completedId && not (List.any (\( existing, _ ) -> existing == id) model.productNames))
                |> List.head
                |> Maybe.map RequestProductDetail
                |> Maybe.withDefault NoOp

        Nothing ->
            NoOp


upsertName : String -> String -> List ( String, String ) -> List ( String, String )
upsertName id name names =
    if List.any (\( existing, _ ) -> existing == id) names then
        List.map
            (\( existing, value ) ->
                if existing == id then
                    ( id, name )

                else
                    ( existing, value )
            )
            names

    else
        names ++ [ ( id, name ) ]


nameFor : String -> Model -> String
nameFor id model =
    model.productNames
        |> List.filter (\( productId, _ ) -> productId == id)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault "Loading..."


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Element.column [ Element.width Element.fill, Element.spacing 16, Element.padding 24 ]
        [ Element.row [ Element.spacing 12 ]
            [ Ui.button "Back" BackClicked
            , Element.el [ Font.size 22, Font.bold ] (Element.text (Maybe.map .name model.meal |> Maybe.withDefault "Meal"))
            , Ui.button "Edit" EditClicked
            , Ui.button "Delete" DeleteClicked
            ]
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case model.meal of
            Just meal ->
                loadedView model meal

            Nothing ->
                Element.text "Loading meal..."
        ]


loadedView : Model -> Meal -> Element Msg
loadedView model meal =
    Element.column [ Element.width Element.fill, Element.spacing 16 ]
        [ case meal.notes of
            Just notes ->
                Element.el [ Font.color (Element.rgb255 107 114 128) ] (Element.text notes)

            Nothing ->
                Element.none
        , Element.el [ Font.size 18, Font.bold ] (Element.text "Components")
        , Element.column [ Element.width Element.fill, Element.spacing 8 ] (List.map (componentView model) meal.components)
        , logFormView model
        , confirmDeleteView model
        ]


componentView : Model -> Meals.MealComponent -> Element Msg
componentView model component =
    Element.row
        [ Element.width Element.fill
        , Element.spacing 12
        , Element.padding 12
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Element.el [ Font.bold ] (Element.text (nameFor component.item.id model))
        , Element.el [ Font.color (Element.rgb255 107 114 128) ] (Element.text (component.quantity.amount ++ " " ++ component.quantity.unit))
        ]


logFormView : Model -> Element Msg
logFormView model =
    Element.column [ Element.width Element.fill, Element.spacing 10 ]
        [ Element.el [ Font.size 18, Font.bold ] (Element.text "Log this meal")
        , Element.row [ Element.spacing 8 ]
            [ Ui.input "Amount" model.logForm.amount AmountChanged
            , Ui.input "Unit" model.logForm.unit UnitChanged
            ]
        , case model.logForm.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case model.logForm.nutrients of
            Just nutrients ->
                Element.column [ Element.spacing 4 ] (List.map nutrientView nutrients)

            Nothing ->
                Element.none
        , Ui.button
            (if model.logForm.logging then
                "Logging..."

             else
                "Log Meal"
            )
            LogClicked
        ]


nutrientView : NutrientAmount -> Element Msg
nutrientView nutrient =
    Element.row [ Element.spacing 8 ]
        [ Element.el [ Font.bold ] (Element.text nutrient.code)
        , Element.text (nutrient.amount ++ " " ++ nutrient.unit)
        ]


confirmDeleteView : Model -> Element Msg
confirmDeleteView model =
    if model.confirmDeleteOpen then
        Element.column [ Element.spacing 8, Element.padding 12, Background.color (Element.rgb255 254 242 242), Border.rounded 8 ]
            [ Element.el [ Font.bold ] (Element.text "Delete meal?")
            , case model.deleteError of
                Just message ->
                    Ui.errorBanner message

                Nothing ->
                    Element.none
            , Element.row [ Element.spacing 8 ]
                [ Ui.button "Cancel" CancelDeleteClicked
                , Ui.button
                    (if model.deleting then
                        "Deleting..."

                     else
                        "Confirm Delete"
                    )
                    ConfirmDeleteClicked
                ]
            ]

    else
        Element.none
