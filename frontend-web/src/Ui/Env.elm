module Ui.Env exposing (Env, withDevice, withLanguage, withTheme)

{-| The ambient view context threaded through the whole view layer: the active
theme, the classified device/viewport, and the active language.

These three values are global, read-only from a view's perspective, and needed
by nearly every screen, so they travel together as one record instead of three
separate parameters or record fields. Adding a further ambient value (for
example a device time zone) is then a single change to this type plus the places
that construct it, rather than a signature change at every call site.

`Env` is view context only. It deliberately does not include `Route`, `Session`,
or server-derived preferences: routes and sessions are navigation/auth state,
and units and diary preferences are cached in `Store` and hydrated into panes.

-}

import Element exposing (Device)
import Translations.Util exposing (Language)
import Ui.Theme exposing (Theme)


type alias Env =
    { theme : Theme
    , device : Device
    , language : Language
    }


{-| Elm only allows record update on a bare variable, so `{ model.env | ... }`
is a syntax error. These helpers keep the field updates at one place.
-}
withTheme : Env -> Theme -> Env
withTheme env theme =
    { env | theme = theme }


withDevice : Env -> Device -> Env
withDevice env device =
    { env | device = device }


withLanguage : Env -> Language -> Env
withLanguage env language =
    { env | language = language }
