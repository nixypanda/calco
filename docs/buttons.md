# Button System

All interactive buttons in the UI go through two unified entry points in
`frontend-web/src/Ui.elm`: `textButton` for label-based buttons and
`iconButton` for icon-only buttons. A small number of components stay
outside this system because they have structural constraints that prevent
using `Input.button` from elm-ui.

## Unified API

### textButton

```elm
textButton : Device -> Theme -> ButtonConfig msg -> Element msg

type alias ButtonConfig msg =
    { tone : ButtonTone
    , width : ButtonWidth
    , label : String
    , onPress : msg
    , submitState : Maybe SubmitState
    , submittingLabel : Maybe String
    , trailing : Maybe (Element msg)
    }
```

All text buttons are 48px tall, pill-shaped (`radiusPill`), and use
`Font.medium` at 14px. Ghost and GhostFilled tones are left-aligned;
all other tones are centered. Hover effects are suppressed when the
button is not active (`Disabled`, `Submitting`, or `Submitted`).

### iconButton

```elm
iconButton :
    Device
    -> Theme
    -> { icon : Icon, title : String, onPress : Maybe msg, tone : ButtonTone }
    -> Element msg
```

44x44px square, pill-shaped. `onPress = Nothing` renders a disabled
state (muted colors, no interaction).

## ADTs

### ButtonTone

| Tone | Background | Text | Border | Use case |
|------|-----------|------|--------|----------|
| `Primary` | brandBlue | white | none | Primary actions (Submit, Save, Create) |
| `PrimaryOutline` | cardBg | brandBlue | 1px brandBlue | Secondary actions (Cancel, Choose photos) |
| `Danger` | dangerSolid | white | none | Destructive actions (Delete, Confirm) |
| `DangerOutline` | cardBg | dangerFg | 1px dangerFg | Destructive secondary (Remove photo) |
| `Ghost` | transparent | brandBlue (muted when disabled) | none | Text links ("+ Add Food", "+ Create Meal") |
| `GhostFilled` | brandBlueSoft | brandBlue | none | Filled links ("Details", "Load earlier") |

### ButtonWidth

| Width | Behavior |
|-------|----------|
| `ContentWidth` | Shrinks to content |
| `ResponsiveWidth` | Fill on phone, shrink on desktop |
| `FullWidth` | Always fill parent |

### SubmitState

| State | Behavior |
|-------|----------|
| `Idle` | Active, pressable |
| `Submitting` | Shows `submittingLabel`, press disabled |
| `Disabled` | Press disabled, muted styling |
| `Submitted` | Press disabled, muted styling (for completed actions) |

## Buttons outside the unified system

The following components use `Input.button` directly or raw HTML instead
of `Ui.textButton` / `Ui.iconButton`. Each has a specific structural
reason.

### Camera input (`Page/CustomFood/Assistant.elm`)

The "Take photo" button renders a hidden `<input type="file"
capture="environment">` inside an `Html.label`. This is the only way to
trigger the native camera picker on mobile. The CSS classes
`.photo-capture-label` match the `PrimaryOutline` visual style (blue
border, blue text, card bg, pill shape, 48px height).

### Macro mode toggle (`Page/Diary/Day.elm`)

An unstyled text tap target. Renders as `Typography.mutedCaption` with
no background, border, or padding. Intentionally minimal — adding
button styling would change its visual identity.

### Log row (`Page/Diary/Day.elm`)

A list item that is also a button. Its label is a complex row with a
macro dot, item name, quantity, and calories. The `textButton` API
accepts a `String` label, not a multi-element layout.

### Scope segment toggle (`Page/Food/Search.elm`)

A segmented control with two visual states (selected: solid blue bg +
white text; unselected: neutral bg + medium text). Structurally a
toggle group, not a standalone button.

### Calendar day cell (`Page/Diary/Calendar.elm`)

A grid cell with `aria-pressed` state and conditional background. The
label is a complex day number + dot indicator element.

### Profile initial button (`View/Chrome.elm`)

A 44x44 circle showing a single character. `iconButton` takes an `Icon`
record, not text. Could potentially be a `textButton` with `ContentWidth`
but the circular shape and specific sizing make it cleaner as a custom
element.

### Update banner (`View/Chrome.elm`)

A full-width banner with a two-part label ("New version available" +
"Tap to refresh"). The complex label layout doesn't fit the `String`
label in `textButton`.

## Adding a new button

Before creating a custom `Input.button`, check if `textButton` or
`iconButton` with the right tone/width covers the case. If the button
needs:

- A different height than 44px
- A non-pill border radius
- A complex (non-string) label
- Special ARIA attributes or native behavior (file input, etc.)

then a custom implementation is justified. Document why in a comment at
the call site.
