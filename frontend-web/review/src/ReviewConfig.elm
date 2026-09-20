module ReviewConfig exposing (config)

import NoDebug.Log
import NoDebug.TodoOrToString
import NoExposingEverything
import NoInconsistentAliases
import NoImportingEverything
import NoMissingSubscriptionsCall
import NoMissingTypeAnnotation
import NoMissingTypeAnnotationInLetIn
import NoMissingTypeExpose
import NoModuleOnExposedNames
import NoRedundantlyQualifiedType
import NoRecursiveUpdate
import NoSimpleLetBody
import NoUnused.CustomTypeConstructorArgs
import NoUnused.CustomTypeConstructors
import NoUnused.Dependencies
import NoUnused.Exports
import NoUnused.Modules
import NoUnused.Parameters
import NoUnused.Patterns
import NoUnused.Variables
import NoUnnecessaryTrailingUnderscore
import NoUselessSubscriptions
import Review.Rule exposing (Rule)
import Simplify


config : List Rule
config =
    [ NoDebug.Log.rule
    , NoDebug.TodoOrToString.rule
    , NoExposingEverything.rule
    , NoInconsistentAliases.config
        [ ( "Browser.Navigation", "Nav" )
        , ( "Data.Auth", "Auth" )
        , ( "Data.ItemNameLookup", "ItemNameLookup" )
        , ( "Data.Search", "Search" )
        , ( "Data.User", "User" )
        , ( "Element.Background", "Background" )
        , ( "Element.Border", "Border" )
        , ( "Element.Font", "Font" )
        , ( "Element.Input", "Input" )
        , ( "Element.Region", "Region" )
        , ( "Json.Decode", "Decode" )
        , ( "Json.Encode", "Encode" )
        , ( "Lib.Date", "LocalDate" )
        , ( "Lib.Json", "Json" )
        , ( "Lib.ListExtra", "ListExtra" )
        , ( "Lib.Number", "Number" )
        , ( "Lib.Text", "Text" )
        , ( "Url.Builder", "Builder" )
        , ( "Url.Parser", "Parser" )
        , ( "Url.Parser.Query", "Query" )
        ]
        |> NoInconsistentAliases.rule
    , NoImportingEverything.rule []
    , NoMissingTypeAnnotation.rule
    , NoMissingTypeAnnotationInLetIn.rule
    , NoMissingTypeExpose.rule
    , NoModuleOnExposedNames.rule
    , NoRedundantlyQualifiedType.rule
    , NoUnused.CustomTypeConstructorArgs.rule
    , NoUnused.CustomTypeConstructors.rule []
    , NoUnused.Dependencies.rule
    , NoUnused.Exports.rule
    , NoUnused.Modules.rule
    , NoUnused.Parameters.rule
    , NoUnused.Patterns.rule
    , NoSimpleLetBody.rule
    , NoUnnecessaryTrailingUnderscore.rule
    , NoUnused.Variables.rule
    , Simplify.rule Simplify.defaults
    , NoMissingSubscriptionsCall.rule
    , NoRecursiveUpdate.rule
    , NoUselessSubscriptions.rule
    ]
        |> List.map (Review.Rule.ignoreErrorsForDirectories [ "generated" ])
