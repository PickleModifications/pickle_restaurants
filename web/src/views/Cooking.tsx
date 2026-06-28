import { useEffect, useRef, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { Badge } from "@/components/ui/badge";
import { X, Flame, CupSoda, Sandwich, UtensilsCrossed } from "lucide-react";
import { cn } from "@/lib/utils";

type Ingredient = { kind: string; item: string; label: string; count?: number; canMake?: boolean };
type ChipItem = { uid: number; state: string; onScreen: boolean; x: number; y: number };

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

// shared across drag handlers without re-rendering
let dragPayload: { type: "ingredient"; ing: Ingredient } | { type: "chip"; uid: number } | null = null;

export default function Cooking({ data }: { data: any }) {
  const [station, setStation] = useState<string>(data?.station || "fryer");
  const [ingredients, setIngredients] = useState<Ingredient[]>(data?.ingredients || []);
  const [chips, setChips] = useState<ChipItem[]>([]);
  const barRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setStation(data?.station || "fryer");
    setIngredients(data?.ingredients || []);
  }, [data]);

  useNuiEvent("cookingIngredients", (d) => setIngredients(d.ingredients || []));
  useNuiEvent("cookingItems", (d) => setChips((d.items || []).filter((i: ChipItem) => i.onScreen)));

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
      {/* world drop zone — drop ingredients here to place, drop chips to move */}
      <div
        className="fixed inset-0"
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          if (!dragPayload) return;
          if (dragPayload.type === "ingredient") {
            fetchNui("cooking:dropItem", { kind: dragPayload.ing.kind, item: dragPayload.ing.item });
          } else {
            fetchNui("cooking:move", { uid: dragPayload.uid });
          }
          dragPayload = null;
        }}
      />

      {/* on-screen chips over each world food prop */}
      {chips.map((c) => {
        const st = STATE_STYLE[c.state] || STATE_STYLE.raw;
        return (
          <div
            key={c.uid}
            draggable
            onDragStart={() => (dragPayload = { type: "chip", uid: c.uid })}
            style={{ left: `${c.x * 100}%`, top: `${c.y * 100}%` }}
            className={cn(
              "fixed -translate-x-1/2 -translate-y-1/2 cursor-grab rounded-full border px-2 py-0.5 text-[11px] font-semibold text-white shadow-lg active:cursor-grabbing",
              st.cls
            )}
          >
            {st.label}
          </div>
        );
      })}

      {/* full-width bottom bar */}
      <div
        ref={barRef}
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          e.stopPropagation();
          if (dragPayload?.type === "chip") {
            fetchNui("cooking:collect", { uid: dragPayload.uid });
          }
          dragPayload = null;
        }}
        className="fixed inset-x-0 bottom-0 animate-fade-in border-t border-border bg-card/95 px-4 py-3 shadow-2xl backdrop-blur"
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
            <button
              onClick={() => fetchNui("cooking:close")}
              className="ml-2 rounded-md p-1 hover:bg-accent"
            >
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
                draggable={can}
                onDragStart={() => can && (dragPayload = { type: "ingredient", ing })}
                className={cn(
                  "relative flex h-20 w-28 shrink-0 select-none flex-col items-center justify-center rounded-lg border text-center text-xs font-medium",
                  can
                    ? "cursor-grab border-border bg-secondary hover:border-primary/60 active:cursor-grabbing"
                    : "cursor-not-allowed border-dashed border-border/60 bg-muted/40 opacity-60"
                )}
              >
                <span className="px-1">{ing.label}</span>
                {ing.kind !== "assembly" && (
                  <Badge variant="secondary" className="absolute right-1 top-1">
                    {ing.count ?? 0}
                  </Badge>
                )}
                {ing.kind === "assembly" && !ing.canMake && (
                  <span className="mt-1 text-[10px] text-muted-foreground">missing parts</span>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}
