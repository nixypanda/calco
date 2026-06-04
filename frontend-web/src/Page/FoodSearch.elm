module Page.FoodSearch exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , isBarcodeVisible
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (SearchRequest, SearchResult)
import Data.MealSlot exposing (MealSlot)
import Element exposing (Element)
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Loadable exposing (Loadable(..))
import Process
import Route exposing (Route(..))
import Task
import Ui


type alias Model =
    { query : String
    , searchToken : Int
    , results : Loadable Client.ApiError (List SearchResult)
    , mealSlot : Maybe MealSlot
    }


type Msg
    = QueryChanged String
    | DebounceElapsed Int String
    | SearchCompleted Int (Result Client.ApiError Foods.SearchResponse)
    | ResultClicked String
    | CreateCustomFoodClicked
    | BackClicked


type OutMsg
    = NoOp
    | RequestSearch Int SearchRequest
    | Navigate Route
    | SessionExpired


init : Maybe MealSlot -> Model
init mealSlot =
    { query = ""
    , searchToken = 0
    , results = NotAsked
    , mealSlot = mealSlot
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        QueryChanged rawQuery ->
            let
                query : String
                query =
                    rawQuery

                trimmed : String
                trimmed =
                    String.trim query
            in
            if String.isEmpty trimmed then
                ( { model
                    | query = query
                    , results = NotAsked
                    , searchToken = model.searchToken + 1
                  }
                , Cmd.none
                , NoOp
                )

            else
                let
                    nextToken : Int
                    nextToken =
                        model.searchToken + 1
                in
                ( { model | query = query, searchToken = nextToken, results = Loading }
                , debounce nextToken trimmed
                , NoOp
                )

        DebounceElapsed token query ->
            if token == model.searchToken then
                ( model, Cmd.none, RequestSearch token { query = query } )

            else
                ( model, Cmd.none, NoOp )

        SearchCompleted token result ->
            if token /= model.searchToken then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model | results = Success response.items }, Cmd.none, NoOp )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | results = Failure error }, Cmd.none, SessionExpired )

                        else
                            ( { model | results = Failure error }, Cmd.none, NoOp )

        ResultClicked id ->
            ( model, Cmd.none, Navigate (FoodDetail id model.mealSlot) )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (Diary Nothing) )


debounce : Int -> String -> Cmd Msg
debounce token query =
    Process.sleep 300
        |> Task.perform (\_ -> DebounceElapsed token query)


isBarcodeVisible : String -> SearchResult -> Bool
isBarcodeVisible query item =
    item.barcode /= Nothing && isNumeric (String.trim query)


isNumeric : String -> Bool
isNumeric value =
    not (String.isEmpty value)
        && String.all Char.isDigit value


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ Ui.pageHeader "Search Foods" (Just BackClicked)
        , Ui.input "Search for a food" model.query QueryChanged
        , bodyView model
        ]


bodyView : Model -> Element Msg
bodyView model =
    case model.results of
        NotAsked ->
            Ui.emptyState "Search for a food to get started."

        Loading ->
            Ui.loading "Searching foods..."

        Failure error ->
            Element.column [ Element.width Element.fill, Element.spacing 12 ]
                [ Ui.errorBanner (Client.displayError error)
                , Ui.emptyState "No foods found. Try a different search."
                ]

        Success items ->
            if List.isEmpty items then
                Element.column [ Element.width Element.fill, Element.spacing 12 ]
                    [ Ui.emptyState "No foods found. Try a different search."
                    , Ui.button "Create Custom Food" CreateCustomFoodClicked
                    ]

            else
                Ui.card (List.map (resultRow model.query) items)


resultRow : String -> SearchResult -> Element Msg
resultRow query item =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        ]
        { onPress = Just (ResultClicked item.id)
        , label =
            Element.column [ Element.width Element.fill, Element.spacing 4 ]
                [ Element.el [ Font.medium ] (Element.text item.name)
                , Element.el
                    [ Font.size 13
                    , Font.color Ui.mutedColor
                    ]
                    (Element.text (metaText query item))
                ]
        }


metaText : String -> SearchResult -> String
metaText query item =
    [ item.brand
    , if isBarcodeVisible query item then
        item.barcode

      else
        Nothing
    , Maybe.map (\kcal -> kcal ++ " kcal per 100 g") item.energyKcalPer100g
    ]
        |> List.filterMap identity
        |> String.join " - "
