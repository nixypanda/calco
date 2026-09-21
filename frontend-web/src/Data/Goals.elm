module Data.Goals exposing
    ( GoalSnapshot
    , GoalSource(..)
    , GoalStatus
    , GoalTargets
    , decoder
    , statusOf
    )

import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)


type GoalSource
    = Default
    | Saved


type alias GoalTargets =
    { calorieTarget : Float, proteinTargetG : Float, carbsTargetG : Float, fatTargetG : Float }


type alias GoalSnapshot =
    { requestedDate : LocalDate
    , effectiveFrom : Maybe LocalDate
    , source : GoalSource
    , targets : GoalTargets
    }


type alias GoalStatus =
    { source : GoalSource, effectiveFrom : Maybe LocalDate }


statusOf : GoalSnapshot -> GoalStatus
statusOf snapshot =
    { source = snapshot.source, effectiveFrom = snapshot.effectiveFrom }


decoder : Decoder GoalSnapshot
decoder =
    Decode.map4 GoalSnapshot
        (Decode.field "requested_date" LocalDate.decoder)
        (Decode.field "effective_from" (Decode.nullable LocalDate.decoder))
        (Decode.field "source" sourceDecoder)
        targetsDecoder


targetsDecoder : Decoder GoalTargets
targetsDecoder =
    Decode.map4 GoalTargets
        (Decode.field "calorie_target" decimalStringDecoder)
        (Decode.field "protein_target_g" decimalStringDecoder)
        (Decode.field "carbs_target_g" decimalStringDecoder)
        (Decode.field "fat_target_g" decimalStringDecoder)


sourceDecoder : Decoder GoalSource
sourceDecoder =
    Decode.string
        |> Decode.andThen
            (\value ->
                case value of
                    "default" ->
                        Decode.succeed Default

                    "saved" ->
                        Decode.succeed Saved

                    _ ->
                        Decode.fail ("Invalid goal source: " ++ value)
            )


decimalStringDecoder : Decoder Float
decimalStringDecoder =
    Decode.oneOf
        [ Decode.float
        , Decode.string
            |> Decode.andThen
                (\raw ->
                    case String.toFloat raw of
                        Just value ->
                            Decode.succeed value

                        Nothing ->
                            Decode.fail ("Invalid decimal string: " ++ raw)
                )
        ]
