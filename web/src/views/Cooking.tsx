import { useEffect, useRef, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { Badge } from "@/components/ui/badge";
import { X, Flame, CupSoda, Sandwich, UtensilsCrossed } from "lucide-react";
import { cn } from "@/lib/utils";

type Ingredient = { kind: string; item: string; label: string; image?: string; count?: number; canMake?: boolean };
type ChipItem = { uid: number; state: string; onScreen: boolean; x: number; y: number; dual?: boolean; sides?: string[] };

type Drag = { mode: "place" } | { mode: "chip"; uid: number };

const STOVE_VIEWS = [
  { key: "stovetop", label: "Stovetop" },
  { key: "door1", label: "Oven Door #1" },
  { key: "door2", label: "Oven Door #2" },
];

const STATION_META: Record<string, { label: string; icon: any; hint: string }> = {
  fryer: { label: "Fryer", icon: Flame, hint: "Drag raw food into the fryer. It cooks, then burns if you wait too long." },
  stovetop: { label: "Stovetop", icon: Flame, hint: "Drag patties onto the stovetop to cook them." },
  soda_machine: { label: "Soda Machine", icon: CupSoda, hint: "Drag a cup out to fill a drink." },
  kitchen_prep: { label: "Kitchen Prep", icon: Sandwich, hint: "Drag a recipe out to assemble it from your components." },
};

const STATE_STYLE: Record<string, { label: string; cls: string }> = {
  raw: { label: "Raw", cls: "bg-rose-500/80 border-rose-300" },
  filling: { label: "Filling…", cls: "bg-sky-500/80 border-sky-300" },
  cooked: { label: "Cooked", cls: "bg-emerald-500/80 border-emerald-300" },
  done: { label: "Ready", cls: "bg-emerald-500/80 border-emerald-300" },
  burnt: { label: "Burnt", cls: "bg-zinc-800/90 border-zinc-500" },
};

// Item thumbnail that quietly disappears if the inventory has no image for it.
function ItemThumb({ src, alt, className }: { src?: string; alt: string; className?: string }) {
  const [broken, setBroken] = useState(false);
  useEffect(() => setBroken(false), [src]);
  if (!src || broken) return null;
  return <img src={src} alt={alt} draggable={false} onError={() => setBroken(true)} className={className} />;
}

const inRect = (x: number, y: number, r: DOMRect) =>
  x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;

export default function Cooking({ data }: { data: any }) {
  const [station, setStation] = useState<string>(data?.station || "fryer");
  const [ingredients, setIngredients] = useState<Ingredient[]>(data?.ingredients || []);
  const [chips, setChips] = useState<ChipItem[]>([]);
  const [view, setView] = useState<string>("stovetop");
  const [ghost, setGhost] = useState<{ x: number; y: number; label: string; image?: string } | null>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<Drag | null>(null);

  useEffect(() => {
    setStation(data?.station || "fryer");
    setIngredients(data?.ingredients || []);
    setView("stovetop");
  }, [data]);

  useNuiEvent("cookingIngredients", (d) => setIngredients(d.ingredients || []));
  useNuiEvent("cookingItems", (d) => setChips((d.items || []).filter((i: ChipItem) => i.onScreen)));

  const isStove = station === "stovetop";
  const switchView = (key: string) => {
    setView(key);
    fetchNui("cooking:setView", { view: key });
  };

  // ── pointer drag (HTML5 DnD is unreliable in CEF) ──────────────────────────
  // Ingredients use live in-world placement: the real prop spawns and tracks the
  // cursor in 3D, so there's no 2D ghost. Only world chips use the ghost.
  const startPlace = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    dragRef.current = { mode: "place" };
    fetchNui("cooking:beginPlace", { kind: ing.kind, item: ing.item });
  };
  // Chips drag the *real* placed prop live in 3D (no 2D ghost), the same way a
  // fresh ingredient places.
  const startChip = (e: React.PointerEvent, uid: number) => {
    e.preventDefault();
    dragRef.current = { mode: "chip", uid };
    fetchNui("cooking:beginMove", { uid });
  };

  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      if (!dragRef.current) return;
      setGhost((g) => (g ? { ...g, x: e.clientX, y: e.clientY } : g));
    };
    const onUp = (e: PointerEvent) => {
      const drag = dragRef.current;
      dragRef.current = null;
      setGhost(null);
      if (!drag) return;
      const overBar = !!barRef.current && inRect(e.clientX, e.clientY, barRef.current.getBoundingClientRect());
      if (drag.mode === "place") {
        // commit the live placement, or cancel if released back over the bar
        fetchNui("cooking:endPlace", { cancel: overBar });
      } else {
        // a world chip: onto the bar collects it, out in the world commits the
        // live drag at its final spot
        if (overBar) fetchNui("cooking:collect", { uid: drag.uid });
        else fetchNui("cooking:endMove", { cancel: false });
      }
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") fetchNui("cooking:close");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const meta = STATION_META[station] || STATION_META.fryer;
  const Icon = meta.icon;

  const draggable = (ing: Ingredient) => (ing.kind === "assembly" ? !!ing.canMake : (ing.count || 0) > 0);

  return (
    <>
      {/* world layer — click toggles the oven door under the cursor (stovetop) */}
      <div className="fixed inset-0" onClick={() => isStove && fetchNui("cooking:worldClick")} />

      {/* stovetop view switcher — re-frames the scripted camera onto a part */}
      {isStove && (
        <div className="fixed left-1/2 top-4 flex -translate-x-1/2 gap-1 rounded-lg border border-border bg-card/95 p-1 shadow-xl">
          {STOVE_VIEWS.map((v) => (
            <button
              key={v.key}
              onClick={() => switchView(v.key)}
              className={cn(
                "rounded-md px-3 py-1.5 text-xs font-semibold transition",
                view === v.key ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-accent"
              )}
            >
              {v.label}
            </button>
          ))}
        </div>
      )}

      {/* on-screen chips over each world food prop. Dual patties show both
          faces; click the patty in the world to flip it. */}
      {chips.map((c) => {
        const st = STATE_STYLE[c.state] || STATE_STYLE.raw;
        if (c.dual && c.sides) {
          const [a, b] = c.sides.map((s) => STATE_STYLE[s] || STATE_STYLE.raw);
          return (
            <div
              key={c.uid}
              onPointerDown={(e) => startChip(e, c.uid)}
              style={{ left: `${c.x * 100}%`, top: `${c.y * 100}%` }}
              className="fixed flex -translate-x-1/2 -translate-y-1/2 cursor-grab touch-none select-none overflow-hidden rounded-full border border-white/30 text-[11px] font-semibold text-white shadow-lg active:cursor-grabbing"
            >
              <span className={cn("px-2 py-0.5", a.cls)}>{a.label}</span>
              <span className={cn("px-2 py-0.5", b.cls)}>{b.label}</span>
            </div>
          );
        }
        return (
          <div
            key={c.uid}
            onPointerDown={(e) => startChip(e, c.uid)}
            style={{ left: `${c.x * 100}%`, top: `${c.y * 100}%` }}
            className={cn(
              "fixed -translate-x-1/2 -translate-y-1/2 cursor-grab touch-none select-none rounded-full border px-2 py-0.5 text-[11px] font-semibold text-white shadow-lg active:cursor-grabbing",
              st.cls
            )}
          >
            {st.label}
          </div>
        );
      })}

      {/* the floating drag preview that follows the cursor */}
      {ghost && (
        <div
          style={{ left: ghost.x, top: ghost.y }}
          className="pointer-events-none fixed z-50 flex -translate-x-1/2 -translate-y-1/2 items-center gap-1.5 rounded-lg border border-primary/60 bg-card/95 px-2 py-1 text-xs font-semibold shadow-2xl"
        >
          <ItemThumb src={ghost.image} alt={ghost.label} className="h-6 w-6 object-contain" />
          {ghost.label}
        </div>
      )}

      {/* full-width bottom bar */}
      <div
        ref={barRef}
        className="fixed inset-x-0 bottom-0 animate-fade-in border-t border-border bg-card px-4 py-3 shadow-2xl"
      >
        <div className="mb-2 flex items-center justify-between">
          <div className="flex items-center gap-2 text-sm font-semibold">
            <Icon className="h-4 w-4 text-primary" />
            {meta.label}
            <span className="ml-2 text-xs font-normal text-muted-foreground">{meta.hint}</span>
          </div>
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <UtensilsCrossed className="h-3.5 w-3.5" />
            Drag a cooked item here to collect it
            <button onClick={() => fetchNui("cooking:close")} className="ml-2 rounded-md p-1 hover:bg-accent">
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        <div className="flex gap-2 overflow-x-auto pb-1">
          {ingredients.length === 0 && (
            <div className="py-4 text-sm text-muted-foreground">You have no ingredients for this station.</div>
          )}
          {ingredients.map((ing, i) => {
            const can = draggable(ing);
            return (
              <div
                key={ing.item + i}
                onPointerDown={(e) => can && startPlace(e, ing)}
                className={cn(
                  "relative flex h-24 w-28 shrink-0 touch-none select-none flex-col items-center justify-center gap-1 rounded-lg border text-center text-xs font-medium",
                  can
                    ? "cursor-grab border-border bg-secondary hover:border-primary/60 active:cursor-grabbing"
                    : "cursor-not-allowed border-dashed border-border/60 bg-muted/40 opacity-60"
                )}
              >
                <ItemThumb src={ing.image} alt={ing.label} className="h-10 w-10 object-contain" />
                <span className="px-1 leading-tight">{ing.label}</span>
                {ing.kind !== "assembly" && (
                  <Badge variant="secondary" className="absolute right-1 top-1">
                    {ing.count ?? 0}
                  </Badge>
                )}
                {ing.kind === "assembly" && !ing.canMake && (
                  <span className="text-[10px] text-muted-foreground">missing parts</span>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}
