module Ui.Css exposing (themeCssVariables)

import Ui.Common exposing (toCssColor)
import Ui.Theme exposing (Theme)


themeCssVariables : Theme -> String
themeCssVariables theme =
    String.join "; "
        [ "--ui-page-bg: " ++ toCssColor theme.pageBg
        , "--ui-card-bg: " ++ toCssColor theme.cardBg
        , "--ui-text-primary: " ++ toCssColor theme.textPrimary
        , "--ui-text-muted: " ++ toCssColor theme.textMuted
        , "--ui-text-medium: " ++ toCssColor theme.textMedium
        , "--ui-divider: " ++ toCssColor theme.divider
        , "--ui-input-fill: " ++ toCssColor theme.inputFill
        , "--ui-brand-blue: " ++ toCssColor theme.brandBlue
        , "--ui-brand-blue-pressed: " ++ toCssColor theme.brandBluePressed
        , "--ui-brand-blue-soft: " ++ toCssColor theme.brandBlueSoft
        , "--ui-brand-blue-disabled: " ++ toCssColor theme.brandBlueDisabled
        , "--ui-danger-bg: " ++ toCssColor theme.dangerBg
        , "--ui-danger-fg: " ++ toCssColor theme.dangerFg
        , "--ui-danger-solid: " ++ toCssColor theme.dangerSolid
        , "--ui-drawer-selection-bg: " ++ toCssColor theme.drawerSelectionBg
        , "--ui-status-green: " ++ toCssColor theme.statusGreen
        , "--ui-status-red: " ++ toCssColor theme.statusRed
        , "--ui-status-active-bg: " ++ toCssColor theme.statusActiveBg
        , "--ui-status-disabled-bg: " ++ toCssColor theme.statusDisabledBg
        , "--ui-card-shadow: " ++ theme.cardShadow
        , "--ui-chip-bg: " ++ toCssColor theme.chipBg
        , "--ui-chip-border: " ++ toCssColor theme.chipBorder
        , "--ui-chip-fg: " ++ toCssColor theme.textPrimary
        , "--ui-chip-selected-bg: " ++ toCssColor theme.chipSelectedBg
        , "--ui-chip-selected-fg: " ++ toCssColor theme.chipSelectedFg
        , "--ui-focus-ring: " ++ toCssColor theme.focusRing
        ]
