module Support.Story exposing
    ( Journey
    , bind
    , finish
    , runSteps
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
