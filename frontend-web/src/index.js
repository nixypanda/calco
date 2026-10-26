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
let lastSentDate = null;

function sendLocalContext() {
    const date = new Date().toLocaleDateString("en-CA");
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    lastSentDate = date;
    app.ports.localContextReceived.send({ date, timezone });
}

app.ports.requestLocalContext.subscribe(sendLocalContext);

// Elm blocks its first render until it knows the date, and a command sent from
// `init` would have been dispatched before the line above subscribed.
sendLocalContext();

// A tab can outlive the day it booted on, and nothing else tells Elm the date
// moved. Only push on an actual rollover: an unsolicited context is a no-op for
// the save paths, but there is no reason to wake every pane once a minute.
function sendLocalContextIfDayChanged() {
    if (new Date().toLocaleDateString("en-CA") !== lastSentDate) {
        sendLocalContext();
    }
}

setInterval(sendLocalContextIfDayChanged, 60000);

document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
        sendLocalContextIfDayChanged();
    }
});

app.ports.persistThemeMode.subscribe((mode) => {
    localStorage.setItem("themeMode", mode);
});

app.ports.reloadPage.subscribe(() => {
    location.reload();
});

app.ports.revokePhotoPreviewUrls.subscribe((urls) => {
    urls.forEach((url) => URL.revokeObjectURL(url));
});

app.ports.copyText.subscribe(async (request) => {
    const result = {
        generation: request.generation,
        requestId: request.requestId,
        succeeded: false,
    };
    try {
        if (!navigator.clipboard || typeof navigator.clipboard.writeText !== "function") {
            throw new Error("Clipboard API unavailable");
        }
        await navigator.clipboard.writeText(request.text);
        result.succeeded = true;
    } catch (_) {
        // Clipboard access can be blocked; the token remains selectable.
    }
    app.ports.copyTextResult.send(result);
});

// Barcode scanner port wiring.
const barcodeScanner = createBarcodeScanner({
    videoElementId: "calco-barcode-scanner-video",
    onEvent: (event) => app.ports.barcodeScannerEvent.send(event),
});

app.ports.requestBarcodeScanStart.subscribe(() => {
    barcodeScanner.start().catch(() => {
        app.ports.barcodeScannerEvent.send({
            event: "failed",
            message: "Barcode scanning could not be started. Enter the barcode manually.",
        });
    });
});

app.ports.requestBarcodeScanStop.subscribe(() => {
    barcodeScanner.stop();
});

window.addEventListener("pagehide", () => {
    barcodeScanner.stop();
    document.querySelectorAll('img[src^="blob:"]').forEach((image) => {
        URL.revokeObjectURL(image.src);
    });
});

document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
        barcodeScanner.stop();
    }
});
