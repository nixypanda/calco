import "./main.css";
import { Elm } from "./Main.elm";
import { createBarcodeScanner } from "./barcodeScanner";

const stored = localStorage.getItem("themeMode") || "light";
const app = Elm.Main.init({
    node: document.getElementById("root"),
    flags: {
        windowWidth: window.innerWidth,
        windowHeight: window.innerHeight,
        themeMode: stored,
    },
});

// Browser integration ports: Elm owns app state and asks JavaScript for the
// few browser effects it cannot perform directly.
app.ports.requestLocalContext.subscribe(() => {
    const date = new Date().toLocaleDateString("en-CA");
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    app.ports.localContextReceived.send({ date, timezone });
});

app.ports.persistThemeMode.subscribe((mode) => {
    localStorage.setItem("themeMode", mode);
});

app.ports.reloadPage.subscribe(() => {
    location.reload();
});

// Barcode scanner port wiring.
const barcodeScanner = createBarcodeScanner({
    videoElementId: "calco-barcode-scanner-video",
    onEvent: (event) => app.ports.barcodeScannerEvent.send(event),
});

app.ports.requestBarcodeScanStart.subscribe(() => {
    barcodeScanner.start();
});

app.ports.requestBarcodeScanStop.subscribe(() => {
    barcodeScanner.stop();
});

window.addEventListener("pagehide", () => {
    barcodeScanner.stop();
});

document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
        barcodeScanner.stop();
    }
});
