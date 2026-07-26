import { useEffect, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { _L } from "@/lib/locale";
import { cn } from "@/lib/utils";

// EAT-IN. The meal itself is real world props on the table in front of a seated
// customer (modules/dining lays them out with the kitchen's own renderer), so this
// view is deliberately almost nothing: a transparent click surface over the world,
// the hover tooltip for whatever the cursor is over, and a one-line hint.
//
// Clicks are resolved WORLD-side, not here: a DOM element can't sit on a 3D prop,
// so the Lua hover loop decides what's under the cursor and `dining:click` eats it
// — the same split the kitchen uses for clicking food on the prep table.

type Hover = {
  index?: number | null;
  x?: number;
  y?: number;
  label?: string;
  image?: string;
  drink?: boolean;
};

export default function Dining() {
  const [hover, setHover] = useState<Hover>({});
  const [busy, setBusy] = useState(false);

  useNuiEvent("diningHover", (d: Hover) => setHover(d || {}));

  // ESC hands the meal back (nothing is consumed) — mirrored in Lua so the props
  // and camera come down either way.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") fetchNui("dining:close");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const onClick = async () => {
    if (busy || hover.index == null) return;
    setBusy(true);
    await fetchNui("dining:click");
    setBusy(false);
  };

  const has = hover.index != null && !!hover.label;

  return (
    <div className="h-full w-full cursor-pointer select-none" onClick={onClick}>
      {/* hovered food: the same card language the kitchen's bar tooltip uses */}
      {has && (
        <div
          className="pointer-events-none fixed z-40 -translate-x-1/2 -translate-y-[140%]"
          style={{ left: `${(hover.x ?? 0.5) * 100}%`, top: `${(hover.y ?? 0.5) * 100}%` }}
        >
          <div className="w-52 rounded-xl border border-border bg-card p-3 text-center shadow-2xl">
            {hover.image && (
              <img src={hover.image} alt={hover.label} className="mx-auto h-12 w-12 object-contain" />
            )}
            <div className="mt-1.5 text-sm font-semibold leading-tight">{hover.label}</div>
            <div className="mt-1 text-[11px] text-muted-foreground">
              {_L(hover.drink ? "dining.click_to_drink" : "dining.click_to_eat")}
            </div>
          </div>
          <div className="absolute left-1/2 top-full h-0 w-0 -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-card" />
        </div>
      )}

      {/* standing hint: what this view is and how to leave it */}
      <div className="pointer-events-none fixed inset-x-0 bottom-8 flex justify-center">
        <div
          className={cn(
            "tape rounded-full border border-border bg-card/90 px-4 py-1.5 text-[11px] text-muted-foreground shadow-xl transition",
            busy && "opacity-60"
          )}
        >
          {_L("dining.hint")}
        </div>
      </div>
    </div>
  );
}
