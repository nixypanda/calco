module Api.ApiKeys exposing (create, list, revoke)

import Api.Client as Client
import Data.ApiKey as ApiKey exposing (ApiKey, CreateRequest, CreatedApiKey)
import Url.Builder as Builder


list : (Result Client.ApiError (List ApiKey) -> msg) -> Cmd msg
list toMsg =
    Client.get apiKeysPath ApiKey.listDecoder toMsg


create : CreateRequest -> (Result Client.ApiError CreatedApiKey -> msg) -> Cmd msg
create request toMsg =
    Client.post apiKeysPath (ApiKey.createRequestEncoder request) ApiKey.createdDecoder toMsg


revoke : String -> (Result Client.ApiError () -> msg) -> Cmd msg
revoke apiKeyId toMsg =
    Client.delete (Builder.absolute [ "api", "auth", "api-keys", apiKeyId ] []) toMsg


apiKeysPath : String
apiKeysPath =
    Builder.absolute [ "api", "auth", "api-keys" ] []
