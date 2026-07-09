import { useState, useCallback, useEffect, Component, type ReactNode } from "react";
import { useNuiEvent, fetchNui } from "@/lib/nui";
import { isSaving, onSavingChange } from "@/lib/autosave";
import { applyTheme } from "@/lib/theme";
import InteractText from "@/views/InteractText";
import Cooking from "@/views/Cooking";
import Admin from "@/views/Admin";
import Management from "@/views/Management";
import Register from "@/views/Register";
import PayConfirm from "@/views/PayConfirm";

type View = "none" | "cooking" | "admin" | "management" | "register" | "payconfirm";

// Contains a render error in any single view (e.g. a malformed payload) so it
// can't white-screen the whole NUI — the panel closes and control returns to the
// game instead of leaving a dead, focus-stealing overlay. Resets when the view
// changes (keyed by `view`), so reopening a panel is a clean mount.
class ViewErrorBoundary extends Component<{ children: ReactNode; onError: () => void }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(err: unknown) { console.error("[pickle_restaurants] view crashed:", err); this.props.onError(); }
  render() { return this.state.failed ? null : this.props.children; }
}

export default function App() {
  const [view, setView] = useState<View>("none");
  const [data, setData] = useState<any>(null);

  useNuiEvent("setView", (d) => {
    const v = (d.view || "none") as View;
    setView(v);
    setData(d.data ?? null);
    // Restaurant-scoped payloads carry the franchise theme seed; closing (or a
    // payload without one) resets the UI to the default kit.
    applyTheme(v === "none" ? null : d.data?.theme);
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

      {view !== "none" && (
        <ViewErrorBoundary key={view} onError={doClose}>
          {view === "cooking" && <Cooking data={data} />}
          {view === "admin" && <Admin data={data} onClose={close} />}
          {view === "management" && <Management data={data} onClose={close} />}
          {view === "register" && <Register data={data} onClose={close} />}
          {view === "payconfirm" && <PayConfirm data={data} />}
        </ViewErrorBoundary>
      )}
    </div>
  );
}
