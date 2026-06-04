module Api.Result exposing (failure)

import Api.Client as Client


failure :
    { noOp : outMsg
    , sessionExpired : outMsg
    , applyError : String -> model -> model
    }
    -> Client.ApiError
    -> model
    -> ( model, Cmd msg, outMsg )
failure config error model =
    let
        updatedModel : model
        updatedModel =
            config.applyError (Client.displayError error) model
    in
    ( updatedModel
    , Cmd.none
    , if Client.isUnauthorized error then
        config.sessionExpired

      else
        config.noOp
    )
