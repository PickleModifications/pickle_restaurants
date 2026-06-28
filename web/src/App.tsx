import { useState, useCallback, useEffect } from "react";
import { useNuiEvent, fetchNui } from "@/lib/nui";
import InteractText from "@/views/InteractText";
import Cooking from "@/views/Cooking";
import Admin from "@/views/Admin";
import Management from "@/views/Management";
import Order from "@/views/Order";
import Register from "@/views/Register";

type View = "none" | "cooking" | "admin" | "management" | "order" | "register";

export default function App() {
  const [view, setView] = useState<View>("none");
  const [data, setData] = useState<any>(null);

  useNuiEvent("setView", (d) => {
    setView((d.view || "none") as View);
    setData(d.data ?? null);
  });

  const close = useCallback(() => {
    setView("none");
    fetchNui("close");
  }, []);

  // ESC closes panel views (cooking manages its own escape).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && view !== "none" && view !== "cooking") close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view, close]);

  return (
    <div className="h-full w-full">
      {view === "none" && <InteractText />}

      {view === "cooking" && <Cooking data={data} />}
      {view === "admin" && <Admin data={data} onClose={close} />}
      {view === "management" && <Management data={data} onClose={close} />}
      {view === "order" && <Order data={data} onClose={close} />}
      {view === "register" && <Register data={data} onClose={close} />}
    </div>
  );
}
