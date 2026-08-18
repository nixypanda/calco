module StoreTest exposing (tests)

import Dict exposing (Dict)
import Expect
import Lib.Loadable exposing (Loadable(..))
import Store exposing (Store)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Store"
        [ test "reset advances the session generation and clears cached data" <|
            \_ ->
                let
                    empty : Store
                    empty =
                        Store.empty

                    populated : Store
                    populated =
                        { empty
                            | generation = 4
                            , nextRequestId = 9
                            , diaryLogs = Dict.singleton "2026-08-18" Loading
                            , diaryLogRequestIds = Dict.singleton "2026-08-18" 9
                            , preferences = Loading
                        }

                    reset : Store
                    reset =
                        Store.reset populated
                in
                Expect.all
                    [ \store -> Expect.equal 5 store.generation
                    , \store -> Expect.equal 0 store.nextRequestId
                    , \store -> Expect.equal Dict.empty store.diaryLogs
                    , \store -> Expect.equal Dict.empty store.diaryLogRequestIds
                    , \store -> Expect.equal NotAsked store.preferences
                    ]
                    reset
        , test "only the current session and request token can update an entry" <|
            \_ ->
                let
                    empty : Store
                    empty =
                        Store.empty

                    store : Store
                    store =
                        { empty | generation = 3 }

                    requests : Dict String Int
                    requests =
                        Dict.singleton "2026-08-18" 7
                in
                Expect.all
                    [ \_ ->
                        Store.isCurrentRequest 3 7 "2026-08-18" store requests
                            |> Expect.equal True
                    , \_ ->
                        Store.isCurrentRequest 2 7 "2026-08-18" store requests
                            |> Expect.equal False
                    , \_ ->
                        Store.isCurrentRequest 3 6 "2026-08-18" store requests
                            |> Expect.equal False
                    ]
                    ()
        ]
