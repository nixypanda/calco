module Page.MealDetail exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , uniqueProductIds
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Meals as Meals exposing (Meal, MealNutritionResponse)
import Data.Nutrition exposing (NutrientAmount)
import Data.Units as Units
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Route exposing (Route(..))
import Ui
import View.Nutrients


type alias Model =
    { mealId : String
    , meal : Maybe Meal
    , productNames : List ( String, String )
    , amount : String
    , unit : String
    , units : List UnitItem
    , unitOpen : Bool
    , nutrients : Maybe (List NutrientAmount)
    , nutritionLoading : Bool
    , nutritionError : Maybe String
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
    | ToggleUnitDropdown
    | NutrientPreviewLoaded (Result Client.ApiError MealNutritionResponse)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestNutrientPreview String String String
    | RequestDeleteMeal String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init mealId =
    ( { mealId = mealId
      , meal = Nothing
      , productNames = []
      , amount = "100"
      , unit = "g"
      , units = fallbackUnits
      , unitOpen = False
      , nutrients = Nothing
      , nutritionLoading = True
      , nutritionError = Nothing
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
                    ( { model | meal = Just meal, error = Nothing }
                    , Cmd.none
                    , requestProductNames (uniqueProductIds meal)
                    )

                Err error ->
                    failure error model

        ProductDetailLoaded productId result ->
            case result of
                Ok product ->
                    ( { model
                        | productNames =
                            upsertName productId product.name model.productNames
                      }
                    , Cmd.none
                    , nextProductNameRequest productId model
                    )

                Err _ ->
                    ( model, Cmd.none, nextProductNameRequest productId model )

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | units =
                            if List.isEmpty response.items then
                                fallbackUnits

                            else
                                response.items
                        , error = Nothing
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err _ ->
                    ( { model | units = fallbackUnits }, Cmd.none, NoOp )

        AmountChanged value ->
            requestNutritionFor
                { model
                    | amount = value
                    , unitOpen = False
                    , nutritionError = Nothing
                }

        UnitChanged value ->
            requestNutritionFor
                { model
                    | unit = value
                    , unitOpen = False
                    , nutritionError = Nothing
                }

        ToggleUnitDropdown ->
            ( { model | unitOpen = not model.unitOpen }, Cmd.none, NoOp )

        NutrientPreviewLoaded result ->
            case result of
                Ok response ->
                    if
                        response.quantity.amount
                            == model.amount
                            && response.quantity.unit
                            == model.unit
                    then
                        ( { model
                            | nutrients = Just response.nutrients
                            , nutritionLoading = False
                            , nutritionError = Nothing
                          }
                        , Cmd.none
                        , NoOp
                        )

                    else
                        ( model, Cmd.none, NoOp )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | nutrients = Nothing
                            , nutritionLoading = False
                            , nutritionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | nutrients = Nothing
                            , nutritionLoading = False
                            , nutritionError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        DeleteClicked ->
            ( { model | confirmDeleteOpen = True, deleteError = Nothing }, Cmd.none, NoOp )

        CancelDeleteClicked ->
            ( { model | confirmDeleteOpen = False, deleteError = Nothing }, Cmd.none, NoOp )

        ConfirmDeleteClicked ->
            ( { model | deleting = True, deleteError = Nothing }
            , Cmd.none
            , RequestDeleteMeal model.mealId
            )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate Meals )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model
                            | deleting = False
                            , confirmDeleteOpen = True
                            , deleteError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model
                            | deleting = False
                            , confirmDeleteOpen = True
                            , deleteError = Just (Client.displayError error)
                          }
                        , Cmd.none
                        , NoOp
                        )

        EditClicked ->
            ( model, Cmd.none, Navigate (MealEdit model.mealId) )


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
                |> List.filter
                    (\id ->
                        id
                            /= completedId
                            && not
                                (List.any
                                    (\( existing, _ ) -> existing == id)
                                    model.productNames
                                )
                    )
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


