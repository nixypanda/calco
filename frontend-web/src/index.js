import { Elm } from "./Main.elm";

const app = Elm.Main.init({
    node: document.getElementById("root"),
    flags: {
        windowWidth: window.innerWidth,
        windowHeight: window.innerHeight,
    },
});

app.ports.requestLocalContext.subscribe(() => {
    const date = new Date().toLocaleDateString("en-CA");
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    app.ports.localContextReceived.send({ date, timezone });
});
