import { useState } from "react";
import { useNuiEvent } from "@/lib/nui";

// Mirrors the core/client.lua contract: SendNUIMessage({ type:"setInteractText", text })
export default function InteractText() {
  const [text, setText] = useState<string | null>(null);
  useNuiEvent("setInteractText", (d) => setText(d.text ?? null));

  if (!text) return null;
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-24 flex justify-center">
      <div className="animate-fade-in whitespace-pre-line rounded-lg border border-border bg-card/90 px-4 py-2 text-center text-sm font-medium text-foreground shadow-xl backdrop-blur">
        {text}
      </div>
    </div>
  );
}
