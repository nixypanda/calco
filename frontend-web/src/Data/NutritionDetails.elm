module Data.NutritionDetails exposing
    ( Coverage(..)
    , GuidanceKind(..)
    , Nutrient
    , NutrientSection(..)
    , NutrientStatus(..)
    , NutritionDetails
    , Reference
    , decoder
    , isDangerous
    , progressPercent
    )

import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json


type alias NutritionDetails =
    { date : LocalDate, reference : Reference, loggedItems : Int, nutrients : List Nutrient }


type alias Reference =
    { code : String
    , name : String
    , authority : String
    , jurisdiction : String
    , populationLabel : String
    , sourceUrl : String
    }


type alias Nutrient =
    { code : String
    , name : String
    , section : NutrientSection
    , knownAmount : Maybe Float
    , unit : String
    , referenceAmount : Maybe Float
    , guidanceKind : GuidanceKind
    , itemsWithData : Int
    , coverage : Coverage
    , status : NutrientStatus
    }


type NutrientSection
    = Overview
    | Carbohydrates
    | Fats
    | Limits
    | VitaminsMinerals


type GuidanceKind
    = Informational
    | Adequacy
    | Maximum


type Coverage
    = NoCoverage
    | PartialCoverage
    | CompleteCoverage


type NutrientStatus
    = NoData
    | PartialData
    | Available
    | BelowReference
    | MetReference
    | WithinLimit
    | OverLimit


decoder : Decoder NutritionDetails
decoder =
    Decode.map4 NutritionDetails
        (Decode.field "date" LocalDate.decoder)
        (Decode.field "reference" referenceDecoder)
        (Decode.field "logged_items" Decode.int)
        (Decode.field "nutrients" (Decode.list nutrientDecoder))


referenceDecoder : Decoder Reference
referenceDecoder =
    Decode.map6 Reference
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "authority" Decode.string)
        (Decode.field "jurisdiction" Decode.string)
        (Decode.field "population_label" Decode.string)
        (Decode.field "source_url" Decode.string)


nutrientDecoder : Decoder Nutrient
nutrientDecoder =
    Decode.succeed Nutrient
        |> Json.andMap (Decode.field "code" Decode.string)
        |> Json.andMap (Decode.field "name" Decode.string)
        |> Json.andMap (Decode.field "section" sectionDecoder)
        |> Json.andMap (Decode.field "known_amount" (Decode.nullable decimalDecoder))
        |> Json.andMap (Decode.field "unit" Decode.string)
        |> Json.andMap (Decode.field "reference_amount" (Decode.nullable decimalDecoder))
        |> Json.andMap (Decode.field "guidance_kind" guidanceKindDecoder)
        |> Json.andMap (Decode.field "items_with_data" Decode.int)
        |> Json.andMap (Decode.field "coverage" coverageDecoder)
        |> Json.andMap (Decode.field "status" statusDecoder)


decimalDecoder : Decoder Float
decimalDecoder =
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


sectionDecoder : Decoder NutrientSection
sectionDecoder =
    Decode.string |> Decode.andThen decodeSection


decodeSection : String -> Decoder NutrientSection
decodeSection raw =
    case raw of
        "overview" ->
            Decode.succeed Overview

        "carbohydrates" ->
            Decode.succeed Carbohydrates

        "fats" ->
            Decode.succeed Fats

        "limits" ->
            Decode.succeed Limits

        "vitamins_minerals" ->
            Decode.succeed VitaminsMinerals

        _ ->
            Decode.fail ("Invalid nutrition-details section: " ++ raw)


guidanceKindDecoder : Decoder GuidanceKind
guidanceKindDecoder =
    Decode.string |> Decode.andThen decodeGuidanceKind


decodeGuidanceKind : String -> Decoder GuidanceKind
decodeGuidanceKind raw =
    case raw of
        "informational" ->
            Decode.succeed Informational

        "adequacy" ->
            Decode.succeed Adequacy

        "maximum" ->
            Decode.succeed Maximum

        _ ->
            Decode.fail ("Invalid nutrient guidance kind: " ++ raw)


coverageDecoder : Decoder Coverage
coverageDecoder =
    Decode.string |> Decode.andThen decodeCoverage


decodeCoverage : String -> Decoder Coverage
decodeCoverage raw =
    case raw of
        "none" ->
            Decode.succeed NoCoverage

        "partial" ->
            Decode.succeed PartialCoverage

        "complete" ->
            Decode.succeed CompleteCoverage

        _ ->
            Decode.fail ("Invalid nutrient coverage: " ++ raw)


statusDecoder : Decoder NutrientStatus
statusDecoder =
    Decode.string |> Decode.andThen decodeStatus


decodeStatus : String -> Decoder NutrientStatus
decodeStatus raw =
    case raw of
        "no_data" ->
            Decode.succeed NoData

        "partial_data" ->
            Decode.succeed PartialData

        "available" ->
            Decode.succeed Available

        "below_reference" ->
            Decode.succeed BelowReference

        "met_reference" ->
            Decode.succeed MetReference

        "within_limit" ->
            Decode.succeed WithinLimit

        "over_limit" ->
            Decode.succeed OverLimit

        _ ->
            Decode.fail ("Invalid nutrient status: " ++ raw)


progressPercent : Nutrient -> Maybe Float
progressPercent nutrient =
    case ( nutrient.guidanceKind, nutrient.knownAmount, nutrient.referenceAmount ) of
        ( Informational, _, _ ) ->
            Nothing

        ( _, Just amount, Just referenceAmount ) ->
            if referenceAmount > 0 then
                Just ((amount / referenceAmount) * 100)

            else
                Nothing

        _ ->
            Nothing


isDangerous : Nutrient -> Bool
isDangerous nutrient =
    nutrient.guidanceKind == Maximum && nutrient.status == OverLimit
