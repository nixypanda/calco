module View.DeleteModal exposing
    ( DeleteState(..)
    , confirmModalView
    , deleteModalView
    )

import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
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
            Just (confirmModalView env config { pending = False, error = Nothing })

        Deleting ->
            Just (confirmModalView env config { pending = True, error = Nothing })

        DeleteFailed message ->
            Just (confirmModalView env config { pending = False, error = Just message })

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
            Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space12
                ]
                [ Element.el [ Element.width Element.fill ]
                    (Button.textButton env.device
                        env.theme
                        { tone = Button.Primary
                        , width = Button.FullWidth
                        , label = I18n.t env.language TidCommonCancel
                        , onPress = config.onCancel
                        , submitState =
                            Just
                                (if state.pending then
                                    Button.Disabled

                                 else
                                    Button.Idle
                                )
                        , submittingLabel = Nothing
                        , trailing = Nothing
                        }
                    )
                , Element.el [ Element.width Element.fill ]
                    (Button.textButton env.device
                        env.theme
                        { tone = Button.Danger
                        , width = Button.FullWidth
                        , label = config.confirmLabel
                        , onPress = config.onConfirm
                        , submitState =
                            Just
                                (if state.pending then
                                    Button.Submitting

                                 else
                                    Button.Idle
                                )
                        , submittingLabel = Just config.pendingLabel
                        , trailing = Nothing
                        }
                    )
                ]
        , onBackgroundPress = Just config.onCancel
        }
