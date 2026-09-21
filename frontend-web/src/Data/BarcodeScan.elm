module Data.BarcodeScan exposing (ScannerEvent)

{-| One event from the JS barcode scanner, pushed in over the
`barcodeScannerEvent` port. `event` names the variant and decides which of the
other two fields is populated.
-}


type alias ScannerEvent =
    { event : String, barcode : Maybe String, message : Maybe String }
