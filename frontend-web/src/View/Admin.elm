module View.Admin exposing (statusBadge)

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
                Element.rgb255 50 110 60

            else
                Element.rgb255 180 60 80
        }
