import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import KioskDui from "./views/KioskDui";
import "./index.css";

// The SAME built bundle is loaded two ways: as the normal ui_page NUI (<App/>), and
// as a DUI on the kiosk's in-world screen via `.../nui/index.html#kiosk` — that hash
// selects the self-service kiosk order page instead (modules/kiosk).
const isKiosk = window.location.hash.replace(/^#/, "").split("?")[0] === "kiosk";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {isKiosk ? <KioskDui /> : <App />}
  </React.StrictMode>
);
