module Main exposing (main)

import Html exposing (Html, div, h1, p, text)
import Html.Attributes exposing (attribute, class)
import Json.Decode as Decode


main : Html msg
main =
    div [ class "app", attribute "data-runtime-dependency" jsonDependencyMarker ]
        [ h1 [] [ text "Hello, Elm!" ]
        , p [] [ text "CalCo frontend-web is running." ]
        ]


jsonDependencyMarker : String
jsonDependencyMarker =
    Decode.decodeString (Decode.succeed "elm/json") "null"
        |> Result.withDefault "elm/json"
