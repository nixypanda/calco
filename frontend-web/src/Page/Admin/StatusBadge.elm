module Page.Admin.StatusBadge exposing (statusBadge)

import Element exposing (Element)
import Ui
import Ui.Theme exposing (Theme)


statusBadge : Theme -> String -> Element msg
statusBadge theme status =
    Ui.coloredPill
        { label = status
        , bg =
            if status == "active" then
                theme.statusActiveBg

            else
                theme.statusDisabledBg
        , fg =
            if status == "active" then
                theme.statusGreen

            else
                theme.statusRed
        }
