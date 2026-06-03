module Loadable exposing (Loadable(..))


type Loadable error value
    = NotAsked
    | Loading
    | Failure error
    | Success value
