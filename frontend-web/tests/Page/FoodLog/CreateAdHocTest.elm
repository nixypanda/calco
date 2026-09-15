module Page.FoodLog.CreateAdHocTest exposing (tests)

import Api.Client as Client
import Expect
import Page.FoodLog.AdHocForm as AdHocForm
import Page.FoodLog.CreateAdHoc as CreateAdHoc
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateAdHoc"
        [ test "save-off submission requests only an ad-hoc log" <|
            \_ ->
                CreateAdHoc.update CreateAdHoc.SubmitClicked validModel
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateAdHoc.RequestAdHocLog request ->
                                    Expect.equal
                                        ( request.name
                                        , request.quantity.amount
                                        , List.map .code request.nutrients
                                        )
                                        ( "Paneer wrap"
                                        , "1"
                                        , [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]
                                        )

                                _ ->
                                    Expect.fail "expected an ad-hoc log request"
                       )
        , test "save-on submission creates a custom food first" <|
            \_ ->
                CreateAdHoc.update CreateAdHoc.SubmitClicked saveModel
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateAdHoc.RequestCreateFood request ->
                                    Expect.equal request.defaultUnit (Just "serving")

                                _ ->
                                    Expect.fail "expected a custom-food request"
                       )
        , test "saved food is then logged through the product endpoint" <|
            \_ ->
                CreateAdHoc.update
                    (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" }))
                    { saveModel | submit = CreateAdHoc.SavingCustomFood }
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateAdHoc.RequestProductLog request ->
                                    Expect.equal request.item.id "food-1"

                                _ ->
                                    Expect.fail "expected a product log request"
                       )
        , test "a product-log failure retains the saved id for retry" <|
            \_ ->
                let
                    failed : CreateAdHoc.Model
                    failed =
                        CreateAdHoc.update
                            (CreateAdHoc.ProductLogCompleted (Err Client.NetworkError))
                            { saveModel
                                | submit = CreateAdHoc.LoggingSavedFood "food-1"
                            }
                            |> first
                in
                CreateAdHoc.update CreateAdHoc.SubmitClicked failed
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateAdHoc.RequestProductLog request ->
                                    Expect.equal request.item.id "food-1"

                                _ ->
                                    Expect.fail "retry should log the existing product"
                       )
        , test "missing route date requests local context" <|
            \_ ->
                let
                    form : AdHocForm.Model
                    form =
                        validModel.form
                in
                CreateAdHoc.update CreateAdHoc.SubmitClicked
                    { validModel | form = { form | date = "" } }
                    |> third
                    |> Expect.equal CreateAdHoc.RequestLocalContext
        ]


validModel : CreateAdHoc.Model
validModel =
    let
        model : CreateAdHoc.Model
        model =
            CreateAdHoc.init (Just "2026-09-14") Nothing

        form : AdHocForm.Model
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
    let
        form : AdHocForm.Model
        form =
            validModel.form
    in
    { validModel
        | form = { form | saveToMyFoods = True, portionWeight = "160" }
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
