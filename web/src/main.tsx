import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import KioskDui from "./views/KioskDui";
import RegisterDui from "./views/RegisterDui";
import "./index.css";

// The SAME built bundle is loaded three ways: as the normal ui_page NUI (<App/>), and
// as a DUI on an in-world screen selected by the URL hash —
//   #kiosk    → the self-service customer kiosk order page (modules/kiosk)
//   #register → the staff POS register painted on the counter's screen (modules/register)
const hash = window.location.hash.replace(/^#/, "").split("?")[0];

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {hash === "kiosk" ? <KioskDui /> : hash === "register" ? <RegisterDui /> : <App />}
  </React.StrictMode>
);
