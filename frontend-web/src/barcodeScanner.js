import { BrowserMultiFormatOneDReader } from "@zxing/browser";
import { BarcodeFormat, DecodeHintType } from "@zxing/library";

// Barcode scanning
//
// This stays in JavaScript because it depends on imperative browser resources
// and npm APIs that Elm cannot own directly: camera streams, video element
// attachment, ZXing decode callbacks, and explicit media-track cleanup. Elm
// decides when scanning starts/stops and receives normalized scanner events.
export function createBarcodeScanner({ videoElementId, onEvent }) {
    const barcodeConfirmationWindowMs = 1500;
    const barcodeRequiredDetections = 2;

    let barcodeReader = null;
    let barcodeControls = null;
    let barcodeScanActive = false;
    let barcodeCandidate = null;
    let barcodeCandidateCount = 0;
    let barcodeCandidateSeenAt = 0;

    async function start() {
        stop({ silent: true });
        barcodeScanActive = true;
        resetBarcodeCandidate();

        const videoElement = await waitForBarcodeVideoElement();
        if (!videoElement) {
            barcodeScanActive = false;
            sendEvent({
                event: "failed",
                message: "Scanner preview is not ready.",
            });
            return;
        }

        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            barcodeScanActive = false;
            sendEvent({
                event: "failed",
                message: "Camera scanning is not available in this browser.",
            });
            return;
        }

        const hints = new Map();
        hints.set(DecodeHintType.POSSIBLE_FORMATS, [
            BarcodeFormat.EAN_13,
            BarcodeFormat.EAN_8,
            BarcodeFormat.UPC_A,
            BarcodeFormat.UPC_E,
        ]);
        hints.set(DecodeHintType.TRY_HARDER, true);

        barcodeReader = new BrowserMultiFormatOneDReader(hints, {
            delayBetweenScanAttempts: 150,
            delayBetweenScanSuccess: 120,
        });

        try {
            const constraints = {
                audio: false,
                video: {
                    facingMode: { ideal: "environment" },
                    width: { ideal: 1920 },
                    height: { ideal: 1080 },
                    aspectRatio: { ideal: 16 / 9 },
                },
            };

            const controls = await barcodeReader.decodeFromConstraints(
                constraints,
                videoElement,
                (result) => {
                    if (!barcodeScanActive || !result) {
                        return;
                    }

                    const rawBarcode =
                        typeof result.getText === "function"
                            ? result.getText()
                            : result.text;
                    const barcode = String(rawBarcode || "").trim();

                    if (barcode.length === 0) {
                        return;
                    }

                    if (!isConfirmedBarcode(barcode)) {
                        return;
                    }

                    sendEvent({ event: "detected", barcode });
                    stop();
                },
            );

            if (!barcodeScanActive) {
                controls.stop();
                return;
            }

            barcodeControls = controls;
            sendEvent({ event: "started" });
        } catch (error) {
            stop({ silent: true });
            sendEvent({
                event: "failed",
                message: barcodeScannerErrorMessage(error),
            });
        }
    }

    function waitForBarcodeVideoElement() {
        return new Promise((resolve) => {
            const startedAt = Date.now();
            const timeoutMs = 1000;

            const find = () => {
                const videoElement = document.getElementById(videoElementId);

                if (videoElement || !barcodeScanActive) {
                    resolve(videoElement);
                    return;
                }

                if (Date.now() - startedAt >= timeoutMs) {
                    resolve(null);
                    return;
                }

                requestAnimationFrame(find);
            };

            find();
        });
    }

    function stop(options = {}) {
        const wasActive = barcodeScanActive || barcodeControls !== null;
        barcodeScanActive = false;
        resetBarcodeCandidate();

        if (barcodeControls && typeof barcodeControls.stop === "function") {
            barcodeControls.stop();
        }
        barcodeControls = null;
        barcodeReader = null;

        const videoElement = document.getElementById(videoElementId);
        const stream = videoElement && videoElement.srcObject;
        if (stream && typeof stream.getTracks === "function") {
            stream.getTracks().forEach((track) => track.stop());
        }
        if (videoElement) {
            videoElement.srcObject = null;
        }

        if (wasActive && !options.silent) {
            sendEvent({ event: "stopped" });
        }
    }

    function isConfirmedBarcode(barcode) {
        const now = Date.now();
        const isSameCandidate =
            barcode === barcodeCandidate &&
            now - barcodeCandidateSeenAt <= barcodeConfirmationWindowMs;

        if (isSameCandidate) {
            barcodeCandidateCount += 1;
            barcodeCandidateSeenAt = now;
        } else {
            barcodeCandidate = barcode;
            barcodeCandidateCount = 1;
            barcodeCandidateSeenAt = now;
        }

        return barcodeCandidateCount >= barcodeRequiredDetections;
    }

    function resetBarcodeCandidate() {
        barcodeCandidate = null;
        barcodeCandidateCount = 0;
        barcodeCandidateSeenAt = 0;
    }

    function sendEvent(payload) {
        onEvent({
            event: payload.event,
            barcode: payload.barcode || null,
            message: payload.message || null,
        });
    }

    return {
        start,
        stop,
    };
}

function barcodeScannerErrorMessage(error) {
    const name = error && error.name;

    if (name === "NotAllowedError" || name === "SecurityError") {
        return "Camera permission was denied.";
    }

    if (name === "NotFoundError" || name === "DevicesNotFoundError") {
        return "No camera was found.";
    }

    if (name === "NotReadableError" || name === "TrackStartError") {
        return "Camera is already in use.";
    }

    if (name === "OverconstrainedError" || name === "ConstraintNotSatisfiedError") {
        return "Could not use the requested camera.";
    }

    return "Could not start barcode scanner.";
}
