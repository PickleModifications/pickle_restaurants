import { useEffect, useMemo, useRef, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { Badge } from "@/components/ui/badge";
import { X, Flame, CupSoda, Sandwich, UtensilsCrossed, Carrot, ChefHat } from "lucide-react";
import { cn } from "@/lib/utils";

type Ingredient = { kind: string; item: string; label: string; image?: string; count?: number; canMake?: boolean; model?: string; dual?: boolean };
type SideInfo = { state: string; percent: number; cooking?: boolean };
type TrayEntry = { item: string; cheese?: number; count: number; label?: string; image?: string; model?: string; dual?: boolean; cheeseModel?: string };
// A buildable recipe (kitchen prep) with its output + components resolved for the tooltip.
type RecipeComp = { item: string; label: string; image?: string };
type RecipeCat = { output: string; label: string; image?: string; components: RecipeComp[] };
// The hovered stack's live snapshot: where it is on screen + what it provides.
type PrepTip = { sid: number; onScreen: boolean; x: number; y: number; provides: Record<string, number> };
// A recipe scored against a stack: how many components are satisfied + what's short.
type Ranked = { rec: RecipeCat; matched: number; ready: boolean; missing: { item: string; label: string; image?: string; short: number }[] };
type ChipItem = {
  uid: number; onScreen: boolean; x: number; y: number;
  state?: string;                         // single items
  dual?: boolean;                         // dual patties below
  sides?: SideInfo[]; cooking?: number;   // per-face progress + which face is on the grill
  cheese?: string;                        // "none" | "applied" | "melted"
  give?: string; giveLabel?: string; giveImage?: string;
};

const STOVE_VIEWS = [
  { key: "stovetop", label: "Stovetop" },
  { key: "door1", label: "Oven Door #1" },
  { key: "door2", label: "Oven Door #2" },
];

const STATION_META: Record<string, { label: string; icon: any; hint: string }> = {
  fryer: { label: "Fryer", icon: Flame, hint: "Drag raw food into the fryer. It cooks, then burns if you wait too long." },
  stovetop: { label: "Stovetop", icon: Flame, hint: "Drag patties onto the grill. Hover a patty for its status, click it to flip." },
  soda_machine: { label: "Soda Machine", icon: CupSoda, hint: "Drag a cup out to fill a drink." },
  kitchen_prep: { label: "Kitchen Prep", icon: Sandwich, hint: "Stack ingredients on the table, then hover a stack to pick a recipe and make it." },
};

const STATE_STYLE: Record<string, { label: string; cls: string }> = {
  raw: { label: "Raw", cls: "bg-rose-500/80 border-rose-300" },
  filling: { label: "Filling…", cls: "bg-sky-500/80 border-sky-300" },
  cooked: { label: "Cooked", cls: "bg-emerald-500/80 border-emerald-300" },
  done: { label: "Ready", cls: "bg-emerald-500/80 border-emerald-300" },
  burnt: { label: "Burnt", cls: "bg-zinc-800/90 border-zinc-500" },
};

const stateMeta = (s?: string) => STATE_STYLE[s || "raw"] || STATE_STYLE.raw;

// Item thumbnail that quietly disappears if the inventory has no image for it.
function ItemThumb({ src, alt, className }: { src?: string; alt: string; className?: string }) {
  const [broken, setBroken] = useState(false);
  useEffect(() => setBroken(false), [src]);
  if (!src || broken) return null;
  return <img src={src} alt={alt} draggable={false} onError={() => setBroken(true)} className={className} />;
}

const inRect = (x: number, y: number, r: DOMRect) =>
  x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;

// ── hover status panel ────────────────────────────────────────────────────────

function SideRow({ name, side }: { name: string; side?: SideInfo }) {
  const st = stateMeta(side?.state);
  const cooking = !!side?.cooking;
  const done = side?.state === "burnt";
  const pct = Math.round((side?.percent ?? 0) * 100);
  return (
    <div className={cn("rounded-md border px-2 py-1.5",
      cooking ? "border-primary/50 bg-primary/10" : "border-white/10 bg-black/25")}>
      <div className="flex items-center justify-between text-[11px]">
        <span className="flex items-center gap-1 text-muted-foreground">
          <Flame className={cn("h-3 w-3", cooking ? "text-primary" : "text-transparent")} />
          {name}
        </span>
        <span className={cn("rounded px-1.5 py-0.5 text-[10px] font-semibold text-white", st.cls)}>{st.label}</span>
      </div>
      <div className="mt-1 flex items-center gap-1.5">
        <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
          <div
            className={cn("h-full rounded-full transition-[width] duration-150 ease-linear",
              done ? "bg-zinc-500" : cooking ? "bg-primary" : "bg-primary/40")}
            style={{ width: `${pct}%` }}
          />
        </div>
        <span className="shrink-0 text-[9px] tabular-nums text-muted-foreground">
          {done ? "Done" : `${pct}%`}
        </span>
      </div>
    </div>
  );
}

function StatusPanel({ c }: { c: ChipItem }) {
  if (!c.dual) {
    const st = stateMeta(c.state);
    return (
      <div className="flex items-center gap-2 rounded-lg border border-border bg-card px-3 py-2 text-xs font-semibold shadow-2xl">
        <span className={cn("rounded px-1.5 py-0.5 text-[10px] text-white", st.cls)}>{st.label}</span>
      </div>
    );
  }
  const sides = c.sides || [];
  return (
    <div className="w-60 rounded-xl border border-border bg-card p-3 shadow-2xl">
      <div className="flex items-center gap-2">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-muted/50">
          <ItemThumb src={c.giveImage} alt={c.giveLabel || ""} className="h-9 w-9 object-contain" />
        </div>
        <div className="min-w-0">
          <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">Collect now</div>
          <div className="truncate text-sm font-semibold">{c.giveLabel || "—"}</div>
        </div>
      </div>

      {/* both faces with their own progress; the flame marks the grill side */}
      <div className="mt-2.5 space-y-1.5">
        <SideRow name="Side 1" side={sides[0]} />
        <SideRow name="Side 2" side={sides[1]} />
      </div>

      {c.cheese && c.cheese !== "none" && (
        <div className="mt-2 flex items-center gap-1.5 text-[11px] text-amber-300">
          🧀 {c.cheese === "melted" ? "Cheese melted" : "Cheese melting…"}
        </div>
      )}
    </div>
  );
}

// Rank recipes for a stack, Minecraft-style: the ones it most relates to first.
// Score by components already satisfied (desc), then ready recipes, then fewest
// missing. Only the required components matter — extras on the stack (an alteration,
// e.g. a donut on a burger) never disqualify a recipe. Top 3 are shown.
function rankRecipes(recipes: RecipeCat[], provides: Record<string, number>): Ranked[] {
  const scored = recipes.map((rec) => {
    const need: Record<string, number> = {};
    const meta: Record<string, { label: string; image?: string }> = {};
    rec.components.forEach((c) => {
      need[c.item] = (need[c.item] || 0) + 1;
      meta[c.item] = { label: c.label, image: c.image };
    });
    let matched = 0;
    const missing: Ranked["missing"] = [];
    for (const item in need) {
      const have = provides[item] || 0;
      matched += Math.min(have, need[item]);
      if (have < need[item]) missing.push({ item, label: meta[item].label, image: meta[item].image, short: need[item] - have });
    }
    return { rec, matched, ready: missing.length === 0, missing };
  });
  return scored
    // only recipes the stack actually relates to (shares at least one component)
    .filter((s) => s.matched > 0)
    .sort(
      (a, b) =>
        b.matched - a.matched ||
        Number(b.ready) - Number(a.ready) ||
        a.missing.length - b.missing.length ||
        a.rec.label.localeCompare(b.rec.label)
    )
    .slice(0, 3);
}

// Floating recipe guide over the hovered stack. Shows the 3 most-related recipes as
// clickable thumbnails (first selected by default); the selected one lists what's
// still missing, and reveals a Make button once the stack satisfies it.
function BuildTooltip({
  ranked, selected, onSelect, onMake, onPin,
}: {
  ranked: Ranked[];
  selected: Ranked | null;
  onSelect: (output: string) => void;
  onMake: () => void;
  onPin: (pinned: boolean) => void;
}) {
  return (
    <div
      onPointerEnter={() => onPin(true)}
      onPointerLeave={() => onPin(false)}
      className="w-64 rounded-xl border border-border bg-card p-3 shadow-2xl"
    >
      {ranked.length === 0 ? (
        <div className="text-xs text-muted-foreground">No matching recipes.</div>
      ) : (
        <>
          <div className="mb-2 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            Recipes — click to compare
          </div>
          <div className="flex gap-2">
            {ranked.map((r) => {
              const active = selected?.rec.output === r.rec.output;
              return (
                <button
                  key={r.rec.output}
                  onClick={() => onSelect(r.rec.output)}
                  title={r.rec.label}
                  className={cn(
                    "relative flex h-14 w-14 shrink-0 items-center justify-center rounded-lg border bg-muted/40 transition",
                    active ? "border-primary ring-2 ring-primary/50" : "border-border hover:border-primary/60"
                  )}
                >
                  <ItemThumb src={r.rec.image} alt={r.rec.label} className="h-10 w-10 object-contain" />
                  {r.ready && (
                    <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-emerald-500 text-[9px] font-bold text-white">
                      ✓
                    </span>
                  )}
                </button>
              );
            })}
          </div>

          {selected && (
            <div className="mt-3">
              <div className="truncate text-sm font-semibold">{selected.rec.label}</div>
              {selected.ready ? (
                <div className="mt-1 text-[11px] font-medium text-emerald-400">Ready to make</div>
              ) : (
                <>
                  <div className="mt-1.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
                    Still needs
                  </div>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {selected.missing.map((m) => (
                      <span
                        key={m.item}
                        className="flex items-center gap-1 rounded bg-secondary px-1.5 py-0.5 text-[11px]"
                      >
                        <ItemThumb src={m.image} alt={m.label} className="h-4 w-4 object-contain" />
                        {m.label}{m.short > 1 ? ` ×${m.short}` : ""}
                      </span>
                    ))}
                  </div>
                </>
              )}
              <button
                disabled={!selected.ready}
                onClick={onMake}
                className={cn(
                  "mt-3 w-full rounded-md px-3 py-1.5 text-xs font-semibold transition",
                  selected.ready
                    ? "bg-primary text-primary-foreground hover:opacity-90"
                    : "cursor-not-allowed bg-muted text-muted-foreground"
                )}
              >
                Make
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function Cooking({ data }: { data: any }) {
  const [station, setStation] = useState<string>(data?.station || "fryer");
  const [ingredients, setIngredients] = useState<Ingredient[]>(data?.ingredients || []);
  const [items, setItems] = useState<ChipItem[]>([]);
  const [hovered, setHovered] = useState<number | null>(null);
  const [view, setView] = useState<string>("stovetop");
  const [tray, setTray] = useState<TrayEntry[]>([]);
  const [tab, setTab] = useState<"ingredients" | "cooked">("ingredients");
  // kitchen-prep recipe catalogue + the hovered stack's live tooltip snapshot
  const [recipes, setRecipes] = useState<RecipeCat[]>([]);
  const [tip, setTip] = useState<PrepTip | null>(null);
  const [tipShow, setTipShow] = useState(false);
  const [selectedOutput, setSelectedOutput] = useState<string | null>(null);
  // last hovered uid — keeps the tooltip's (live) content during fade-out
  const [lastUid, setLastUid] = useState<number | null>(null);
  const [dragging, setDragging] = useState(false);
  // instructional drop-zone shown while a drag is in progress (null = no drag)
  const [dragHint, setDragHint] = useState<string | null>(null);
  // floating 2D ghost for a topping (cheese) drag onto a patty
  const [ghost, setGhost] = useState<{ x: number; y: number; label: string; image?: string } | null>(null);

  const barRef = useRef<HTMLDivElement>(null);
  const tipPinnedRef = useRef(false);           // cursor is over the build tooltip
  const tipHideTimer = useRef<number | null>(null);
  const itemsRef = useRef<ChipItem[]>([]);
  const hoveredRef = useRef<number | null>(null);
  const placingRef = useRef(false);          // dragging an ingredient out of the bar
  const toppingRef = useRef<string | null>(null); // dragging a topping (cheese) onto a patty
  const prepDragRef = useRef<{ source: string; item: string; cheese: number; model?: string | null } | null>(null); // dragging a NEW part onto the prep table
  const prepHoveredRef = useRef<number | null>(null); // placed prep part under the cursor (grab target)
  const prepMoveRef = useRef<{ puid: number } | null>(null); // re-dragging a placed prep part
  const worldRef = useRef<{ uid: number | null; startX: number; startY: number; dragging: boolean } | null>(null);

  useEffect(() => {
    setStation(data?.station || "fryer");
    setIngredients(data?.ingredients || []);
    setView("stovetop");
    setTab("ingredients");
    setTip(null);
    setTipShow(false);
  }, [data]);

  useNuiEvent("cookingIngredients", (d) => setIngredients(d.ingredients || []));
  useNuiEvent("cookingTray", (d) => setTray(d.tray || []));
  useNuiEvent("cookingRecipes", (d) => setRecipes(d.recipes || []));
  useNuiEvent("cookingItems", (d) => {
    const its: ChipItem[] = d.items || [];
    itemsRef.current = its;
    hoveredRef.current = d.hovered ?? null;
    prepHoveredRef.current = d.prepHovered ?? null;
    setItems(its);
    setHovered(d.hovered ?? null);

    // Prep tooltip: the client sends the hovered stack (or nothing). While a stack
    // is hovered, keep the tooltip live and shown; when the cursor leaves, hold it
    // briefly so the player can travel onto it to click — and keep it up as long as
    // the cursor is actually over it (pinned).
    const pt: PrepTip | null = d.prepTip ?? null;
    if (pt) {
      if (tipHideTimer.current) { clearTimeout(tipHideTimer.current); tipHideTimer.current = null; }
      setTip(pt);
      setTipShow(true);
    } else if (!tipPinnedRef.current && tipShow && !tipHideTimer.current) {
      tipHideTimer.current = window.setTimeout(() => {
        tipHideTimer.current = null;
        if (!tipPinnedRef.current) setTipShow(false);
      }, 220);
    }
  });

  const isStove = station === "stovetop";
  const isPrep = station === "kitchen_prep";
  const trayTotal = tray.reduce((n, e) => n + e.count, 0);
  const switchView = (key: string) => {
    setView(key);
    fetchNui("cooking:setView", { view: key });
  };

  // Always render the *live* item for the active uid (never a frozen snapshot),
  // so a flip's swapped top/bottom + progress update immediately. The tooltip
  // fades when nothing is hovered or while dragging.
  useEffect(() => {
    if (hovered != null) setLastUid(hovered);
  }, [hovered]);
  const activeUid = hovered ?? lastUid;
  const shownChip = activeUid != null ? items.find((c) => c.uid === activeUid) : undefined;
  const panelVisible = hovered != null && !!shownChip && !!shownChip.onScreen && !dragging;

  // ── prep recipe tooltip: rank recipes for the hovered stack, keep a selection ──
  const ranked = useMemo(
    () => (tip ? rankRecipes(recipes, tip.provides || {}) : []),
    [recipes, tip]
  );
  // Default the selection to the most-related recipe; keep the player's pick while
  // it stays in the top 3, otherwise fall back to the first.
  const selected = ranked.find((r) => r.rec.output === selectedOutput) || ranked[0] || null;
  useEffect(() => {
    if (ranked.length && !ranked.some((r) => r.rec.output === selectedOutput)) {
      setSelectedOutput(ranked[0].rec.output);
    }
  }, [ranked, selectedOutput]);
  // A fresh stack resets the pick to its top recipe.
  useEffect(() => { setSelectedOutput(null); }, [tip?.sid]);

  const tipVisible = isPrep && tipShow && !!tip && !!tip.onScreen && !dragging && ranked.length > 0;
  const onTipPin = (pinned: boolean) => {
    tipPinnedRef.current = pinned;
    if (pinned) {
      if (tipHideTimer.current) { clearTimeout(tipHideTimer.current); tipHideTimer.current = null; }
    } else {
      setTipShow(false); // left the tooltip and the stack — dismiss
    }
  };
  const onTipMake = () => {
    if (!tip || !selected?.ready) return;
    fetchNui("cooking:prepMakeStack", { sid: tip.sid, output: selected.rec.output });
    setTipShow(false);
    setTip(null);
    tipPinnedRef.current = false;
  };

  // ── drag ingredients out of the bar (live in-world placement) ───────────────
  const startPlace = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    placingRef.current = true;
    setTab("ingredients");
    setDragging(true);
    fetchNui("cooking:beginPlace", { kind: ing.kind, item: ing.item });
  };
  // toppings (cheese) aren't placed in the world — they're dragged onto a patty.
  // The real slice prop renders in 3D under the cursor (no 2D pill); releasing
  // over a cooked patty applies it.
  const startTopping = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    toppingRef.current = ing.item;
    setTab("ingredients");
    setDragging(true);
    fetchNui("cooking:beginTopping", { item: ing.item, model: ing.model });
  };
  // at the prep station, drag a tray item / ingredient onto the table to add a
  // layer. With a model it spawns a live 3D prop that follows the cursor (like the
  // stovetop); without one it falls back to a 2D ghost + auto-stack.
  const startPrepDrag = (
    e: React.PointerEvent, source: string,
    entry: { item: string; cheese?: number; model?: string; label?: string; image?: string; dual?: boolean; cheeseModel?: string }
  ) => {
    e.preventDefault();
    // A bun is one item spawned as a bottom+top pair (handled client-side), so no
    // half hint is needed here.
    prepDragRef.current = { source, item: entry.item, cheese: entry.cheese || 0, model: entry.model || null };
    setTab(source === "tray" ? "cooked" : "ingredients");
    setDragging(true);
    setDragHint("Drop on the prep table — or onto another item to stack");
    if (entry.model) {
      fetchNui("cooking:beginPrepPlace", {
        item: entry.item, model: entry.model,
        dual: entry.dual ? 1 : 0, cheese: entry.cheese || 0, cheeseModel: entry.cheeseModel,
      });
    } else {
      setGhost({ x: e.clientX, y: e.clientY, label: entry.label || entry.item, image: entry.image });
    }
  };

  // ── world interaction: drag the real prop, or click it (flip) / the grill ───
  const onWorldDown = (e: React.PointerEvent) => {
    if (e.button !== 0) return;
    e.preventDefault();
    // at prep, pressing on a placed part grabs it to restack freely
    if (isPrep) {
      const puid = prepHoveredRef.current;
      if (puid != null) {
        prepMoveRef.current = { puid };
        setDragging(true);
        setDragHint("Drag onto another item to stack — drop on the bar to remove");
        fetchNui("cooking:prepGrab", { puid });
      }
      return;
    }
    worldRef.current = { uid: hoveredRef.current, startX: e.clientX, startY: e.clientY, dragging: false };
  };

  useEffect(() => {
    const DRAG_THRESH = 49; // px^2 (~7px) before a press becomes a drag (vs a click/flip)
    const onMove = (e: PointerEvent) => {
      // only the no-model prep fallback uses a 2D ghost now (everything else is 3D)
      if (prepDragRef.current && !prepDragRef.current.model) setGhost((g) => (g ? { ...g, x: e.clientX, y: e.clientY } : g));
      const w = worldRef.current;
      if (w && w.uid != null && !w.dragging) {
        const dx = e.clientX - w.startX, dy = e.clientY - w.startY;
        if (dx * dx + dy * dy > DRAG_THRESH) {
          w.dragging = true;
          setDragging(true); // hide the tooltip while moving the prop
          setTab("cooked");  // dragging a cooked prop -> show where it'll land
          fetchNui("cooking:beginMove", { uid: w.uid });
        }
      }
    };
    const onUp = (e: PointerEvent) => {
      const overBar = !!barRef.current && inRect(e.clientX, e.clientY, barRef.current.getBoundingClientRect());
      setDragging(false);
      setDragHint(null);

      // re-dragged a placed prep part: drop on the bar removes it, else it stays
      if (prepMoveRef.current) {
        prepMoveRef.current = null;
        fetchNui("cooking:prepDrop", { cancel: overBar });
        return;
      }

      // topping (cheese) dropped onto a patty — the live 3D slice ends here; the
      // server sticks it on the hovered patty (or it just cancels).
      if (toppingRef.current) {
        toppingRef.current = null;
        const uid = hoveredRef.current;
        fetchNui("cooking:endTopping", { uid: overBar ? null : uid, cancel: overBar });
        return;
      }

      // prep-table drag dropped onto the table (anywhere but the bar)
      if (prepDragRef.current) {
        const p = prepDragRef.current;
        prepDragRef.current = null;
        setGhost(null);
        if (p.model) {
          // live 3D placement — commit (or cancel back over the bar)
          fetchNui("cooking:endPrepPlace", { cancel: overBar, source: p.source, item: p.item, cheese: p.cheese });
        } else if (!overBar) {
          fetchNui("cooking:prepAdd", { source: p.source, item: p.item, cheese: p.cheese });
        }
        return;
      }

      // ingredient placement from the bar
      if (placingRef.current) {
        placingRef.current = false;
        fetchNui("cooking:endPlace", { cancel: overBar });
      }

      // world prop interaction
      const w = worldRef.current;
      worldRef.current = null;
      if (w) {
        if (w.uid != null) {
          if (w.dragging) {
            if (overBar) fetchNui("cooking:collect", { uid: w.uid });
            else fetchNui("cooking:endMove", { cancel: false });
          } else {
            // a click (no drag) on a patty flips it; only dual patties flip
            const it = itemsRef.current.find((c) => c.uid === w.uid);
            if (it?.dual) fetchNui("cooking:flip", { uid: w.uid });
          }
        } else if (!w.dragging) {
          // clicked empty grill -> toggle the oven door under the cursor
          fetchNui("cooking:worldClick");
        }
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
      {/* world layer — press to grab/drag the hovered prop, click to flip it or
          toggle an oven door. The status panel above sits over this layer but is
          click-through, so clicks still reach the patty. */}
      <div className="fixed inset-0" onPointerDown={onWorldDown} />

      {/* instructional dotted drop-zone shown while dragging an item */}
      {dragHint && (
        <div className="pointer-events-none fixed inset-x-0 bottom-44 top-20 z-30 flex items-center justify-center px-6">
          <div className="flex flex-col items-center gap-2 rounded-2xl border-2 border-dashed border-primary/60 bg-primary/5 px-12 py-10 text-center">
            <UtensilsCrossed className="h-8 w-8 text-primary/80" />
            <span className="text-sm font-semibold text-primary">{dragHint}</span>
          </div>
        </div>
      )}

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

      {/* hover status panel — fades in/out over the hovered prop, click-through */}
      <div
        className={cn(
          "pointer-events-none fixed z-40 -translate-x-1/2 -translate-y-[120%] transition-all duration-200 ease-out",
          panelVisible ? "opacity-100 scale-100" : "opacity-0 scale-95"
        )}
        style={{ left: `${(shownChip?.x ?? 0.5) * 100}%`, top: `${(shownChip?.y ?? 0.5) * 100}%` }}
      >
        <div className="relative">
          {shownChip && <StatusPanel c={shownChip} />}
          {/* caret pointing down at the prop */}
          <div className="absolute left-1/2 top-full h-0 w-0 -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-card" />
        </div>
      </div>

      {/* prep recipe tooltip — floats over the hovered stack; interactive (unlike the
          status panel) so recipes can be picked and the stack built from here */}
      <div
        className={cn(
          "fixed z-40 -translate-x-1/2 -translate-y-[120%] transition-all duration-200 ease-out",
          tipVisible ? "opacity-100 scale-100" : "pointer-events-none opacity-0 scale-95"
        )}
        style={{ left: `${(tip?.x ?? 0.5) * 100}%`, top: `${(tip?.y ?? 0.5) * 100}%` }}
      >
        <div className="relative">
          <BuildTooltip ranked={ranked} selected={selected} onSelect={setSelectedOutput} onMake={onTipMake} onPin={onTipPin} />
          <div className="absolute left-1/2 top-full h-0 w-0 -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-card" />
        </div>
      </div>

      {/* floating ghost while dragging a topping (cheese) onto a patty */}
      {ghost && (
        <div
          style={{ left: ghost.x, top: ghost.y }}
          className="pointer-events-none fixed z-50 flex -translate-x-1/2 -translate-y-1/2 items-center gap-1.5 rounded-lg border border-primary/60 bg-card px-2 py-1 text-xs font-semibold shadow-2xl"
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

        {/* tabs: raw ingredients vs the persistent Cooked Items tray */}
        <div className="mb-2 flex gap-1">
          {([["ingredients", "Ingredients", Carrot], ["cooked", "Cooked Items", ChefHat]] as const).map(
            ([key, label, TabIcon]) => (
              <button
                key={key}
                onClick={() => setTab(key)}
                className={cn(
                  "flex items-center gap-1.5 rounded-md px-3 py-1 text-xs font-semibold transition",
                  tab === key ? "bg-primary text-primary-foreground" : "bg-secondary text-muted-foreground hover:bg-accent"
                )}
              >
                <TabIcon className="h-3.5 w-3.5" />
                {label}
                {key === "cooked" && trayTotal > 0 ? ` (${trayTotal})` : ""}
              </button>
            )
          )}
        </div>

        {tab === "ingredients" ? (
          <div className="flex gap-2 overflow-x-auto pb-1">
            {ingredients.length === 0 && (
              <div className="py-4 text-sm text-muted-foreground">You have no ingredients for this station.</div>
            )}
            {ingredients.map((ing, i) => {
              const can = draggable(ing);
              const onDown = (e: React.PointerEvent) => {
                if (!can) return;
                if (ing.kind === "topping") startTopping(e, ing);
                else if (isPrep) startPrepDrag(e, "inv", { item: ing.item, cheese: 0, model: ing.model, label: ing.label, image: ing.image, dual: ing.dual });
                else startPlace(e, ing);
              };
              return (
                <div
                  key={ing.item + i}
                  onPointerDown={onDown}
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
                    <Badge variant="secondary" className="absolute right-1 top-1">{ing.count ?? 0}</Badge>
                  )}
                  {ing.kind === "assembly" && !ing.canMake && (
                    <span className="text-[10px] text-muted-foreground">missing parts</span>
                  )}
                </div>
              );
            })}
          </div>
        ) : (
          <div className="flex gap-2 overflow-x-auto pb-1">
            {tray.length === 0 && (
              <div className="py-4 text-sm text-muted-foreground">No cooked items yet — cook something and collect it.</div>
            )}
            {tray.map((e, i) => (
              <div
                key={e.item + "|" + (e.cheese || 0) + "|" + i}
                onPointerDown={(ev) => isPrep && startPrepDrag(ev, "tray", e)}
                className={cn(
                  "relative flex h-24 w-28 shrink-0 touch-none select-none flex-col items-center justify-center gap-1 rounded-lg border border-border bg-secondary text-center text-xs font-medium",
                  isPrep ? "cursor-grab hover:border-primary/60 active:cursor-grabbing" : ""
                )}
              >
                <ItemThumb src={e.image} alt={e.label || e.item} className="h-10 w-10 object-contain" />
                <span className="px-1 leading-tight">{e.label || e.item}</span>
                <Badge variant="secondary" className="absolute right-1 top-1">{e.count}</Badge>
                {!!e.cheese && <span className="absolute left-1 top-1 text-sm">🧀</span>}
                {!isPrep && (
                  <button
                    onClick={() => fetchNui("cooking:trayToInventory", { item: e.item, cheese: e.cheese || 0, count: 1 })}
                    className="mt-0.5 rounded bg-background/60 px-1.5 py-0.5 text-[10px] hover:bg-accent"
                  >
                    → inventory
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </>
  );
}
