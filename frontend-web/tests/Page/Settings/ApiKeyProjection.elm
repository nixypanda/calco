module Page.Settings.ApiKeyProjection exposing
    ( ApiKeysScreen
    , CreateScreen
    , CreatedView
    , DialogView
    , FormView
    , apiKeysScreen
    , createScreen
    )

{-| User-visible projections for the api-key list and create pages. The
projections deliberately omit internal states such as loading/submitting and
generation counters; a story only asserts what the user can see.
-}

import Api.Client as Client
import I18n
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeys as ApiKeys
import Translations.Ids exposing (TranslationId(..))


type alias CreateScreen =
    { form : Maybe FormView
    , created : Maybe CreatedView
    }


type alias FormView =
    { name : String
    , submitLabel : String
    , submitDisabled : Bool
    , error : Maybe String
    }


type alias CreatedView =
    { token : String
    , copyFeedback : Maybe String
    , copyDisabled : Bool
    , doneDisabled : Bool
    }


type alias ApiKeysScreen =
    { names : List String
    , error : Maybe String
    , dialog : Maybe DialogView
    }


type alias DialogView =
    { keyName : String
    , title : String
    , actionLabel : String
    , error : Maybe String
    }


createScreen : ApiKeyCreate.Model -> CreateScreen
createScreen model =
    case model of
        ApiKeyCreate.Form formModel ->
            let
                form : ApiKeyCreate.CreateForm
                form =
                    formModel.form

                submitting : Bool
                submitting =
                    isSubmitting form.state
            in
            { form =
                Just
                    { name = form.name
                    , submitLabel =
                        if submitting then
                            I18n.en TidCommonCreating

                        else
                            I18n.en TidApiKeysCreate
                    , submitDisabled = submitting
                    , error = formError form.state
                    }
            , created = Nothing
            }

        ApiKeyCreate.Created createdModel ->
            let
                copyPending : Bool
                copyPending =
                    isCopyPending createdModel.copyState
            in
            { form = Nothing
            , created =
                Just
                    { token = createdModel.created.token
                    , copyFeedback = copyFeedback createdModel.copyState
                    , copyDisabled = copyPending
                    , doneDisabled = copyPending
                    }
            }


apiKeysScreen : ApiKeys.Model -> ApiKeysScreen
apiKeysScreen model =
    case model of
        ApiKeys.Loading ->
            { names = [], error = Nothing, dialog = Nothing }

        ApiKeys.LoadFailed error ->
            { names = []
            , error = Just (Client.displayError error)
            , dialog = Nothing
            }

        ApiKeys.Loaded loaded ->
            { names = List.map .name loaded.keys
            , error = Nothing
            , dialog =
                case loaded.dialog of
                    ApiKeys.NoDialog ->
                        Nothing

                    ApiKeys.ConfirmRevoke key maybeError ->
                        Just (confirmDialog key.name maybeError)

                    ApiKeys.Revoking _ key ->
                        Just (revokingDialog key.name)
            }


confirmDialog : String -> Maybe String -> DialogView
confirmDialog keyName maybeError =
    { keyName = keyName
    , title = I18n.en TidApiKeysRevokeTitle
    , actionLabel = I18n.en TidApiKeysConfirmRevoke
    , error = maybeError
    }


revokingDialog : String -> DialogView
revokingDialog keyName =
    { keyName = keyName
    , title = I18n.en TidApiKeysRevokeTitle
    , actionLabel = I18n.en TidApiKeysRevoking
    , error = Nothing
    }


formError : ApiKeyCreate.CreateState -> Maybe String
formError state =
    case state of
        ApiKeyCreate.Invalid error ->
            Just (errorMessage error)

        ApiKeyCreate.Failed message ->
            Just message

        ApiKeyCreate.Editing ->
            Nothing

        ApiKeyCreate.Submitting _ ->
            Nothing


errorMessage : ApiKeyCreate.CreateError -> String
errorMessage error =
    case error of
        ApiKeyCreate.NameRequired ->
            I18n.en TidApiKeysNameRequired

        ApiKeyCreate.NameTooLong ->
            I18n.en TidApiKeysNameTooLong

        ApiKeyCreate.NameInvalid ->
            I18n.en TidApiKeysNameInvalid


isSubmitting : ApiKeyCreate.CreateState -> Bool
isSubmitting state =
    case state of
        ApiKeyCreate.Submitting _ ->
            True

        _ ->
            False


isCopyPending : ApiKeyCreate.CopyState -> Bool
isCopyPending state =
    case state of
        ApiKeyCreate.CopyPending _ ->
            True

        _ ->
            False


copyFeedback : ApiKeyCreate.CopyState -> Maybe String
copyFeedback state =
    case state of
        ApiKeyCreate.CopyIdle ->
            Nothing

        ApiKeyCreate.CopyPending _ ->
            Just (I18n.en TidApiKeysCopying)

        ApiKeyCreate.CopySucceeded ->
            Just (I18n.en TidApiKeysCopied)

        ApiKeyCreate.CopyFailed ->
            Just (I18n.en TidApiKeysCopyFailed)
