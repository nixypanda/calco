module Page.FoodLog.CreateAdHocTest exposing (tests)

import Api.Client as Client
import Component.FoodEditor as Editor
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.FoodLog.CreateAdHoc as CreateAdHoc
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateAdHoc"
        [ test "saving off logs an ad-hoc entry with the entered nutrition" <|
            \_ ->
                out CreateAdHoc.SubmitClicked validModel
                    |> adHocPayload
                    |> Expect.equal
                        (Just
                            { name = "Paneer wrap"
                            , amount = "1"
                            , nutrients = [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]
                            }
                        )
        , test "saving on creates the custom food and then logs the saved product" <|
            \_ ->
                let
                    afterSubmit : CreateAdHoc.Model
                    afterSubmit =
                        step CreateAdHoc.SubmitClicked saveModel

                    afterFood : CreateAdHoc.Model
                    afterFood =
                        step (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" })) afterSubmit
                in
                { food =
                    out CreateAdHoc.SubmitClicked saveModel
                        |> requestDefaultUnit
                , product =
                    out (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" })) afterSubmit
                        |> requestProductId
                , loggedFoodId = savedProductId afterFood
                }
                    |> Expect.equal
                        { food = Just "serving"
                        , product = Just "food-1"
                        , loggedFoodId = Just "food-1"
                        }
        , test "a failed product log after saving the food retries the same product" <|
            \_ ->
                let
                    failed : CreateAdHoc.Model
                    failed =
                        saveModel
                            |> step CreateAdHoc.SubmitClicked
                            |> step (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" }))
                            |> step (CreateAdHoc.ProductLogCompleted (Err Client.NetworkError))
                in
                Expect.all
                    [ \_ ->
                        out CreateAdHoc.SubmitClicked failed
                            |> requestProductId
                            |> Expect.equal (Just "food-1")
                    , \_ ->
                        submitError failed
                            |> Expect.equal
                                (Just "Food was saved to My Foods, but it could not be logged.")
                    ]
                    ()
        , test "a missing diary date asks the host for the device context" <|
            \_ ->
                validModel
                    |> step (CreateAdHoc.FormMsg (Editor.LogDateChanged ""))
                    |> out CreateAdHoc.SubmitClicked
                    |> Expect.equal CreateAdHoc.RequestLocalContext
        ]



-- PROJECTIONS


type alias AdHocPayload =
    { name : String, amount : String, nutrients : List String }


adHocPayload : CreateAdHoc.OutMsg -> Maybe AdHocPayload
adHocPayload outMsg =
    case outMsg of
        CreateAdHoc.RequestAdHocLog request ->
            Just
                { name = request.name
                , amount = request.quantity.amount
                , nutrients = List.map .code request.nutrients
                }

        _ ->
            Nothing


requestDefaultUnit : CreateAdHoc.OutMsg -> Maybe String
requestDefaultUnit outMsg =
    case outMsg of
        CreateAdHoc.RequestCreateFood request ->
            request.defaultUnit

        _ ->
            Nothing


requestProductId : CreateAdHoc.OutMsg -> Maybe String
requestProductId outMsg =
    case outMsg of
        CreateAdHoc.RequestProductLog request ->
            Just request.item.id

        _ ->
            Nothing


savedProductId : CreateAdHoc.Model -> Maybe String
savedProductId model =
    case model.submit of
        CreateAdHoc.LoggingSavedFood productId ->
            Just productId

        CreateAdHoc.LogFailedAfterFoodSaved saved ->
            Just saved.productId

        _ ->
            Nothing


submitError : CreateAdHoc.Model -> Maybe String
submitError model =
    case model.submit of
        CreateAdHoc.SubmitFailed message ->
            Just message

        CreateAdHoc.LogFailedAfterFoodSaved saved ->
            Just saved.message

        _ ->
            Nothing


step : CreateAdHoc.Msg -> CreateAdHoc.Model -> CreateAdHoc.Model
step msg model =
    first (CreateAdHoc.update msg model)


out : CreateAdHoc.Msg -> CreateAdHoc.Model -> CreateAdHoc.OutMsg
out msg model =
    third (CreateAdHoc.update msg model)


validModel : CreateAdHoc.Model
validModel =
    let
        model : CreateAdHoc.Model
        model =
            CreateAdHoc.init (Just (date "2026-09-14")) Nothing

        form : Editor.FormModel
        form =
            model.form
    in
    { model
        | form =
            { form
                | name = "Paneer wrap"
                , nutrients =
                    [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
                    , { code = "PROTEIN_G", amount = "24", unit = "g" }
                    , { code = "CARBS_G", amount = "48", unit = "g" }
                    , { code = "FAT_G", amount = "25", unit = "g" }
                    ]
            }
    }


saveModel : CreateAdHoc.Model
saveModel =
    validModel
        |> step (CreateAdHoc.FormMsg Editor.LogPersistenceToggled)
        |> step (CreateAdHoc.FormMsg (Editor.PortionWeightChanged "160"))


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            case LocalDate.fromParts 1970 1 1 of
                Just fallback ->
                    fallback

                Nothing ->
                    date raw
