module Data.Category exposing (formatInput, parseInput)

import Lib.Text as Text


parseInput : String -> List String
parseInput raw =
    Text.commaSeparatedUniqueLower raw


formatInput : List String -> String
formatInput categories =
    String.join ", " categories
