import { useState, useCallback, useEffect } from "react";
import { useNuiEvent, fetchNui } from "@/lib/nui";
import { isSaving, onSavingChange } from "@/lib/autosave";
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

  const doClose = useCallback(() => {
    setView("none");
    fetchNui("close");
  }, []);

  // Don't close mid-save: if a debounced setting write is pending/in-flight, keep the
  // panel open and close as soon as it lands (so no edit is dropped). A fallback timer
  // guarantees the UI can't get stuck if a save ever hangs.
  const close = useCallback(() => {
    if (!isSaving()) { doClose(); return; }
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      unsub();
      window.clearTimeout(fallback);
      doClose();
    };
    const unsub = onSavingChange(() => { if (!isSaving()) finish(); });
    const fallback = window.setTimeout(finish, 4000);
  }, [doClose]);

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
