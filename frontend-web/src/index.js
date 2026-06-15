import "./main.css";
import { Elm } from "./Main.elm";

const stored = localStorage.getItem("themeMode") || "light";

const app = Elm.Main.init({
    node: document.getElementById("root"),
    flags: {
        windowWidth: window.innerWidth,
        windowHeight: window.innerHeight,
        themeMode: stored,
    },
});

app.ports.requestLocalContext.subscribe(() => {
    const date = new Date().toLocaleDateString("en-CA");
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    app.ports.localContextReceived.send({ date, timezone });
});

app.ports.persistThemeMode.subscribe((mode) => {
    localStorage.setItem("themeMode", mode);
});
