module Version exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , subscriptions
    , update
    )

import Api.Client as Client
import Browser.Events
import Json.Decode as Decode
import Task
import Time


type alias Model =
    { currentVersion : Maybe String
    , updateAvailable : Bool
    , versionError : Maybe String
    }


type Msg
    = GotVersionCheck (Result Client.ApiError String)
    | GotVersionCheckTime Time.Posix
    | CheckForUpdate
    | ReloadPageRequested
    | NoOp


type OutMsg
    = NoOutMsg
    | ReloadPage


init : ( Model, Cmd Msg )
init =
    ( { currentVersion = Nothing
      , updateAvailable = False
      , versionError = Nothing
      }
    , Task.perform GotVersionCheckTime Time.now
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        GotVersionCheck result ->
            case result of
                Ok version ->
                    let
                        isNew : Bool
                        isNew =
                            case model.currentVersion of
                                Nothing ->
                                    False

                                Just current ->
                                    current /= version
                    in
                    ( { model
                        | currentVersion = Just version
                        , updateAvailable = isNew && model.currentVersion /= Nothing
                        , versionError = Nothing
                      }
                    , Cmd.none
                    , NoOutMsg
                    )

                Err error ->
                    ( { model | versionError = Just (Client.displayError error) }
                    , Cmd.none
                    , NoOutMsg
                    )

        GotVersionCheckTime posix ->
            ( model, fetchVersion (Time.posixToMillis posix), NoOutMsg )

        CheckForUpdate ->
            ( model, Task.perform GotVersionCheckTime Time.now, NoOutMsg )

        ReloadPageRequested ->
            ( model, Cmd.none, ReloadPage )

        NoOp ->
            ( model, Cmd.none, NoOutMsg )


subscriptions : Sub Msg
subscriptions =
    Browser.Events.onVisibilityChange
        (\visibility ->
            case visibility of
                Browser.Events.Visible ->
                    CheckForUpdate

                Browser.Events.Hidden ->
                    NoOp
        )


fetchVersion : Int -> Cmd Msg
fetchVersion timestamp =
    Client.get
        ("/version.json?v=" ++ String.fromInt timestamp)
        versionDecoder
        GotVersionCheck


versionDecoder : Decode.Decoder String
versionDecoder =
    Decode.field "version" Decode.string
