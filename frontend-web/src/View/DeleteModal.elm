module View.DeleteModal exposing
    ( DeleteState(..)
    , deleteModalView
    )

import Element exposing (Device, Element)
import Ui
import Ui.Button as Button
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type DeleteState
    = DeleteIdle
    | DeleteConfirming
    | Deleting
    | DeleteFailed String


deleteModalView :
    Theme
    -> Device
    -> { title : String, description : String, onCancel : msg, onConfirm : msg }
    -> DeleteState
    -> Maybe (Element msg)
deleteModalView theme device config deleteState =
    case deleteState of
        DeleteConfirming ->
            Just (deleteModalContent theme device config Nothing False)

        Deleting ->
            Just (deleteModalContent theme device config Nothing True)

        DeleteFailed message ->
            Just (deleteModalContent theme device config (Just message) False)

        DeleteIdle ->
            Nothing


deleteModalContent :
    Theme
    -> Device
    -> { title : String, description : String, onCancel : msg, onConfirm : msg }
    -> Maybe String
    -> Bool
    -> Element msg
deleteModalContent theme device config maybeError deleting =
    Ui.modalOverlay theme
        { title = config.title
        , body =
            [ Typography.mutedParagraph theme config.description
            , Ui.maybeErrorBanner theme maybeError
            ]
        , actions =
            Button.bottomActionButtons device
                theme
                [ { label = "Cancel", onPress = config.onCancel, tone = Button.Primary }
                , { label =
                        if deleting then
                            "Deleting..."

                        else
                            "Confirm Delete"
                  , onPress = config.onConfirm
                  , tone = Button.Danger
                  }
                ]
        , onBackgroundPress = Just config.onCancel
        }
