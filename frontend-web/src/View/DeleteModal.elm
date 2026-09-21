module View.DeleteModal exposing
    ( DeleteState(..)
    , confirmModalView
    , deleteModalView
    )

import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Typography as Typography


type DeleteState
    = DeleteIdle
    | DeleteConfirming
    | Deleting
    | DeleteFailed String


deleteModalView :
    Env
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
deleteModalView env config deleteState =
    case deleteState of
        DeleteConfirming ->
            Just
                (confirmModalView env
                    config
                    { pending = False, error = Nothing }
                )

        Deleting ->
            Just
                (confirmModalView env
                    config
                    { pending = True, error = Nothing }
                )

        DeleteFailed message ->
            Just
                (confirmModalView env
                    config
                    { pending = False, error = Just message }
                )

        DeleteIdle ->
            Nothing


{-| Shared confirmation dialog for destructive actions that are not deletes.
-}
confirmModalView :
    Env
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
confirmModalView env config state =
    Feedback.modalOverlay env.theme
        { title = config.title
        , body =
            [ Typography.mutedParagraph env.theme config.description
            , Feedback.maybeErrorBanner env.theme state.error
            ]
        , actions =
            Button.bottomActionButtons env.device
                env.theme
                [ { label = I18n.t env.language TidCommonCancel
                  , onPress = config.onCancel
                  , tone = Button.Primary
                  }
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
