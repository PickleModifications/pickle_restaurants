import { useEffect, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { _L } from "@/lib/locale";
import { cn } from "@/lib/utils";
import type { Crop } from "@/components/Branding";

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
  // USED rather than eaten (a DLC toy laid on the tray with the meal): there is no
  // "one bite vs finish it" to choose between, so the tooltip collapses to one button
  play?: boolean;
  // the food's own crop for `image` ({x,y,w,h}, 0..1) — the tooltip frames exactly
  // the rectangle the admin chose rather than letterboxing the whole picture
  crop?: Crop | null;
  // mouthfuls left on this serving; shown on the "take a bite" button
  bitesLeft?: number;
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

  // BOTH actions are buttons on the tooltip. Clicking the world eats nothing:
  // "click to take a bite" and "a button to finish" were two gestures aimed at the
  // same thing, and which one you got depended on hitting a button you might not
  // have noticed. One row, two explicit choices.
  const act = async (event: string) => {
    if (busy || hover.index == null) return;
    setBusy(true);
    await fetchNui(event);
    setBusy(false);
  };

  const has = hover.index != null && !!hover.label;

  return (
    <div className="h-full w-full select-none">
      {/* hovered food: the same card language the kitchen's bar tooltip uses */}
      {has && (
        <div
          className="pointer-events-none fixed z-40 -translate-x-1/2 -translate-y-[140%]"
          style={{ left: `${(hover.x ?? 0.5) * 100}%`, top: `${(hover.y ?? 0.5) * 100}%` }}
        >
          {/* pointer-events-auto ONLY on the card: the tooltip carries the buttons,
              while the rest of the screen stays a click-through surface for the world */}
          {/* PIN the world hover while the cursor is on the card. The buttons sit
              above the pile, so reaching for one leaves the pile's hover radius and
              Lua would otherwise drop the target out from under the click. Lua holds
              a lost pile briefly on its own, which covers the gap between the food
              and this card; the pin covers the rest of the reach. */}
          <div
            onPointerEnter={() => fetchNui("dining:pin", { on: true })}
            onPointerLeave={() => fetchNui("dining:pin", { on: false })}
            className="pointer-events-auto w-60 rounded-xl border border-border bg-card p-3 text-center shadow-2xl"
          >
            {hover.image && (
              <div className="mx-auto h-12 w-12 overflow-hidden rounded">
                <img
                  src={hover.image}
                  alt={hover.label}
                  className="h-full w-full object-cover"
                  // Honour the admin's crop: scale the picture so the chosen
                  // rectangle fills the frame, then offset to it. Falls back to a
                  // plain cover when the food never had one cropped.
                  style={
                    hover.crop && hover.crop.w > 0 && hover.crop.h > 0
                      ? {
                          width: `${100 / hover.crop.w}%`,
                          height: `${100 / hover.crop.h}%`,
                          objectFit: "cover",
                          transform: `translate(${-hover.crop.x * 100}%, ${-hover.crop.y * 100}%)`,
                          transformOrigin: "top left",
                          maxWidth: "none",
                        }
                      : undefined
                  }
                />
              </div>
            )}
            <div className="mt-1.5 text-sm font-semibold leading-tight">{hover.label}</div>
            {/* one row, two buttons: a single mouthful (with how many are left) or
                the whole serving. A thing that is USED rather than eaten (a toy) is
                one action — offering it "one bite" of a plush would be nonsense — so
                it collapses to the single button. */}
            <div className="mt-2.5 flex gap-1.5">
              {hover.play ? (
                <button
                  disabled={busy}
                  onClick={() => act("dining:finish")}
                  className="flex-1 rounded-md bg-primary px-2 py-1.5 text-xs font-semibold text-primary-foreground transition hover:opacity-90 disabled:cursor-not-allowed disabled:bg-muted disabled:text-muted-foreground"
                >
                  {_L("dining.play_with")}
                </button>
              ) : (
                <>
                  <button
                    disabled={busy}
                    onClick={() => act("dining:bite")}
                    className="flex-1 rounded-md bg-secondary px-2 py-1.5 text-xs font-semibold transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {_L(hover.drink ? "dining.take_sip" : "dining.take_bite")}
                    <span className="ml-1 font-mono tabular-nums opacity-60">({hover.bitesLeft ?? 1})</span>
                  </button>
                  <button
                    disabled={busy}
                    onClick={() => act("dining:finish")}
                    className="flex-1 rounded-md bg-primary px-2 py-1.5 text-xs font-semibold text-primary-foreground transition hover:opacity-90 disabled:cursor-not-allowed disabled:bg-muted disabled:text-muted-foreground"
                  >
                    {_L(hover.drink ? "dining.finish_drink" : "dining.finish_food")}
                  </button>
                </>
              )}
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