requestNutritionFor : Model -> ( Model, Cmd Msg, OutMsg )
requestNutritionFor model =
    case String.toFloat model.amount of
        Just amount ->
            if amount > 0 then
                ( { model | nutritionLoading = True }
                , Cmd.none
                , RequestNutrientPreview model.mealId model.amount model.unit
                )

            else
                clearNutritionPreview model

        Nothing ->
            clearNutritionPreview model


clearNutritionPreview : Model -> ( Model, Cmd Msg, OutMsg )
clearNutritionPreview model =
    ( { model
        | nutrients = Nothing
        , nutritionLoading = False
        , nutritionError = Nothing
      }
    , Cmd.none
    , NoOp
    )


fallbackUnits : List UnitItem
fallbackUnits =
    [ { code = "g", name = "g", kind = "mass" } ]


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | error = Just (Client.displayError error) }, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ Element.row [ Element.width Element.fill, Element.spacing 12 ]
            [ Element.el
                [ Ui.heading1, Font.bold ]
                (Element.text (Maybe.map .name model.meal |> Maybe.withDefault "Meal"))
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
                Ui.loading "Loading meal..."
        ]


loadedView : Model -> Meal -> Element Msg
loadedView model meal =
    Element.column [ Element.width Element.fill, Element.spacing 16 ]
        [ case meal.notes of
            Just notes ->
                Ui.mutedText notes

            Nothing ->
                Element.none
        , Ui.sectionHeader "Components"
        , Element.column
            [ Element.width Element.fill, Element.spacing 8 ]
            (List.map (componentView model) meal.components)
        , nutritionView model
        , confirmDeleteView model
        ]


componentView : Model -> Meals.MealComponent -> Element Msg
componentView model component =
    Element.row
        [ Element.width Element.fill
        , Element.spacing 12
        , Element.padding 12
        , Background.color Ui.cardBg
        , Border.rounded 8
        , Border.width 1
        , Border.color Ui.borderGray
        ]
        [ Element.el [ Font.bold ] (Element.text (nameFor component.item.id model))
        , Element.el
            [ Font.color Ui.mutedColor ]
            (Element.text (component.quantity.amount ++ " " ++ component.quantity.unit))
        ]


nutritionView : Model -> Element Msg
nutritionView model =
    Element.column [ Element.width Element.fill, Element.spacing 10 ]
        [ Ui.sectionHeader "Nutrition"
        , Ui.card
            [ Ui.input "Amount" model.amount AmountChanged
            , Ui.selectDropdown
                { label = "Unit"
                , selected = model.unit
                , options = model.units |> Units.ensureSelected model.unit |> Units.options
                , onChange = UnitChanged
                , isOpen = model.unitOpen
                , onToggle = ToggleUnitDropdown
                }
            ]
        , if model.nutritionLoading then
            Ui.loading "Loading nutrition..."

          else
            Element.none
        , case model.nutritionError of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , case model.nutrients of
            Just nutrients ->
                Element.column [ Element.width Element.fill, Element.spacing 8 ]
                    [ View.Nutrients.nutrientsTable nutrients
                    , Ui.card
                        [ Ui.sectionHeader "Macro Breakdown"
                        , View.Nutrients.macroBreakdownView nutrients
                        ]
                    ]

            Nothing ->
                Element.none
        ]


confirmDeleteView : Model -> Element Msg
confirmDeleteView model =
    if model.confirmDeleteOpen then
        Element.column
            [ Element.spacing 8
            , Element.padding 12
            , Background.color Ui.dangerBg
            , Border.rounded 8
            ]
            [ Element.el [ Font.bold ] (Element.text "Delete meal?")
            , case model.deleteError of
                Just message ->
                    Ui.errorBanner message

                Nothing ->
                    Element.none
            , Element.row [ Element.spacing 8 ]
                [ Ui.button "Cancel" CancelDeleteClicked
                , Ui.dangerButton
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
