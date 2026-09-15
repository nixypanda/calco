module Page.FoodLog.AiReview exposing
    ( allowedUnitCodes
    , changeAmount
    , changeUnit
    , fromDraft
    )

import Api.Foods exposing (NutrientItem)
import Data.FoodAssistant exposing (FoodDraft, SuggestedLog)
import Page.Food.Editor as Editor


fromDraft :
    List NutrientItem
    -> FoodDraft
    -> SuggestedLog
    -> Editor.FormModel
    -> Result String Editor.FormModel
fromDraft =
    Editor.applyAiLogDraft


changeAmount : String -> Editor.FormModel -> Editor.FormModel
changeAmount =
    Editor.changeLogQuantity


changeUnit : FoodDraft -> String -> Editor.FormModel -> Editor.FormModel
changeUnit =
    Editor.changeLogUnit


allowedUnitCodes : FoodDraft -> List String
allowedUnitCodes =
    Editor.allowedLogUnitCodes
