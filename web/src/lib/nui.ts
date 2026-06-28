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
