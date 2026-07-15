import { useEffect, useRef } from "react";

const RESOURCE =
  (typeof window !== "undefined" && (window as any).GetParentResourceName?.()) ||
  "pickle_restaurants";

export async function fetchNui<T = any>(event: string, data: any = {}): Promise<T> {
  try {
    const resp = await fetch(`https://${RESOURCE}/${event}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(data),
    });
    return (await resp.json()) as T;
  } catch {
    return {} as T;
  }
}

// Fade the whole NUI to 75% while the user peeks at a highlighted world entity
// behind the panel (a prop-card hover beams/outlines the prop in the world). Driven
// by a `data-peek` attr on <html>; index.css fades the app root with a transition.
export function setPeek(on: boolean) {
  if (on) document.documentElement.setAttribute("data-peek", "1");
  else document.documentElement.removeAttribute("data-peek");
}

type Handler = (data: any) => void;

// Subscribes to NUI messages. Matches on either `action` or `type` (the core
// interact-text message uses `type`).
export function useNuiEvent(name: string, handler: Handler) {
  const saved = useRef<Handler>(handler);
  saved.current = handler;
  useEffect(() => {
    const listener = (e: MessageEvent) => {
      const d = e.data || {};
      if (d.action === name || d.type === name) saved.current(d);
    };
    window.addEventListener("message", listener);
    return () => window.removeEventListener("message", listener);
  }, [name]);
}
