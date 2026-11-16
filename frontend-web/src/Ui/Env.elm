module Ui.Env exposing
    ( Env
    , Viewport(..)
    , viewportForWidth
    , withDevice
    , withLanguage
    , withTheme
    , withViewport
    )

{-| The ambient view context threaded through the whole view layer: the active
theme, the classified device, the coarse viewport category, and the active
language.

These values are global, read-only from a view's perspective, and needed by
nearly every screen, so they travel together as one record instead of separate
parameters or record fields. Adding a further ambient value (for example a
device time zone) is then a single change to this type plus the places that
construct it, rather than a signature change at every call site.

`Element.Device` only distinguishes phones below 600px, but a phone-width
layout sometimes needs a finer breakpoint. `viewportForWidth` reduces the raw
window width to a semantic category once, at the main view's resize boundary,
so ordinary pixel changes inside one category do not force a re-render. The
category is deliberately independent of the device class: it only answers
whether a narrow phone card needs the compact arrangement.

`Env` is view context only. It deliberately does not include `Route`, `Session`,
or server-derived preferences: routes and sessions are navigation/auth state,
and units and diary preferences are cached in `Store` and hydrated into panes.

-}

import Element exposing (Device)
import Translations.Util exposing (Language)
import Ui.Theme exposing (Theme)


type Viewport
    = NarrowViewport
    | RegularViewport


{-| Parse the raw width at the boundary that receives resize events. The
359/360 boundary is the smallest phone width that comfortably fits the diary
date and its two 44px navigation controls on one row.
-}
viewportForWidth : Int -> Viewport
viewportForWidth width =
    if width < 360 then
        NarrowViewport

    else
        RegularViewport


type alias Env =
    { theme : Theme
    , device : Device
    , viewport : Viewport
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


withViewport : Env -> Viewport -> Env
withViewport env viewport =
    { env | viewport = viewport }


withLanguage : Env -> Language -> Env
withLanguage env language =
    { env | language = language }
