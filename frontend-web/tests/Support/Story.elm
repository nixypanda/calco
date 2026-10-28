module Support.Story exposing (runSteps, runStepsResult)

{-| Apply sequences of page messages to a model.

Page-specific setup, projections, and assertions stay next to their tests;
these helpers only remove fold boilerplate and make ignored required messages
visible.

-}


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
