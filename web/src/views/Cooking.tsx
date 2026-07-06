import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { Badge } from "@/components/ui/badge";
import { X, Flame, CupSoda, Sandwich, UtensilsCrossed, Carrot, ChefHat, CookingPot, Heater, Microwave, CircleDot, Search, Trash2, ChevronUp, ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";

// kind "finish" = a finish tool (frosting): flavors is picked on the card, then the
// tube is rubbed over a cooked target on the prep table until fully coated.
type Ingredient = { kind: string; item: string; label: string; image?: string; count?: number; canMake?: boolean; model?: string; dual?: boolean; flavors?: { id: string; label: string; color?: string }[] };

// Swatch colors for the flavor squares on a finish card. The config can carry a
// per-flavor `color`; these cover the default flavors on servers seeded before
// colors existed (and anything unknown gets the neutral fallback).
const FLAVOR_COLORS: Record<string, string> = {
  strawberry: "#f472b6",
  chocolate: "#8b5a2b",
  glazed: "#f0c36d",
  vanilla: "#f3e5ab",
  pickle: "#65a30d",
};
const flavorColor = (fl: { id: string; color?: string }) => fl.color || FLAVOR_COLORS[fl.id] || "#9ca3af";
type SideInfo = { state: string; percent: number; cooking?: boolean };
// One aggregated component of a build stack (bun halves collapse to one bun).
type TrayComp = { item: string; label: string; image?: string; count: number };
type TrayEntry = {
  item: string; cheese?: number; count: number; label?: string; image?: string; model?: string;
  dual?: boolean; cheeseModel?: string; decompose?: boolean; uncooked?: boolean; cookStation?: string;
  // per-build-variation identity: sig addresses exactly this variation on the server;
  // stack/stackState render its full layer tower; extras (toppings over the base
  // recipe) and comps (full component list) tell otherwise-identical entries apart.
  // source "inv" = an inventory-held product listed alongside the tray ("Item" pill).
  sig?: string; stack?: string[]; stackState?: string; extras?: TrayComp[]; comps?: TrayComp[]; source?: string;
  // a serving-tray meal: sets back down at prep as its full tray, layout intact
  meal?: boolean;
  // a finished (frosted…) product's recorded flavor, e.g. "Strawberry"
  flavorLabel?: string;
  // a burnt cook output — sorted to the back of the bar and offered the bin
  burnt?: boolean;
};
// A buildable recipe (kitchen prep) with its output + components resolved for the tooltip.
type RecipeComp = { item: string; label: string; image?: string };
type RecipeCat = { output: string; label: string; image?: string; components: RecipeComp[] };
// The hovered stack's live snapshot: where it is on screen + what it provides.
// A hovered serving tray sends { tray: true, tid, count } instead (Make Meal tooltip).
type PrepTip = {
  sid?: number; onScreen: boolean; x: number; y: number; provides?: Record<string, number>;
  tray?: boolean; tid?: number; count?: number;
};
// A recipe scored against a stack: how many components are satisfied + what's short.
type Ranked = { rec: RecipeCat; matched: number; ready: boolean; missing: { item: string; label: string; image?: string; short: number }[] };
type ChipItem = {
  uid: number; onScreen: boolean; x: number; y: number;
  state?: string;                         // single items
  dual?: boolean;                         // dual patties below
  single?: boolean;                       // oven/fryer/soda gated single item (progress below)
  locked?: boolean;                       // in a lowered fryer basket / mid-pour — can't be grabbed
  percent?: number; gate?: boolean; method?: string; burningSoon?: boolean;
  ice?: boolean; needLid?: boolean;       // soda cups: ice dispensed / lid still required
  sides?: SideInfo[]; cooking?: number;   // per-face progress + which face is on the grill
  cheese?: string;                        // "none" | "applied" | "melted"
  give?: string; giveLabel?: string; giveImage?: string;
};

// The stovetop's camera views as icon tabs (sidebar left of the item listings):
// a cooktop for the stovetop, the same oven icon twice with a #1/#2 badge.
const STOVE_VIEWS: { key: string; label: string; icon: any; num?: number }[] = [
  { key: "stovetop", label: "Stovetop", icon: Heater },
  { key: "door1", label: "Oven Door #1", icon: Microwave, num: 1 },
  { key: "door2", label: "Oven Door #2", icon: Microwave, num: 2 },
];

const STATION_META: Record<string, { label: string; icon: any; hint: string }> = {
  fryer: { label: "Fryer", icon: Flame, hint: "Drop food into a basket, then click that basket to lower it into the oil. Click it again to raise it and take the food out." },
  stovetop: { label: "Stovetop", icon: Flame, hint: "Grill patties on the cooktop (click to flip); open a door to bake cookies, cakes & pizzas inside." },
  soda_machine: { label: "Soda Machine", icon: CupSoda, hint: "Drag a cup under a tap and click the tap to pour — the middle tap adds ice. Press a lid on, then drag the drink to the bar." },
  kitchen_prep: { label: "Kitchen Prep", icon: Sandwich, hint: "Stack ingredients on the table, then hover a stack to pick a recipe and make it." },
};

const STATE_STYLE: Record<string, { label: string; cls: string }> = {
  raw: { label: "Raw", cls: "bg-rose-500/80 border-rose-300" },
  filling: { label: "Filling…", cls: "bg-sky-500/80 border-sky-300" },
  cooked: { label: "Cooked", cls: "bg-emerald-500/80 border-emerald-300" },
  done: { label: "Ready", cls: "bg-emerald-500/80 border-emerald-300" },
  burnt: { label: "Burnt", cls: "bg-zinc-800/90 border-zinc-500" },
  // soda cups
  empty: { label: "Empty", cls: "bg-zinc-600/80 border-zinc-400" },
  filled: { label: "Filled", cls: "bg-emerald-500/80 border-emerald-300" },
  capped: { label: "Ready", cls: "bg-emerald-500/80 border-emerald-300" },
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

// "+ 2 toppings" — how many extras ride on top of the base recipe (tooltip header);
// the per-topping detail lives in the "Made with" list below it.
const extrasCount = (e?: TrayEntry) => (e?.extras ?? []).reduce((n, c) => n + c.count, 0);

// ── tray-card toppings row ────────────────────────────────────────────────────
// A fixed-height row on every tray card: square icons for the toppings that fit,
// "+X" for the overflow, grey "No toppings" when the build is exactly the base
// recipe — so all cards keep the same spacing.

const TOPPING_SLOTS = 4;

function ToppingsRow({ e }: { e: TrayEntry }) {
  const units: TrayComp[] = [];
  for (const c of e.extras || []) for (let n = 0; n < c.count; n++) units.push(c);
  if (units.length === 0) {
    return <div className="flex h-[18px] items-center text-[9px] text-muted-foreground/70">No toppings</div>;
  }
  const shown = units.slice(0, units.length > TOPPING_SLOTS ? TOPPING_SLOTS - 1 : TOPPING_SLOTS);
  const over = units.length - shown.length;
  return (
    <div className="flex h-[18px] items-center justify-center gap-0.5">
      {shown.map((c, i) => (
        <div
          key={c.item + i}
          className="flex h-4 w-4 shrink-0 items-center justify-center rounded-sm border border-border/60 bg-background/60"
        >
          <ItemThumb src={c.image} alt={c.label} className="h-3.5 w-3.5 object-contain" />
        </div>
      ))}
      {over > 0 && (
        <span className="rounded-sm border border-border/60 bg-background/60 px-1 text-[9px] font-semibold tabular-nums text-muted-foreground">
          +{over}
        </span>
      )}
    </div>
  );
}

// ── bar-item hover tooltip ────────────────────────────────────────────────────
// Floats above a hovered tray/ingredient card: what the item is, what it's made
// of (with icons), its cheese state, and what you can do with it here. Anchored
// fixed so the bar's horizontal scroll can't clip it. When the entry has actions
// (Take / Discard) the tooltip is interactive — the cursor can travel onto it and
// it pins itself open while hovered, like the prep recipe tooltip.

type BarTip = { x: number; y: number; tray?: TrayEntry; ing?: Ingredient; hint?: string };

function BarTooltip({ tip, actions, onPin }: { tip: BarTip; actions?: ReactNode; onPin: (pinned: boolean) => void }) {
  const e = tip.tray;
  const ing = tip.ing;
  const label = e ? e.label || e.item : ing?.label || "";
  const image = e ? e.image : ing?.image;
  const count = e ? e.count : ing?.count;
  // clamp the w-56 (224px) card inside the viewport; the caret keeps pointing at
  // the card's centre even when the box has been shoved off-centre to fit
  const HALF = 112, MARGIN = 8;
  const x = Math.min(Math.max(tip.x, HALF + MARGIN), window.innerWidth - HALF - MARGIN);
  const caretShift = Math.min(Math.max(tip.x - x, -HALF + 16), HALF - 16);
  return (
    <div
      // NOTE: the fade-in animation lives on the INNER card — its keyframes set
      // `transform`, which would override this centering translate mid-animation
      // (the tooltip would start off to the right/below and slide into place)
      onPointerEnter={() => actions && onPin(true)}
      onPointerLeave={() => actions && onPin(false)}
      className={cn(
        "fixed z-50 -translate-x-1/2 -translate-y-[104%]",
        actions ? "pointer-events-auto" : "pointer-events-none"
      )}
      style={{ left: x, top: tip.y }}
    >
      <div className="relative w-56 animate-fade-in rounded-xl border border-border bg-card p-3 shadow-2xl">
        <div className="flex items-center gap-2">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-muted/50">
            <ItemThumb src={image} alt={label} className="h-9 w-9 object-contain" />
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-1.5">
              <span className="truncate text-sm font-semibold">{label}</span>
              {e?.source === "inv" && (
                <span className="shrink-0 rounded border border-border bg-secondary px-1 py-px text-[9px] font-semibold uppercase tracking-wide text-muted-foreground">
                  Item
                </span>
              )}
            </div>
            {e &&
              (e.meal ? (
                <div className="truncate text-[11px] font-medium text-amber-300">
                  Serving-tray meal — sets down as arranged
                </div>
              ) : e.flavorLabel ? (
                <div className="truncate text-[11px] font-medium text-pink-300">{e.flavorLabel}</div>
              ) : extrasCount(e) > 0 ? (
                <div className="truncate text-[11px] font-medium text-amber-300">
                  + {extrasCount(e)} topping{extrasCount(e) === 1 ? "" : "s"}
                </div>
              ) : (
                <div className="truncate text-[11px] font-medium text-muted-foreground">No toppings</div>
              ))}
          </div>
          {count != null && (
            <span className="ml-auto shrink-0 rounded bg-secondary px-1.5 py-0.5 text-[11px] font-semibold tabular-nums">
              ×{count}
            </span>
          )}
        </div>

        {!!e?.cheese && (
          <div className="mt-2 flex items-center gap-1.5 text-[11px] text-amber-300">
            🧀 {e.cheese === 2 ? "Cheese melted in" : "Cheese applied"}
          </div>
        )}

        {e?.comps && e.comps.length > 0 && (
          <>
            <div className="mt-2.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
              Made with
            </div>
            <div className="mt-1 space-y-1">
              {e.comps.map((c, i) => (
                <div key={c.item + i} className="flex items-center gap-1.5 text-[11px]">
                  <div className="flex h-5 w-5 shrink-0 items-center justify-center rounded bg-muted/50">
                    <ItemThumb src={c.image} alt={c.label} className="h-4 w-4 object-contain" />
                  </div>
                  <span className="truncate">{c.label}</span>
                  {c.count > 1 && <span className="ml-auto shrink-0 tabular-nums text-muted-foreground">×{c.count}</span>}
                </div>
              ))}
            </div>
          </>
        )}

        {tip.hint && (
          <div className="mt-2.5 border-t border-border/60 pt-2 text-[11px] leading-snug text-muted-foreground">
            {tip.hint}
          </div>
        )}
        {actions}
        {/* caret pointing down at the card */}
        <div
          className="absolute top-full h-0 w-0 -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-card"
          style={{ left: `calc(50% + ${caretShift}px)` }}
        />
      </div>
    </div>
  );
}

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
    // oven / fryer / soda item: live progress bar, collect-now, next-step hints
    if (c.single) {
      const st = stateMeta(c.state);
      const pct = Math.round((c.percent ?? 0) * 100);
      const done = c.state === "burnt";
      const pausedHint = c.method === "soda"
        ? (c.state === "empty"
            ? "Click a tap to pour — the middle tap adds ice"
            : c.state === "filled"
              ? (c.needLid ? "Drag a lid onto the cup to finish it" : "Drag it to the bar to collect")
              : c.state === "capped"
                ? "Drag it to the bar to collect"
                : null)
        : !c.gate
          ? (c.method === "oven" ? "Close the door to bake" : "Lower the basket to fry")
          : c.locked
            ? "Raise the basket to take it out"
            : null;
      return (
        <div className="w-56 rounded-xl border border-border bg-card p-3 shadow-2xl">
          <div className="flex items-center gap-2">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-muted/50">
              <ItemThumb src={c.giveImage} alt={c.giveLabel || ""} className="h-9 w-9 object-contain" />
            </div>
            <div className="min-w-0">
              <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">Collect now</div>
              <div className="truncate text-sm font-semibold">{c.giveLabel || "—"}</div>
            </div>
            <span className={cn("ml-auto shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold text-white", st.cls)}>{st.label}</span>
          </div>
          <div className="mt-2.5 flex items-center gap-1.5">
            <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted">
              <div
                className={cn("h-full rounded-full transition-[width] duration-150 ease-linear",
                  done ? "bg-zinc-500" : c.gate ? "bg-primary" : "bg-primary/40")}
                style={{ width: `${pct}%` }}
              />
            </div>
            <span className="shrink-0 text-[9px] tabular-nums text-muted-foreground">{done ? "Done" : `${pct}%`}</span>
          </div>
          {c.burningSoon && !done && (
            <div className="mt-2 text-[11px] font-semibold text-amber-400">⚠ Burning soon!</div>
          )}
          {c.ice && (
            <div className="mt-2 flex items-center gap-1.5 text-[11px] text-sky-300">❄ Ice added</div>
          )}
          {pausedHint && <div className="mt-2 text-[11px] text-muted-foreground">{pausedHint}</div>}
        </div>
      );
    }
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

// Floating tooltip over the hovered serving tray: item count + the Make Meal
// button. The whole arrangement (every pile, exact offsets) becomes one meal item.
function MealTooltip({
  count, onMake, onPin,
}: {
  count: number;
  onMake: () => void;
  onPin: (pinned: boolean) => void;
}) {
  return (
    <div
      onPointerEnter={() => onPin(true)}
      onPointerLeave={() => onPin(false)}
      className="w-60 rounded-xl border border-border bg-card p-3 shadow-2xl"
    >
      <div className="flex items-center gap-2">
        <UtensilsCrossed className="h-4 w-4 shrink-0 text-primary" />
        <span className="text-sm font-semibold">Serving Tray</span>
        <span className="ml-auto shrink-0 rounded bg-secondary px-1.5 py-0.5 text-[11px] font-semibold tabular-nums">
          {count} item{count === 1 ? "" : "s"}
        </span>
      </div>
      <div className="mt-2 text-[11px] leading-snug text-muted-foreground">
        {count === 0
          ? "Drag food onto the tray to arrange a meal. Grab the tray to move it."
          : "Grab the tray to move it — or drop it on the bar to make the meal."}
      </div>
      <button
        disabled={count === 0}
        onClick={onMake}
        className={cn(
          "mt-3 w-full rounded-md px-3 py-1.5 text-xs font-semibold transition",
          count > 0
            ? "bg-primary text-primary-foreground hover:opacity-90"
            : "cursor-not-allowed bg-muted text-muted-foreground"
        )}
      >
        Make Meal
      </button>
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
  const [tab, setTab] = useState<"ingredients" | "cooked" | "uncooked">("ingredients");
  // bar organisation: text filter over the cards, one-row strip vs wrapped grid,
  // and the card whose bin button is waiting for its confirming second click
  const [query, setQuery] = useState("");
  const [expanded, setExpanded] = useState(false);
  const [confirmKey, setConfirmKey] = useState<string | null>(null);
  const confirmTimer = useRef<number | null>(null);
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
  // hover tooltip for a bar card (tray item / ingredient): contents + what to do with it
  const [barTip, setBarTip] = useState<BarTip | null>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const barPinnedRef = useRef(false);          // cursor is over the bar tooltip's actions
  const barTipTimer = useRef<number | null>(null);
  const tipPinnedRef = useRef(false);           // cursor is over the build tooltip
  const tipHideTimer = useRef<number | null>(null);
  const itemsRef = useRef<ChipItem[]>([]);
  const hoveredRef = useRef<number | null>(null);
  const placingRef = useRef(false);          // dragging an ingredient out of the bar
  const toppingRef = useRef<string | null>(null); // dragging a topping (cheese) onto a patty
  const lidRef = useRef<string | null>(null);     // dragging a lid onto a filled soda cup
  const finishRef = useRef<string | null>(null); // rubbing a finish tool (frosting) over a target
  const [finishFlavor, setFinishFlavor] = useState<Record<string, string>>({}); // chosen flavor per finish tool
  const prepDragRef = useRef<{ source: string; item: string; cheese: number; model?: string | null; decompose?: boolean; sig?: string } | null>(null); // dragging a NEW part (or a product/meal to take apart) onto the prep table
  const prepHoveredRef = useRef<number | null>(null); // placed prep part under the cursor (grab target)
  const trayHoveredRef = useRef<number | null>(null); // placed serving tray under the cursor (grab target)
  const prepMoveRef = useRef<{ puid?: number; tray?: boolean } | null>(null); // re-dragging a placed prep part / a whole serving tray
  const trayPlaceRef = useRef(false); // dragging a fresh serving tray out of the bar
  const worldRef = useRef<{ uid: number | null; startX: number; startY: number; dragging: boolean } | null>(null);

  useEffect(() => {
    setStation(data?.station || "fryer");
    setIngredients(data?.ingredients || []);
    setView("stovetop");
    setTab("ingredients");
    setTip(null);
    setTipShow(false);
    setQuery("");
    setConfirmKey(null);
  }, [data]);

  useNuiEvent("cookingIngredients", (d) => { setIngredients(d.ingredients || []); setBarTip(null); });
  // finish drag concluded on the Lua side (fully coated & applied, or rejected)
  useNuiEvent("cookingFinishDone", () => {
    finishRef.current = null;
    setDragging(false);
    setDragHint(null);
  });
  useNuiEvent("cookingTray", (d) => { setTray(d.tray || []); setBarTip(null); });
  useNuiEvent("cookingRecipes", (d) => setRecipes(d.recipes || []));
  useNuiEvent("cookingItems", (d) => {
    const its: ChipItem[] = d.items || [];
    itemsRef.current = its;
    hoveredRef.current = d.hovered ?? null;
    prepHoveredRef.current = d.prepHovered ?? null;
    trayHoveredRef.current = d.prepTrayHovered ?? null;
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
  const isFryer = station === "fryer";
  // the tray splits into ready "Cooked Items" and still-raw "Uncooked Items"
  // (things like an uncooked pizza that still need the oven/fryer)
  const cookedItems = tray.filter((e) => !e.uncooked);
  const uncookedItems = tray.filter((e) => e.uncooked);
  const cookedTotal = cookedItems.reduce((n, e) => n + e.count, 0);
  const uncookedTotal = uncookedItems.reduce((n, e) => n + e.count, 0);
  // burnt food actually binnable here — the sweep only reaches the tray store,
  // never inventory-held ("Item") entries
  const burntTotal = cookedItems.reduce((n, e) => n + (e.burnt && e.source !== "inv" ? e.count : 0), 0);
  // text filter (matches the name, flavor, and component/topping names) + a stable
  // sort: alphabetical, burnt last — so the bin candidates never hide mid-strip
  const q = query.trim().toLowerCase();
  const trayMatches = (e: TrayEntry) =>
    !q ||
    [e.label || e.item, e.flavorLabel, ...(e.comps || []).map((c) => c.label), ...(e.extras || []).map((c) => c.label)]
      .some((t) => !!t && t.toLowerCase().includes(q));
  const sortTray = (list: TrayEntry[]) =>
    [...list].sort(
      (a, b) =>
        Number(!!a.burnt) - Number(!!b.burnt) ||
        (a.label || a.item).localeCompare(b.label || b.item) ||
        (a.sig || "").localeCompare(b.sig || "")
    );
  const trayListAll = tab === "uncooked" ? uncookedItems : cookedItems;
  const trayList = sortTray(trayListAll.filter(trayMatches));
  const shownIngredients = ingredients.filter((ing) => !q || ing.label.toLowerCase().includes(q));
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

  const tipVisible = isPrep && tipShow && !!tip && !!tip.onScreen && !dragging && (tip.tray ? true : ranked.length > 0);
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
  // the hovered serving tray's Make Meal — the whole arrangement becomes one item
  const onMealMake = () => {
    if (!tip?.tray || !(tip.count || 0)) return;
    fetchNui("cooking:prepMakeMeal", { tid: tip.tid });
    setTipShow(false);
    setTip(null);
    tipPinnedRef.current = false;
  };

  // ── the bin: two clicks to throw away (arm, then confirm within 2.5s) ────────
  const armConfirm = (key: string) => {
    setConfirmKey(key);
    if (confirmTimer.current) clearTimeout(confirmTimer.current);
    confirmTimer.current = window.setTimeout(() => setConfirmKey(null), 2500);
  };
  const discardEntry = (e: TrayEntry, key: string) => {
    if (confirmKey !== key) return armConfirm(key);
    setConfirmKey(null);
    fetchNui("cooking:trayDiscard", { item: e.item, cheese: e.cheese || 0, count: e.count, sig: e.sig || "" });
  };
  const discardBurnt = () => {
    if (confirmKey !== "__burnt__") return armConfirm("__burnt__");
    setConfirmKey(null);
    fetchNui("cooking:trayDiscard", { burnt_only: true });
  };

  // ── drag ingredients out of the bar (live in-world placement) ───────────────
  const startPlace = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    placingRef.current = true;
    setTab("ingredients");
    setDragging(true);
    fetchNui("cooking:beginPlace", { kind: ing.kind, item: ing.item });
  };
  // an uncooked tray item (e.g. an uncooked pizza) can be dragged straight into its
  // own station to cook — consumed from the tray rather than the inventory.
  const canCookHere = (e: TrayEntry) => !isPrep && !!e.uncooked && e.cookStation === station;

  // one contextual "what can I do with this here" line for the hover tooltip
  const trayHint = (e: TrayEntry): string => {
    if (isPrep && e.meal) return "Drag onto the table to set the meal down — exactly as it was arranged.";
    if (isPrep && e.decompose) return "Drag onto the table to take it apart, or stack it as a layer.";
    if (isPrep) return "Drag onto the table to build with it.";
    if (canCookHere(e)) return station === "fryer" ? "Drag into the fryer basket to cook it." : "Drag into an open oven door to bake it.";
    if (e.uncooked) return `Still raw — cook it at the ${e.cookStation === "fryer" ? "fryer" : "stovetop oven"}.`;
    if (e.source === "inv") return "In your inventory — ready to stock or sell.";
    if (e.burnt) return "Burnt — discard it below, or keep it in your inventory.";
    return "Take it into your inventory to stock or sell it.";
  };
  const ingHint = (ing: Ingredient): string => {
    if (ing.kind === "tray") return "Drag onto the table — arrange food on it, then make it a meal.";
    if (ing.kind === "topping") return "Drag onto a cooked patty to add it.";
    if (ing.kind === "finish") return "Pick a flavor, then rub the tube over a cooked item on the table until fully coated.";
    if (ing.kind === "drink") return "Drag the cup under a tap, then click the tap to pour (middle tap = ice).";
    if (ing.kind === "lid") return "Drag onto a filled cup to press the lid on.";
    if (isPrep) return "Drag onto the table — stack parts to build recipes.";
    return station === "fryer" ? "Drag into the fryer basket to cook." : "Drag onto the cooktop or into an open oven door.";
  };
  const showBarTip = (ev: React.PointerEvent, tip: Omit<BarTip, "x" | "y">) => {
    if (barTipTimer.current) { clearTimeout(barTipTimer.current); barTipTimer.current = null; }
    barPinnedRef.current = false;
    const r = (ev.currentTarget as HTMLElement).getBoundingClientRect();
    setBarTip({ x: r.left + r.width / 2, y: r.top, ...tip });
  };
  // Leaving a card holds the tooltip briefly so the cursor can travel up onto its
  // action buttons; while hovered (pinned) it stays until the cursor leaves it.
  const hideBarTip = () => {
    if (barTipTimer.current) clearTimeout(barTipTimer.current);
    barTipTimer.current = window.setTimeout(() => {
      barTipTimer.current = null;
      if (!barPinnedRef.current) setBarTip(null);
    }, 250);
  };
  const onBarTipPin = (pinned: boolean) => {
    barPinnedRef.current = pinned;
    if (pinned) {
      if (barTipTimer.current) { clearTimeout(barTipTimer.current); barTipTimer.current = null; }
    } else {
      setBarTip(null); // left the tooltip and the card — dismiss
    }
  };
  const takeEntry = (e: TrayEntry, count: number) =>
    fetchNui("cooking:trayToInventory", { item: e.item, cheese: e.cheese || 0, count, sig: e.sig || "" });
  const startTrayCook = (ev: React.PointerEvent, e: TrayEntry) => {
    ev.preventDefault();
    placingRef.current = true;
    setDragging(true);
    fetchNui("cooking:beginPlace", { kind: "cook", item: e.item, source: e.source || "tray", cheese: e.cheese || 0, sig: e.sig || "" });
  };
  // the serving tray (kitchen prep): equipment, not an item — drag it onto the
  // table, arrange food on it, then turn the whole thing into one meal item.
  const startTrayPlace = (e: React.PointerEvent) => {
    e.preventDefault();
    trayPlaceRef.current = true;
    setDragging(true);
    setDragHint("Drop on the table to set the tray down");
    fetchNui("cooking:beginTrayPlace", {});
  };
  // the lid (soda machine): dragged as its real 3D prop and released over a
  // filled cup to press it on — same gesture as a cheese slice on a patty.
  const startLid = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    lidRef.current = ing.item;
    setTab("ingredients");
    setDragging(true);
    fetchNui("cooking:beginLid", { item: ing.item, model: ing.model });
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
  // finish tools (frosting): the chosen flavor rides the drag; the tube renders in
  // 3D under the cursor and is rubbed over a cooked target until fully coated —
  // the Lua side commits at full coverage (cookingFinishDone ends the drag state).
  const startFinish = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    const flavor = finishFlavor[ing.item] ?? ing.flavors?.[0]?.id;
    if (!flavor) return;
    finishRef.current = ing.item;
    setTab("ingredients");
    setDragging(true);
    setDragHint("Rub the tube over a cooked item on the table until fully coated");
    fetchNui("cooking:beginFinish", { item: ing.item, flavor });
  };
  // at the prep station, drag a tray item / ingredient onto the table to add a
  // layer. With a model it spawns a live 3D prop that follows the cursor (like the
  // stovetop); without one it falls back to a 2D ghost + auto-stack.
  const startPrepDrag = (
    e: React.PointerEvent, source: string,
    entry: { item: string; cheese?: number; model?: string; label?: string; image?: string; dual?: boolean; cheeseModel?: string; decompose?: boolean; uncooked?: boolean; sig?: string; stack?: string[]; stackState?: string }
  ) => {
    e.preventDefault();
    // A bun is one item spawned as a bottom+top pair (handled client-side), so no
    // half hint is needed here. A finished product from the tray is dragged as its
    // single prop but, on drop, gets taken apart into its component stack. The
    // server flags what's decomposable (tray products; meals from either source —
    // a meal previews and sets down as its whole tray).
    const decompose = !!entry.decompose;
    // the exact build variation this drag addresses: tray entries always carry a
    // sig; inventory PRODUCT entries carry one too (slot metadata). Plain
    // Ingredients-bar components have none — they reserve item-wide.
    const sig = entry.sig ?? (source === "tray" ? "" : undefined);
    // model doubles as the "3D drag in progress" marker on release — a stack-only
    // entry uses its base layer so the endPrepPlace commit path still runs
    const dragModel = entry.model || (entry.stack && entry.stack.length > 1 ? entry.stack[0] : null);
    prepDragRef.current = { source, item: entry.item, cheese: entry.cheese || 0, model: dragModel, decompose, sig };
    // stay on the tab the card actually lives in: tray entries AND inventory-held
    // products (they carry a sig) file under Cooked/Uncooked; only true
    // Ingredients-bar components switch to Ingredients
    const fromTab = source === "tray" || entry.sig !== undefined;
    setTab(fromTab ? (entry.uncooked ? "uncooked" : "cooked") : "ingredients");
    setDragging(true);
    setDragHint(decompose ? "Drop on the prep table to take it apart" : "Drop on the prep table — or onto another item to stack");
    if (decompose) {
      // preview the whole component stack (peeked, nothing consumed) under the
      // cursor; source tells the server which store holds it (tray vs inventory)
      fetchNui("cooking:beginPrepDecompose", { item: entry.item, sig, source });
    } else if (entry.model || (entry.stack && entry.stack.length > 1)) {
      // a product carrying a build stack (e.g. a cooked pizza) drags as its whole
      // layer tower, not just the base model
      fetchNui("cooking:beginPrepPlace", {
        item: entry.item, model: entry.model,
        dual: entry.dual ? 1 : 0, cheese: entry.cheese || 0, cheeseModel: entry.cheeseModel,
        sig, stack: entry.stack, state: entry.stackState,
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
        return;
      }
      // no part hovered: grab the serving tray itself (with everything on it)
      const tid = trayHoveredRef.current;
      if (tid != null) {
        prepMoveRef.current = { tray: true };
        setDragging(true);
        setDragHint("Drop on the bar to make it a meal — or set the tray down elsewhere");
        fetchNui("cooking:trayGrab", { tid });
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
          // an item in a lowered fryer basket can't be grabbed at all — the drag
          // never starts (no reaching into hot oil; raise the basket first)
          if (itemsRef.current.find((c) => c.uid === w.uid)?.locked) return;
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

      // dragging a fresh serving tray out of the bar: drop on the table places it
      if (trayPlaceRef.current) {
        trayPlaceRef.current = false;
        fetchNui("cooking:endTrayPlace", { cancel: overBar });
        return;
      }

      // re-dragged a placed prep part (or a grabbed serving tray): drop on the bar
      // removes it (a tray becomes its meal), else it stays / moves
      if (prepMoveRef.current) {
        prepMoveRef.current = null;
        fetchNui("cooking:prepDrop", { cancel: overBar });
        return;
      }

      // finish tool (frosting) released before full coverage: cancels harmlessly
      // (coverage resets, nothing consumed). At full coverage the Lua side already
      // committed and cleared the drag via cookingFinishDone.
      if (finishRef.current) {
        finishRef.current = null;
        fetchNui("cooking:endFinish", { cancel: overBar });
        return;
      }

      // lid dropped onto a filled soda cup — the live 3D lid ends here; the
      // server caps the hovered cup (or it just cancels).
      if (lidRef.current) {
        lidRef.current = null;
        const uid = hoveredRef.current;
        fetchNui("cooking:endLid", { uid: overBar ? null : uid, cancel: overBar });
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
        if (p.decompose) {
          // a finished product — take it apart into its component stack on drop
          // (a meal recreates its full tray + arrangement)
          fetchNui("cooking:endPrepDecompose", { cancel: overBar, item: p.item, sig: p.sig, source: p.source });
        } else if (p.model) {
          // live 3D placement — commit (or cancel back over the bar)
          fetchNui("cooking:endPrepPlace", { cancel: overBar, source: p.source, item: p.item, cheese: p.cheese, sig: p.sig });
        } else if (!overBar) {
          fetchNui("cooking:prepAdd", { source: p.source, item: p.item, cheese: p.cheese, sig: p.sig });
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
            // a click (no drag) on a patty flips it; only dual patties flip. A
            // click on a soda cup falls through to the tap under the cursor —
            // the cup sits right below its nozzle, so it must not eat the click.
            const it = itemsRef.current.find((c) => c.uid === w.uid);
            if (it?.dual) fetchNui("cooking:flip", { uid: w.uid });
            else if (it?.method === "soda") fetchNui("cooking:worldClick");
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

  useEffect(() => () => { if (confirmTimer.current) clearTimeout(confirmTimer.current); }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      // Escape inside the search box clears it and leaves the box; the next
      // Escape closes the station
      const t = e.target as HTMLElement | null;
      if (t && t.tagName === "INPUT") { (t as HTMLInputElement).blur(); setQuery(""); return; }
      fetchNui("cooking:close");
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const meta = STATION_META[station] || STATION_META.fryer;
  const Icon = meta.icon;

  const draggable = (ing: Ingredient) =>
    // tray + lid are kitchen equipment, never gated on an item count
    ing.kind === "tray" || ing.kind === "lid" ? true : ing.kind === "assembly" ? !!ing.canMake : (ing.count || 0) > 0;

  // One-row strip by default (wheel scrolls it sideways); expanded — or while
  // searching — the strip wraps into a scrollable grid. A drag always collapses
  // back to one row so the bar never covers the kitchen mid-gesture.
  const gridMode = (expanded || !!q) && !dragging;
  const rowCls = cn(
    "min-h-[132px] gap-2 pb-1",
    gridMode ? "flex max-h-[40vh] flex-wrap content-start overflow-y-auto pr-1" : "flex items-center overflow-x-auto"
  );
  const onRowWheel = (e: React.WheelEvent<HTMLDivElement>) => {
    if (gridMode) return;
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) e.currentTarget.scrollLeft += e.deltaY;
  };

  // Take / Discard live on the hovered card's tooltip, not the card itself —
  // tray-held entries only (inventory "Item" entries are already taken).
  const entryKey = (e: TrayEntry) => e.item + "|" + (e.cheese || 0) + "|" + (e.sig || "") + "|" + (e.source || "tray");
  const tipEntry = barTip?.tray;
  const tipKey = tipEntry ? entryKey(tipEntry) : "";
  const tipActions =
    tipEntry && tipEntry.source !== "inv" ? (
      <div className="mt-2.5 flex items-center gap-1.5 border-t border-border/60 pt-2.5">
        <button
          onClick={() => takeEntry(tipEntry, 1)}
          className="rounded-md bg-secondary px-2.5 py-1 text-[11px] font-semibold text-foreground transition hover:bg-accent"
        >
          {tipEntry.count > 1 ? "Take 1" : "Take"}
        </button>
        {tipEntry.count > 1 && (
          <button
            onClick={() => takeEntry(tipEntry, tipEntry.count)}
            className="rounded-md bg-secondary px-2.5 py-1 text-[11px] font-semibold text-foreground transition hover:bg-accent"
          >
            Take All
          </button>
        )}
        <button
          onClick={() => discardEntry(tipEntry, tipKey)}
          className={cn(
            "ml-auto flex items-center gap-1 rounded-md px-2.5 py-1 text-[11px] font-semibold transition",
            confirmKey === tipKey
              ? "bg-red-500/25 text-red-200 ring-1 ring-red-500"
              : "bg-secondary text-foreground hover:bg-red-500/20 hover:text-red-200"
          )}
        >
          <Trash2 className="h-3 w-3" />
          {confirmKey === tipKey ? "Confirm?" : "Discard"}
        </button>
      </div>
    ) : null;

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
          {tip?.tray ? (
            <MealTooltip count={tip.count || 0} onMake={onMealMake} onPin={onTipPin} />
          ) : (
            <BuildTooltip ranked={ranked} selected={selected} onSelect={setSelectedOutput} onMake={onTipMake} onPin={onTipPin} />
          )}
          <div className="absolute left-1/2 top-full h-0 w-0 -translate-x-1/2 border-x-[6px] border-t-[6px] border-x-transparent border-t-card" />
        </div>
      </div>

      {/* hover tooltip for a bar card (tray item / ingredient) */}
      {barTip && !dragging && <BarTooltip tip={barTip} actions={tipActions} onPin={onBarTipPin} />}

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

        <div className="flex gap-3">
          {/* stovetop view switcher — icon tabs for the cooktop and each oven door;
              the pictures do the talking (labels only on hover) */}
          {isStove && (
            <div className="flex shrink-0 flex-col justify-center gap-1.5 border-r border-border pr-3">
              {STOVE_VIEWS.map((v) => {
                const VIcon = v.icon;
                const active = view === v.key;
                return (
                  <button
                    key={v.key}
                    title={v.label}
                    onClick={() => switchView(v.key)}
                    className={cn(
                      "relative flex h-10 w-10 items-center justify-center rounded-lg border transition",
                      active
                        ? "border-primary bg-primary text-primary-foreground"
                        : "border-border bg-secondary text-muted-foreground hover:border-primary/60 hover:text-foreground"
                    )}
                  >
                    <VIcon className="h-5 w-5" />
                    {v.num != null && (
                      <span
                        className={cn(
                          "absolute -bottom-1 -right-1 flex h-4 w-4 items-center justify-center rounded-full border text-[9px] font-bold",
                          active
                            ? "border-primary bg-background text-primary"
                            : "border-border bg-background text-muted-foreground"
                        )}
                      >
                        {v.num}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          )}

          <div className="min-w-0 flex-1">
        {/* tabs: raw ingredients · ready cooked items · still-raw uncooked items —
            plus the bar tools on the right: burnt sweep, search, one-row/grid toggle */}
        <div className="mb-2 flex items-center gap-1">
          {([
            ["ingredients", "Ingredients", Carrot, 0],
            ["cooked", "Cooked Items", ChefHat, cookedTotal],
            ["uncooked", "Uncooked Items", CookingPot, uncookedTotal],
          ] as const).map(([key, label, TabIcon, count]) => (
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
              {count > 0 ? ` (${count})` : ""}
            </button>
          ))}
          <div className="ml-auto flex items-center gap-1.5">
            {tab === "cooked" && burntTotal > 0 && (
              <button
                onClick={discardBurnt}
                className={cn(
                  "flex items-center gap-1 rounded-md border px-2 py-1 text-[11px] font-semibold transition",
                  confirmKey === "__burnt__"
                    ? "border-red-500 bg-red-500/20 text-red-200"
                    : "border-border bg-secondary text-foreground hover:border-red-500/60 hover:text-red-200"
                )}
              >
                <Trash2 className="h-3.5 w-3.5" />
                {confirmKey === "__burnt__" ? "Click again to confirm" : `Discard burnt (${burntTotal})`}
              </button>
            )}
            <div className="relative">
              <Search className="pointer-events-none absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search…"
                className="h-[26px] w-40 rounded-md border border-border bg-background pl-7 pr-6 text-xs outline-none placeholder:text-muted-foreground/70 focus:border-primary/60"
              />
              {query && (
                <button
                  onClick={() => setQuery("")}
                  className="absolute right-1 top-1/2 -translate-y-1/2 rounded p-0.5 text-muted-foreground hover:text-foreground"
                >
                  <X className="h-3 w-3" />
                </button>
              )}
            </div>
            <button
              title={expanded ? "Collapse to one row" : "Show everything as a grid"}
              onClick={() => setExpanded((v) => !v)}
              className={cn(
                "flex h-[26px] w-[26px] items-center justify-center rounded-md border transition",
                expanded
                  ? "border-primary bg-primary text-primary-foreground"
                  : "border-border bg-secondary text-muted-foreground hover:border-primary/60 hover:text-foreground"
              )}
            >
              {expanded ? <ChevronDown className="h-4 w-4" /> : <ChevronUp className="h-4 w-4" />}
            </button>
          </div>
        </div>

        {tab === "ingredients" ? (
          <div className={rowCls} onWheel={onRowWheel}>
            {shownIngredients.length === 0 && (
              <div className="text-sm text-muted-foreground">
                {q && ingredients.length > 0
                  ? `No matches for “${query.trim()}”.`
                  : "You have no ingredients for this station."}
              </div>
            )}
            {shownIngredients.map((ing, i) => {
              const can = draggable(ing);
              const onDown = (e: React.PointerEvent) => {
                if (!can) return;
                setBarTip(null);
                if (ing.kind === "tray") startTrayPlace(e);
                else if (ing.kind === "lid") startLid(e, ing);
                else if (ing.kind === "topping") startTopping(e, ing);
                else if (ing.kind === "finish") startFinish(e, ing);
                else if (isPrep) startPrepDrag(e, "inv", { item: ing.item, cheese: 0, model: ing.model, label: ing.label, image: ing.image, dual: ing.dual });
                else startPlace(e, ing);
              };
              return (
                <div
                  key={ing.item + i}
                  onPointerDown={onDown}
                  onPointerEnter={(ev) => showBarTip(ev, { ing, hint: can ? ingHint(ing) : undefined })}
                  onPointerLeave={hideBarTip}
                  className={cn(
                    "relative flex h-32 shrink-0 touch-none select-none flex-col items-center justify-center gap-1 rounded-lg border text-center text-xs font-medium",
                    ing.kind === "finish" ? "w-32" : "w-28",
                    can
                      ? "cursor-grab border-border bg-secondary hover:border-primary/60 active:cursor-grabbing"
                      : "cursor-not-allowed border-dashed border-border/60 bg-muted/40 opacity-60"
                  )}
                >
                  {ing.kind === "tray" ? (
                    <UtensilsCrossed className="h-10 w-10 text-primary/80" />
                  ) : ing.kind === "lid" ? (
                    <CircleDot className="h-10 w-10 text-primary/80" />
                  ) : (
                    <ItemThumb src={ing.image} alt={ing.label} className={ing.kind === "finish" ? "h-8 w-8 object-contain" : "h-10 w-10 object-contain"} />
                  )}
                  <span className="w-full truncate px-1.5 leading-tight">{ing.label}</span>
                  {ing.kind === "tray" && (
                    <span className="text-[10px] text-muted-foreground">Build a meal</span>
                  )}
                  {ing.kind === "lid" && (
                    <span className="text-[10px] text-muted-foreground">Caps a filled drink</span>
                  )}
                  {/* finish tool: flavor picked right on the card (colored swatch
                      squares, hover for the flavor name), then drag to apply.
                      NOTE: native title tooltips don't render in NUI/CEF, so each
                      swatch carries its own CSS group-hover label. */}
                  {ing.kind === "finish" && !!ing.flavors?.length && (
                    <div className="mx-auto flex w-[70%] flex-wrap items-center justify-center gap-1">
                      {ing.flavors.map((fl) => {
                        const active = (finishFlavor[ing.item] ?? ing.flavors![0].id) === fl.id;
                        return (
                          <div key={fl.id} className="group relative">
                            <button
                              aria-label={fl.label}
                              onPointerDown={(ev) => ev.stopPropagation()}
                              onClick={() => setFinishFlavor((m) => ({ ...m, [ing.item]: fl.id }))}
                              style={{ backgroundColor: flavorColor(fl) }}
                              className={cn(
                                "block h-5 w-5 shrink-0 rounded-md border transition",
                                active
                                  ? "scale-110 border-white ring-2 ring-primary"
                                  : "border-black/40 opacity-70 hover:opacity-100"
                              )}
                            />
                            <span className="pointer-events-none absolute -top-6 left-1/2 z-50 hidden -translate-x-1/2 whitespace-nowrap rounded border border-border bg-card px-1.5 py-0.5 text-[9px] font-semibold text-foreground shadow-lg group-hover:block">
                              {fl.label}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                  {ing.kind !== "assembly" && ing.kind !== "tray" && ing.kind !== "lid" && (
                    <Badge variant="secondary" className="absolute right-1 top-1">{ing.count ?? 0}</Badge>
                  )}
                  {ing.kind === "assembly" && !ing.canMake && (
                    <span className="text-[10px] text-muted-foreground">Missing parts</span>
                  )}
                </div>
              );
            })}
          </div>
        ) : (
          <div className={rowCls} onWheel={onRowWheel}>
            {trayList.length === 0 && (
              <div className="text-sm text-muted-foreground">
                {q && trayListAll.length > 0
                  ? `No matches for “${query.trim()}”.`
                  : tab === "uncooked"
                    ? "No uncooked items — assemble one (e.g. a pizza) at the prep table."
                    : "No cooked items yet — cook something and collect it."}
              </div>
            )}
            {trayList.map((e, i) => {
              const cookHere = canCookHere(e);
              const fromInv = e.source === "inv";
              const cardKey = e.item + "|" + (e.cheese || 0) + "|" + (e.sig || "") + "|" + (e.source || "tray") + "|" + i;
              return (
              <div
                key={cardKey}
                onPointerDown={(ev) => {
                  setBarTip(null);
                  if (isPrep) startPrepDrag(ev, e.source || "tray", e);
                  else if (cookHere) startTrayCook(ev, e);
                }}
                onPointerEnter={(ev) => showBarTip(ev, { tray: e, hint: trayHint(e) })}
                onPointerLeave={hideBarTip}
                className={cn(
                  "relative flex h-32 w-28 shrink-0 touch-none select-none flex-col items-center rounded-lg border bg-secondary pt-2 text-center text-xs font-medium",
                  e.burnt ? "border-red-900/70 bg-red-950/25" : "border-border",
                  (isPrep || cookHere) ? "cursor-grab hover:border-primary/60 active:cursor-grabbing" : e.burnt ? "hover:border-red-800" : "hover:border-border"
                )}
              >
                {/* content block centered in the space above the action row */}
                <div className="flex min-h-0 w-full flex-1 flex-col items-center justify-center gap-0.5">
                  <ItemThumb src={e.image} alt={e.label || e.item} className="h-10 w-10 object-contain" />
                  <span className="w-full truncate px-1.5 leading-tight">{e.label || e.item}</span>
                  {/* flavor line for finished (frosted) products; toppings row for
                      everything else — fixed height so every card lines up */}
                  {e.flavorLabel ? (
                    <div className="flex h-[18px] items-center text-[9px] font-semibold text-pink-300">{e.flavorLabel}</div>
                  ) : (
                    <ToppingsRow e={e} />
                  )}
                </div>
                {/* hint chips pinned to the card's bottom edge — the actionable
                    buttons (Take / Discard) live on the hover tooltip instead */}
                <div className="flex w-full flex-col items-center gap-0.5 pb-1.5">
                  {isPrep && e.meal && (
                    <span className="rounded bg-primary/15 px-1.5 py-0.5 text-[9px] font-semibold text-primary">
                      Drag to set down
                    </span>
                  )}
                  {cookHere && (
                    <span className="rounded bg-primary/15 px-1.5 py-0.5 text-[9px] font-semibold text-primary">
                      {station === "fryer" ? "Drag into the basket" : "Drag into the oven"}
                    </span>
                  )}
                </div>
                <Badge variant="secondary" className="absolute right-1 top-1">{e.count}</Badge>
                {/* origin marker (inventory item) + cheese state */}
                <div className="absolute left-1 top-1 flex items-center gap-0.5">
                  {fromInv && (
                    <span className="rounded border border-border bg-background/70 px-1 py-px text-[8px] font-semibold uppercase tracking-wide text-muted-foreground">
                      Item
                    </span>
                  )}
                  {!!e.cheese && <span className="text-sm">🧀</span>}
                </div>
              </div>
              );
            })}
          </div>
        )}
          </div>
        </div>
      </div>
    </>
  );
}
