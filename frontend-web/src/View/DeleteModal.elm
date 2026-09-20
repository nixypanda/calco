module View.DeleteModal exposing
    ( DeleteState(..)
    , confirmModalView
    , deleteModalView
    )

import Element exposing (Device, Element)
import Ui.Button as Button
import Ui.Feedback as Feedback
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
    ->
        { title : String
        , description : String
        , confirmLabel : String
        , pendingLabel : String
        , onCancel : msg
        , onConfirm : msg
        }
    -> DeleteState
    -> Maybe (Element msg)
deleteModalView theme device config deleteState =
    case deleteState of
        DeleteConfirming ->
            Just (confirmModalView theme device config { pending = False, error = Nothing })

        Deleting ->
            Just (confirmModalView theme device config { pending = True, error = Nothing })

        DeleteFailed message ->
            Just (confirmModalView theme device config { pending = False, error = Just message })

        DeleteIdle ->
            Nothing


{-| Shared confirmation dialog for destructive actions that are not deletes.
-}
confirmModalView :
    Theme
    -> Device
    ->
        { title : String
        , description : String
        , confirmLabel : String
        , pendingLabel : String
        , onCancel : msg
        , onConfirm : msg
        }
    -> { pending : Bool, error : Maybe String }
    -> Element msg
confirmModalView theme device config state =
    Feedback.modalOverlay theme
        { title = config.title
        , body =
            [ Typography.mutedParagraph theme config.description
            , Feedback.maybeErrorBanner theme state.error
            ]
        , actions =
            Button.bottomActionButtons device
                theme
                [ { label = "Cancel", onPress = config.onCancel, tone = Button.Primary }
                , { label =
                        if state.pending then
                            config.pendingLabel

                        else
                            config.confirmLabel
                  , onPress = config.onConfirm
                  , tone = Button.Danger
                  }
                ]
        , onBackgroundPress = Just config.onCancel
        }
