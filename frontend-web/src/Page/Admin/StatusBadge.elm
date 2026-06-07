module Page.Admin.StatusBadge exposing (statusBadge)

import Element exposing (Element)
import Ui


statusBadge : String -> Element msg
statusBadge status =
    Ui.coloredPill
        { label = status
        , bg =
            if status == "active" then
                Ui.accentSoftGreen

            else
                Ui.accentSoftPink
        , fg =
            if status == "active" then
                Ui.statusGreen

            else
                Ui.statusRed
        }
