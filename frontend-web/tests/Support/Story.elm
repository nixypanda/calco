module Support.Story exposing
    ( Journey
    , bind
    , finish
    , runSteps
    , runStepsResult
    , start
    , step
    )

{-| Apply sequences of page messages to a model.

Page-specific setup, projections, and assertions stay next to their tests;
these helpers only remove fold boilerplate and make ignored required messages
visible.

-}

import Expect


runSteps : (msg -> model -> model) -> List msg -> model -> model
runSteps stepFn messages model =
    List.foldl (\message current -> stepFn message current) model messages


{-| Like `runSteps`, but a message the page ignored aborts the sequence.
Intentional stale completions should use their own helper so they are not
confused with a broken required step.
-}
runStepsResult :
    (msg -> model -> Maybe ( model, out ))
    -> List msg
    -> model
    -> Result String ( model, List out )
runStepsResult stepFn messages model =
    let
        go : List msg -> model -> List out -> Result String ( model, List out )
        go remaining current outs =
            case remaining of
                [] ->
                    Ok ( current, List.reverse outs )

                message :: rest ->
                    case stepFn message current of
                        Just ( next, out ) ->
                            go rest next (out :: outs)

                        Nothing ->
                            Err "a required page message was ignored"
    in
    go messages model []


{-| A page story as a linear pipeline. `bind` handles the step whose message
depends on the previous `OutMsg`; `finish` makes one assertion on the final
state.
-}
type Journey model out
    = Journey (Result String ( model, out ))


start : ( model, out ) -> Journey model out
start ( model, out ) =
    Journey (Ok ( model, out ))


step :
    (msg -> model -> ( model, out ))
    -> msg
    -> Journey model out
    -> Journey model out
step update msg (Journey state) =
    Journey
        (state
            |> Result.map (\( model, _ ) -> update msg model)
        )


bind :
    (msg -> model -> ( model, out ))
    -> (out -> Result String msg)
    -> Journey model out
    -> Journey model out
bind update toMsg (Journey state) =
    Journey
        (state
            |> Result.andThen
                (\( model, out ) ->
                    toMsg out
                        |> Result.map (\msg -> update msg model)
                )
        )


finish :
    (( model, out ) -> Expect.Expectation)
    -> Journey model out
    -> Expect.Expectation
finish assertion (Journey state) =
    case state of
        Ok pair ->
            assertion pair

        Err message ->
            Expect.fail message
