import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { Badge } from "@/components/ui/badge";
import { X, Flame, CupSoda, Sandwich, UtensilsCrossed, Carrot, ChefHat, CookingPot, Heater, Microwave, CircleDot, Search, Trash2, ChevronUp, ChevronDown, Timer, Package } from "lucide-react";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";

// kind "finish" = a finish tool (frosting): flavors is picked on the card, then the
// tube is rubbed over a cooked target on the prep table until fully coated.
type Ingredient = { kind: string; item: string; label: string; image?: string; count?: number; canMake?: boolean; model?: string; dual?: boolean; subkind?: string; flavors?: { id: string; label: string; color?: string }[] };

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
  // a meal made in a pizza box — sets back down as its box (lid open), not a tray
  boxed?: boolean;
  // a finished (frosted…) product's recorded flavor, e.g. "Strawberry"
  flavorLabel?: string;
  // which finish tool last applied to this product (e.g. "frosting") — lets a
  // finish tool gate on a prior finish (sprinkles require frosting) client-side
  finishTool?: string;
  // a burnt cook output — sorted to the back of the bar and offered the bin
  burnt?: boolean;
  // freshness: seconds left until this item spoils when the tray was last fetched
  // (absent = never expires). The card counts it down locally and shows a red timer
  // in the final minute.
  expiresIn?: number;
};
// A buildable recipe (kitchen prep) with its output + components resolved for the tooltip.
type RecipeComp = { item: string; label: string; image?: string };
type RecipeCat = { output: string; label: string; image?: string; components: RecipeComp[] };
// The hovered stack's live snapshot: where it is on screen + what it provides.
// A hovered serving tray sends { tray: true, tid, count } instead (Make Meal
// tooltip); a pizza box additionally carries { box: true, open } (lid state —
// clicking the box toggles it).
type PrepTip = {
  sid?: number; onScreen: boolean; x: number; y: number; provides?: Record<string, number>;
  tray?: boolean; box?: boolean; open?: boolean; boxing?: boolean; tid?: number; count?: number;
  // a baking tray (cake tin / cookie tray): no Make Meal — a hint to rub the mix in
  // (empty) or drag it to the hotbar (filled).
  bake?: boolean; filled?: boolean;
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
  { key: "stovetop", label: _L("cook.view_stovetop"), icon: Heater },
  { key: "door1", label: _L("cook.view_oven_door_1"), icon: Microwave, num: 1 },
  { key: "door2", label: _L("cook.view_oven_door_2"), icon: Microwave, num: 2 },
];

const STATION_META: Record<string, { label: string; icon: any; hint: string }> = {
  fryer: { label: _L("cook.station_fryer_label"), icon: Flame, hint: _L("cook.station_fryer_hint") },
  stovetop: { label: _L("cook.station_stovetop_label"), icon: Flame, hint: _L("cook.station_stovetop_hint") },
  soda_machine: { label: _L("cook.station_soda_label"), icon: CupSoda, hint: _L("cook.station_soda_hint") },
  kitchen_prep: { label: _L("cook.station_prep_label"), icon: Sandwich, hint: _L("cook.station_prep_hint") },
};

const STATE_STYLE: Record<string, { label: string; cls: string }> = {
  raw: { label: _L("cook.state_raw"), cls: "bg-rose-500/80 border-rose-300" },
  filling: { label: _L("cook.state_filling"), cls: "bg-sky-500/80 border-sky-300" },
  cooked: { label: _L("cook.state_cooked"), cls: "bg-emerald-500/80 border-emerald-300" },
  done: { label: _L("cook.state_ready"), cls: "bg-emerald-500/80 border-emerald-300" },
  burnt: { label: _L("cook.state_burnt"), cls: "bg-zinc-800/90 border-zinc-500" },
  // soda cups
  empty: { label: _L("cook.state_empty"), cls: "bg-zinc-600/80 border-zinc-400" },
  filled: { label: _L("cook.state_filled"), cls: "bg-emerald-500/80 border-emerald-300" },
  capped: { label: _L("cook.state_ready"), cls: "bg-emerald-500/80 border-emerald-300" },
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
    return <div className="flex h-[18px] items-center text-[9px] text-muted-foreground/70">{_L("cook.no_toppings")}</div>;
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
                  {_L("cook.item_badge")}
                </span>
              )}
            </div>
            {e &&
              (e.meal ? (
                <div className="truncate text-[11px] font-medium text-amber-300">
                  {e.boxed ? _L("cook.boxed_pizza_meal") : _L("cook.serving_tray_meal")}
                </div>
              ) : e.flavorLabel ? (
                <div className="truncate text-[11px] font-medium text-pink-300">{e.flavorLabel}</div>
              ) : extrasCount(e) > 0 ? (
                <div className="truncate text-[11px] font-medium text-amber-300">
                  {extrasCount(e) === 1 ? _L("cook.topping_one", extrasCount(e)) : _L("cook.toppings_other", extrasCount(e))}
                </div>
              ) : (
                <div className="truncate text-[11px] font-medium text-muted-foreground">{_L("cook.no_toppings")}</div>
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
            🧀 {e.cheese === 2 ? _L("cook.cheese_melted_in") : _L("cook.cheese_applied")}
          </div>
        )}

        {e?.comps && e.comps.length > 0 && (
          <>
            <div className="mt-2.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
              {_L("cook.made_with")}
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
          {done ? _L("cook.done") : `${pct}%`}
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
            ? _L("cook.hint_click_tap_pour")
            : c.state === "filled"
              ? (c.needLid ? _L("cook.hint_drag_lid_finish") : _L("cook.hint_drag_bar_collect"))
              : c.state === "capped"
                ? _L("cook.hint_drag_bar_collect")
                : null)
        : !c.gate
          ? (c.method === "oven" ? _L("cook.hint_close_door_bake") : _L("cook.hint_lower_basket_fry"))
          : c.locked
            ? _L("cook.hint_raise_basket")
            : null;
      return (
        <div className="w-56 rounded-xl border border-border bg-card p-3 shadow-2xl">
          <div className="flex items-center gap-2">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-muted/50">
              <ItemThumb src={c.giveImage} alt={c.giveLabel || ""} className="h-9 w-9 object-contain" />
            </div>
            <div className="min-w-0">
              <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{_L("cook.collect_now")}</div>
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
            <span className="shrink-0 text-[9px] tabular-nums text-muted-foreground">{done ? _L("cook.done") : `${pct}%`}</span>
          </div>
          {c.burningSoon && !done && (
            <div className="mt-2 text-[11px] font-semibold text-amber-400">{_L("cook.burning_soon")}</div>
          )}
          {c.ice && (
            <div className="mt-2 flex items-center gap-1.5 text-[11px] text-sky-300">{_L("cook.ice_added")}</div>
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
        <SideRow name={_L("cook.side_1")} side={sides[0]} />
        <SideRow name={_L("cook.side_2")} side={sides[1]} />
      </div>

      {c.cheese && c.cheese !== "none" && (
        <div className="mt-2 flex items-center gap-1.5 text-[11px] text-amber-300">
          🧀 {c.cheese === "melted" ? _L("cook.cheese_melted") : _L("cook.cheese_melting")}
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
        <div className="text-xs text-muted-foreground">{_L("cook.no_matching_recipes")}</div>
      ) : (
        <>
          <div className="mb-2 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            {_L("cook.recipes_click_compare")}
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
                <div className="mt-1 text-[11px] font-medium text-emerald-400">{_L("cook.ready_to_make")}</div>
              ) : (
                <>
                  <div className="mt-1.5 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
                    {_L("cook.still_needs")}
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
                {_L("cook.make")}
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

// Floating hint over a hovered baking tray (cake tin / cookie tray): rub the mix in
// while empty, drag it to the hotbar once filled. No Make Meal — a baking tray isn't
// a meal surface; the mix + tray produce an oven-ready raw bake.
function BakeTrayTooltip({ filled, onPin }: { filled: boolean; onPin: (pinned: boolean) => void }) {
  return (
    <div
      onPointerEnter={() => onPin(true)}
      onPointerLeave={() => onPin(false)}
      className="w-60 rounded-xl border border-border bg-card p-3 shadow-2xl"
    >
      <div className="flex items-center gap-2">
        <CookingPot className="h-4 w-4 shrink-0 text-primary" />
        <span className="text-sm font-semibold">{_L("cook.baking_tray")}</span>
      </div>
      <div className="mt-2 text-[11px] leading-snug text-muted-foreground">
        {filled ? _L("cook.baketray_filled_hint") : _L("cook.baketray_empty_hint")}
      </div>
    </div>
  );
}

// Floating tooltip over the hovered serving tray / pizza box: item count + the
// Make Meal / Box It Up button. The whole arrangement (every pile, exact
// offsets) becomes one meal item; a box's meal is flagged so it sets back down
// as its box. A box also explains its click-to-toggle lid.
function MealTooltip({
  count, box, open, boxing, onMake, onTakeOut, onPin,
}: {
  count: number;
  box?: boolean;
  open?: boolean;
  boxing?: boolean;
  onMake: () => void;
  onTakeOut: () => void;
  onPin: (pinned: boolean) => void;
}) {
  const Icon = box ? Package : UtensilsCrossed;
  const hint = box
    ? boxing
      ? _L("cook.box_closing_hint")
      : count === 0
        ? open
          ? _L("cook.box_empty_open_hint")
          : _L("cook.box_empty_closed_hint")
        : _L("cook.box_full_hint")
    : count === 0
      ? _L("cook.tray_empty_hint")
      : _L("cook.tray_full_hint");
  const canAct = count > 0 && !boxing;
  return (
    <div
      onPointerEnter={() => onPin(true)}
      onPointerLeave={() => onPin(false)}
      className="w-60 rounded-xl border border-border bg-card p-3 shadow-2xl"
    >
      <div className="flex items-center gap-2">
        <Icon className="h-4 w-4 shrink-0 text-primary" />
        <span className="text-sm font-semibold">{box ? _L("cook.pizza_box") : _L("cook.serving_tray")}</span>
        <span className="ml-auto shrink-0 rounded bg-secondary px-1.5 py-0.5 text-[11px] font-semibold tabular-nums">
          {box
            ? count === 0
              ? _L("cook.box_empty_badge")
              : _L("cook.box_pizza_inside")
            : count === 1
              ? _L("cook.item_one", count)
              : _L("cook.items_other", count)}
        </span>
      </div>
      <div className="mt-2 text-[11px] leading-snug text-muted-foreground">{hint}</div>
      <div className="mt-3 flex gap-1.5">
        <button
          disabled={!canAct}
          onClick={onMake}
          className={cn(
            "flex-1 rounded-md px-3 py-1.5 text-xs font-semibold transition",
            canAct
              ? "bg-primary text-primary-foreground hover:opacity-90"
              : "cursor-not-allowed bg-muted text-muted-foreground"
          )}
        >
          {box ? (boxing ? _L("cook.box_closing") : _L("cook.box_it_up")) : _L("cook.make_meal")}
        </button>
        {box && count > 0 && (
          <button
            disabled={!canAct}
            onClick={onTakeOut}
            className={cn(
              "rounded-md px-2.5 py-1.5 text-xs font-semibold transition",
              canAct
                ? "bg-secondary text-foreground hover:bg-accent"
                : "cursor-not-allowed bg-muted text-muted-foreground"
            )}
          >
            {_L("cook.box_take_out")}
          </button>
        )}
      </div>
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
  const bakeMixRef = useRef<string | null>(null); // rubbing the baking mix over an empty baking tray
  const [finishFlavor, setFinishFlavor] = useState<Record<string, string>>({}); // chosen flavor per finish tool
  const prepDragRef = useRef<{ source: string; item: string; cheese: number; model?: string | null; decompose?: boolean; sig?: string } | null>(null); // dragging a NEW part (or a product/meal to take apart) onto the prep table
  const prepHoveredRef = useRef<number | null>(null); // placed prep part under the cursor (grab target)
  const trayHoveredRef = useRef<number | null>(null); // placed serving tray/box under the cursor (grab target)
  const trayHoveredBoxRef = useRef(false); // the hovered tray is a pizza box (click toggles its lid)
  // a press on a pizza box: undecided between a click (lid toggle) and a drag (grab)
  const pendingBoxRef = useRef<{ tid: number; x: number; y: number } | null>(null);
  const prepMoveRef = useRef<{ puid?: number; tray?: boolean } | null>(null); // re-dragging a placed prep part / a whole serving tray
  const trayPlaceRef = useRef(false); // dragging a fresh serving tray out of the bar
  const worldRef = useRef<{ uid: number | null; startX: number; startY: number; dragging: boolean } | null>(null);
  // Dragging a cross-category item auto-switches the bar to that item's category so
  // you can see where it lands; prevTabRef remembers the tab to fall BACK to if the
  // drag doesn't finish on the prep table (cancel / drop on the bar). tabRef mirrors
  // `tab` so the []-deps pointer handlers read the live value.
  const prevTabRef = useRef<"ingredients" | "cooked" | "uncooked" | null>(null);
  const tabRef = useRef(tab);
  useEffect(() => { tabRef.current = tab; }, [tab]);
  // dragging a prop FROM the world/prep table (grill collect, prep restack/remove) —
  // the hotbar becomes the prominent orange drop zone against a dimmed backdrop
  const [worldDragging, setWorldDragging] = useState(false);
  // switch the bar to a dragged item's category, remembering where we came from
  const dragSwitchTab = (cat: "ingredients" | "cooked" | "uncooked") => {
    if (tabRef.current !== cat) {
      if (prevTabRef.current === null) prevTabRef.current = tabRef.current;
      setTab(cat);
    }
  };
  // end of drag: keep the switched-to category if it landed on the prep, else revert
  const endDragTab = (droppedOnPrep: boolean) => {
    const prev = prevTabRef.current;
    prevTabRef.current = null;
    if (prev !== null && !droppedOnPrep) setTab(prev);
  };

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
  // baking-mix drag concluded on the Lua side (tray filled, or rejected)
  useNuiEvent("cookingBakeDone", () => {
    bakeMixRef.current = null;
    setDragging(false);
    setDragHint(null);
  });
  // when the tray was last fetched — the freshness countdown is measured from here
  const [trayAt, setTrayAt] = useState(() => Date.now());
  const [nowMs, setNowMs] = useState(() => Date.now());
  useNuiEvent("cookingTray", (d) => { setTray(d.tray || []); setTrayAt(Date.now()); setBarTip(null); });
  // 1s tick so the red expiry countdown updates while the panel is open
  useEffect(() => {
    const t = window.setInterval(() => setNowMs(Date.now()), 1000);
    return () => window.clearInterval(t);
  }, []);
  // seconds left before an entry spoils (null = never / already gone). Counts down
  // locally from expiresIn measured at the last tray fetch.
  const expirySecs = (e: TrayEntry): number | null => {
    if (e.expiresIn == null) return null;
    return Math.max(0, Math.round(e.expiresIn - (nowMs - trayAt) / 1000));
  };
  // M:SS for a minute or more, else Ns — a compact live countdown label
  const fmtExpiry = (s: number): string =>
    s >= 60 ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}` : `${s}s`;
  // When a countdown reaches 0, ask the server to re-pull the tray (it purges spoiled
  // rows on fetch) so the item drops immediately instead of waiting for the sweep.
  // Throttled so a small client/server clock skew can't spin a tight refetch loop.
  const lastReapRef = useRef(0);
  useEffect(() => {
    const anyExpired = tray.some((e) => { const s = expirySecs(e); return s != null && s <= 0; });
    if (anyExpired && Date.now() - lastReapRef.current > 2500) {
      lastReapRef.current = Date.now();
      fetchNui("cooking:refreshTray");
    }
  }, [nowMs, tray, trayAt]);
  useNuiEvent("cookingRecipes", (d) => setRecipes(d.recipes || []));
  useNuiEvent("cookingItems", (d) => {
    const its: ChipItem[] = d.items || [];
    itemsRef.current = its;
    hoveredRef.current = d.hovered ?? null;
    prepHoveredRef.current = d.prepHovered ?? null;
    trayHoveredRef.current = d.prepTrayHovered ?? null;
    trayHoveredBoxRef.current = !!d.prepTrayBox;
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
  // kitchen equipment (serving tray, pizza box) files under the COOKED ITEMS tab —
  // that's where the food they package lives — not among the raw ingredients
  const isEquipment = (ing: Ingredient) => ing.kind === "tray" || ing.kind === "pizzabox" || ing.kind === "baketray";
  const equipmentCards = isPrep
    ? ingredients.filter((ing) => isEquipment(ing) && (!q || ing.label.toLowerCase().includes(q)))
    : [];
  const shownIngredients = ingredients.filter((ing) => !isEquipment(ing) && (!q || ing.label.toLowerCase().includes(q)));
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
  // the hovered serving tray's Make Meal / pizza box's Box It Up — the whole
  // arrangement becomes one item (a box closes its lid first, Lua-side)
  const onMealMake = () => {
    if (!tip?.tray || !(tip.count || 0) || tip.boxing) return;
    fetchNui("cooking:prepMakeMeal", { tid: tip.tid });
    setTipShow(false);
    setTip(null);
    tipPinnedRef.current = false;
  };
  // the box tooltip's Take Out — the pizza slides back out onto the table
  const onBoxTakeOut = () => {
    if (!tip?.box || !(tip.count || 0) || tip.boxing) return;
    fetchNui("cooking:boxTakeOut", { tid: tip.tid });
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
    if (isPrep && e.meal) return _L("cook.trayhint_meal");
    if (isPrep && e.decompose) return _L("cook.trayhint_decompose");
    if (isPrep) return _L("cook.trayhint_build");
    if (canCookHere(e)) return station === "fryer" ? _L("cook.trayhint_cook_fryer") : _L("cook.trayhint_cook_oven");
    if (e.uncooked) return _L("cook.trayhint_still_raw", e.cookStation === "fryer" ? _L("cook.station_word_fryer") : _L("cook.station_word_stovetop_oven"));
    if (e.source === "inv") return _L("cook.trayhint_in_inventory");
    if (e.burnt) return _L("cook.trayhint_burnt");
    return _L("cook.trayhint_take");
  };
  const ingHint = (ing: Ingredient): string => {
    if (ing.kind === "tray") return _L("cook.inghint_tray");
    if (ing.kind === "pizzabox") return _L("cook.inghint_pizzabox");
    if (ing.kind === "topping") return _L("cook.inghint_topping");
    if (ing.kind === "finish") return _L("cook.inghint_finish");
    if (ing.kind === "drink") return _L("cook.inghint_drink");
    if (ing.kind === "lid") return _L("cook.inghint_lid");
    if (isPrep) return _L("cook.inghint_prep");
    return station === "fryer" ? _L("cook.inghint_fryer") : _L("cook.inghint_stovetop");
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
  // the serving tray / pizza box (kitchen prep): equipment, not an item — drag it
  // onto the table, arrange food on/in it, then turn the whole thing into one
  // meal item (kind "box" places the pizza box, lid closed).
  const startTrayPlace = (e: React.PointerEvent, kind?: string) => {
    e.preventDefault();
    trayPlaceRef.current = true;
    setDragging(true);
    setDragHint(kind === "box" ? _L("cook.draghint_box_down") : _L("cook.draghint_tray_down"));
    fetchNui("cooking:beginTrayPlace", { kind });
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
    setDragHint(_L("cook.draghint_rub_tube"));
    fetchNui("cooking:beginFinish", { item: ing.item, flavor });
  };
  // baking mix: dragged as its bowl prop and rubbed over a placed EMPTY baking tray
  // (cake tin / cookie tray) until full — the Lua side fills the tray at full coverage
  // (cookingBakeDone ends the drag state).
  const startBakeMix = (e: React.PointerEvent, ing: Ingredient) => {
    e.preventDefault();
    bakeMixRef.current = ing.item;
    setTab("ingredients");
    setDragging(true);
    setDragHint(_L("cook.draghint_bakemix"));
    fetchNui("cooking:beginBakeMix", { item: ing.item });
  };
  // at the prep station, drag a tray item / ingredient onto the table to add a
  // layer. With a model it spawns a live 3D prop that follows the cursor (like the
  // stovetop); without one it falls back to a 2D ghost + auto-stack.
  const startPrepDrag = (
    e: React.PointerEvent, source: string,
    entry: { item: string; cheese?: number; model?: string; label?: string; image?: string; dual?: boolean; cheeseModel?: string; decompose?: boolean; uncooked?: boolean; sig?: string; stack?: string[]; stackState?: string; finishTool?: string }
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
    dragSwitchTab(fromTab ? (entry.uncooked ? "uncooked" : "cooked") : "ingredients");
    setDragging(true);
    setDragHint(decompose ? _L("cook.draghint_prep_apart") : _L("cook.draghint_prep_stack"));
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
        sig, stack: entry.stack, state: entry.stackState, finishTool: entry.finishTool,
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
        setWorldDragging(true);
        dragSwitchTab("cooked"); // a placed part is a cooked product
        setDragHint(_L("cook.draghint_restack"));
        fetchNui("cooking:prepGrab", { puid });
        return;
      }
      // no part hovered: grab the serving tray itself (with everything on it)
      const tid = trayHoveredRef.current;
      if (tid != null) {
        // a pizza box waits to see what the press becomes: a click toggles the
        // lid, moving past the drag threshold grabs the whole box (onMove)
        if (trayHoveredBoxRef.current) {
          pendingBoxRef.current = { tid, x: e.clientX, y: e.clientY };
          return;
        }
        prepMoveRef.current = { tray: true };
        setDragging(true);
        setWorldDragging(true);
        dragSwitchTab("cooked");
        setDragHint(_L("cook.draghint_tray_meal"));
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
      // a pressed pizza box that travels past the threshold becomes a grab drag
      const pb = pendingBoxRef.current;
      if (pb) {
        const dx = e.clientX - pb.x, dy = e.clientY - pb.y;
        if (dx * dx + dy * dy > DRAG_THRESH) {
          pendingBoxRef.current = null;
          prepMoveRef.current = { tray: true };
          setDragging(true);
          setWorldDragging(true);
          dragSwitchTab("cooked");
          setDragHint("Drop on the bar to box it up — or set the box down elsewhere");
          fetchNui("cooking:trayGrab", { tid: pb.tid });
        }
      }
      const w = worldRef.current;
      if (w && w.uid != null && !w.dragging) {
        const dx = e.clientX - w.startX, dy = e.clientY - w.startY;
        if (dx * dx + dy * dy > DRAG_THRESH) {
          // an item in a lowered fryer basket can't be grabbed at all — the drag
          // never starts (no reaching into hot oil; raise the basket first)
          if (itemsRef.current.find((c) => c.uid === w.uid)?.locked) return;
          w.dragging = true;
          setDragging(true);       // hide the tooltip while moving the prop
          setWorldDragging(true);  // darken the hotbar as the drop zone
          setDragHint("Drop on the bar to collect it — or set it back down");
          dragSwitchTab("cooked"); // dragging a cooked prop -> show where it'll land
          fetchNui("cooking:beginMove", { uid: w.uid });
        }
      }
    };
    const onUp = (e: PointerEvent) => {
      const overBar = !!barRef.current && inRect(e.clientX, e.clientY, barRef.current.getBoundingClientRect());
      setDragging(false);
      setDragHint(null);
      setWorldDragging(false);
      // keep the drag's category only when it lands on the prep (not on the bar /
      // cancelled) — else fall back to the tab we were browsing before the drag
      endDragTab(!overBar);

      // a press on a pizza box that never became a drag: a click — toggle the lid
      if (pendingBoxRef.current) {
        const tid = pendingBoxRef.current.tid;
        pendingBoxRef.current = null;
        fetchNui("cooking:boxToggle", { tid });
        return;
      }

      // dragging a fresh serving tray / pizza box out of the bar: drop on the
      // table places it
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

      // baking mix released before the tray is full: cancels harmlessly (nothing
      // consumed). At full coverage the Lua side already filled the tray and cleared
      // the drag via cookingBakeDone.
      if (bakeMixRef.current) {
        bakeMixRef.current = null;
        fetchNui("cooking:endBakeMix", { cancel: overBar });
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
    // tray + pizza box + lid are kitchen equipment, never gated on an item count
    ing.kind === "tray" || ing.kind === "pizzabox" || ing.kind === "lid" ? true : ing.kind === "assembly" ? !!ing.canMake : (ing.count || 0) > 0;

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
          {tipEntry.count > 1 ? _L("cook.take_1") : _L("cook.take")}
        </button>
        {tipEntry.count > 1 && (
          <button
            onClick={() => takeEntry(tipEntry, tipEntry.count)}
            className="rounded-md bg-secondary px-2.5 py-1 text-[11px] font-semibold text-foreground transition hover:bg-accent"
          >
            {_L("cook.take_all")}
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
          {confirmKey === tipKey ? _L("cook.confirm") : _L("cook.discard")}
        </button>
      </div>
    ) : null;

  return (
    <>
      {/* world layer — press to grab/drag the hovered prop, click to flip it or
          toggle an oven door. The status panel above sits over this layer but is
          click-through, so clicks still reach the patty. */}
      <div className="fixed inset-0" onPointerDown={onWorldDown} />

      {/* instructional dotted drop-zone for a drag OUT of the bar (onto the world/table).
          A drag FROM the world shows the same modal over the hotbar instead (above). */}
      {dragHint && !worldDragging && (
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
          {tip?.bake ? (
            <BakeTrayTooltip filled={!!tip.filled} onPin={onTipPin} />
          ) : tip?.tray ? (
            <MealTooltip count={tip.count || 0} box={!!tip.box} open={!!tip.open} boxing={!!tip.boxing}
              onMake={onMealMake} onTakeOut={onBoxTakeOut} onPin={onTipPin} />
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

      {/* full-width bottom bar — the kitchen rail, wearing the franchise theme */}
      <div
        ref={barRef}
        className="fixed inset-x-0 bottom-0 animate-fade-in border-t border-border bg-background px-4 py-3 shadow-2xl"
      >
        <div className="brand-hairline absolute inset-x-0 top-0 h-0.5" />
        {/* dragging a prop FROM the world: a SEPARATE dark overlay laid over the whole
            hotbar, with the dotted drop-zone modal centred on it — the hotbar itself is
            the drop target (drop here to collect / make a meal). */}
        {worldDragging && (
          <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center bg-black/25">
            <div className="flex items-center gap-2 rounded-2xl border-2 border-dashed border-primary/60 bg-primary/5 px-10 py-4">
              <UtensilsCrossed className="h-6 w-6 text-primary/80" />
              <span className="text-sm font-semibold text-primary">{dragHint || "Drop here to collect it"}</span>
            </div>
          </div>
        )}
        <div className="mb-2 flex items-center justify-between">
          <div className="flex min-w-0 items-center gap-2.5">
            <div className="grid h-7 w-7 shrink-0 place-items-center rounded-md bg-primary/15 text-primary">
              <Icon className="h-4 w-4" />
            </div>
            <span className="font-display text-sm font-bold tracking-tight">{meta.label}</span>
            <span className="truncate text-xs text-muted-foreground">{meta.hint}</span>
          </div>
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <UtensilsCrossed className="h-3.5 w-3.5" />
            {_L("cook.drag_cooked_here")}
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
            ["ingredients", _L("cook.tab_ingredients"), Carrot, 0],
            ["cooked", _L("cook.tab_cooked_items"), ChefHat, cookedTotal],
            ["uncooked", _L("cook.tab_uncooked_items"), CookingPot, uncookedTotal],
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
                {confirmKey === "__burnt__" ? _L("cook.click_again_confirm") : _L("cook.discard_burnt", burntTotal)}
              </button>
            )}
            <div className="relative">
              <Search className="pointer-events-none absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder={_L("cook.search_placeholder")}
                className="h-[26px] w-40 rounded-md border border-border bg-muted/50 pl-7 pr-6 text-xs outline-none placeholder:text-muted-foreground/70 focus:border-primary/60"
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
              title={expanded ? _L("cook.collapse_row") : _L("cook.show_grid")}
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
                  ? _L("cook.no_matches", query.trim())
                  : _L("cook.no_ingredients")}
              </div>
            )}
            {shownIngredients.map((ing, i) => {
              const can = draggable(ing);
              const onDown = (e: React.PointerEvent) => {
                if (!can) return;
                setBarTip(null);
                if (ing.kind === "tray") startTrayPlace(e);
                else if (ing.kind === "pizzabox") startTrayPlace(e, "box");
                else if (ing.kind === "lid") startLid(e, ing);
                else if (ing.kind === "topping") startTopping(e, ing);
                else if (ing.kind === "finish") startFinish(e, ing);
                else if (ing.kind === "bakemix") startBakeMix(e, ing);
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
                      ? "cursor-grab border-border/80 bg-card hover:border-primary/50 hover:bg-accent/60 active:cursor-grabbing"
                      : "cursor-not-allowed border-dashed border-border/60 bg-muted/40 opacity-60"
                  )}
                >
                  {ing.kind === "tray" ? (
                    <UtensilsCrossed className="h-10 w-10 text-primary/80" />
                  ) : ing.kind === "pizzabox" ? (
                    <Package className="h-10 w-10 text-primary/80" />
                  ) : ing.kind === "lid" ? (
                    <CircleDot className="h-10 w-10 text-primary/80" />
                  ) : (
                    <ItemThumb src={ing.image} alt={ing.label} className={ing.kind === "finish" ? "h-8 w-8 object-contain" : "h-10 w-10 object-contain"} />
                  )}
                  <span className="w-full truncate px-1.5 leading-tight">{ing.label}</span>
                  {ing.kind === "tray" && (
                    <span className="text-[10px] text-muted-foreground">{_L("cook.build_a_meal")}</span>
                  )}
                  {ing.kind === "pizzabox" && (
                    <span className="text-[10px] text-muted-foreground">Boxes a pizza</span>
                  )}
                  {ing.kind === "lid" && (
                    <span className="text-[10px] text-muted-foreground">{_L("cook.caps_filled_drink")}</span>
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
                  {ing.kind !== "assembly" && ing.kind !== "tray" && ing.kind !== "pizzabox" && ing.kind !== "lid" && (
                    <Badge variant="secondary" className="absolute right-1 top-1">{ing.count ?? 0}</Badge>
                  )}
                  {ing.kind === "assembly" && !ing.canMake && (
                    <span className="text-[10px] text-muted-foreground">{_L("cook.missing_parts")}</span>
                  )}
                </div>
              );
            })}
          </div>
        ) : (
          <div className={rowCls} onWheel={onRowWheel}>
            {/* kitchen equipment leads the strip: the serving tray and pizza box the
                cooked food gets arranged on/in — same drag-to-place gesture as before */}
            {tab === "cooked" &&
              equipmentCards.map((ing) => (
                <div
                  key={"equip-" + ing.kind + (ing.subkind || "")}
                  onPointerDown={(e) => {
                    setBarTip(null);
                    if (ing.kind === "tray") startTrayPlace(e);
                    else if (ing.kind === "baketray") startTrayPlace(e, ing.subkind);
                    else startTrayPlace(e, "box");
                  }}
                  onPointerEnter={(ev) => showBarTip(ev, { ing, hint: ingHint(ing) })}
                  onPointerLeave={hideBarTip}
                  className="relative flex h-32 w-28 shrink-0 cursor-grab touch-none select-none flex-col items-center justify-center gap-1 rounded-lg border border-border/80 bg-card text-center text-xs font-medium hover:border-primary/50 hover:bg-accent/60 active:cursor-grabbing"
                >
                  {ing.kind === "tray" ? (
                    <UtensilsCrossed className="h-10 w-10 text-primary/80" />
                  ) : ing.kind === "baketray" ? (
                    <CookingPot className="h-10 w-10 text-primary/80" />
                  ) : (
                    <Package className="h-10 w-10 text-primary/80" />
                  )}
                  <span className="w-full truncate px-1.5 leading-tight">{ing.label}</span>
                  <span className="text-[10px] text-muted-foreground">
                    {ing.kind === "tray" ? "Build a meal" : ing.kind === "baketray" ? "Rub in the mix" : "Boxes a pizza"}
                  </span>
                </div>
              ))}
            {trayList.length === 0 && (tab !== "cooked" || equipmentCards.length === 0) && (
              <div className="text-sm text-muted-foreground">
                {q && trayListAll.length > 0
                  ? _L("cook.no_matches", query.trim())
                  : tab === "uncooked"
                    ? _L("cook.no_uncooked_items")
                    : _L("cook.no_cooked_items")}
              </div>
            )}
            {trayList.map((e, i) => {
              const cookHere = canCookHere(e);
              const fromInv = e.source === "inv";
              const cardKey = e.item + "|" + (e.cheese || 0) + "|" + (e.sig || "") + "|" + (e.source || "tray") + "|" + i;
              // freshness: show a red countdown only in the final minute before it spoils
              const secs = expirySecs(e);
              const expiring = secs != null && secs > 0 && secs <= 59;
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
                  "relative flex h-32 w-28 shrink-0 touch-none select-none flex-col items-center rounded-lg border bg-card pt-2 text-center text-xs font-medium",
                  e.burnt ? "border-red-900/70 bg-red-950/25" : "border-border/80",
                  (isPrep || cookHere) ? "cursor-grab hover:border-primary/50 hover:bg-accent/60 active:cursor-grabbing" : e.burnt ? "hover:border-red-800" : "hover:border-border"
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
                  {cookHere && (
                    <span className="rounded bg-primary/15 px-1.5 py-0.5 text-[9px] font-semibold text-primary">
                      {station === "fryer" ? _L("cook.drag_into_basket") : _L("cook.drag_into_oven")}
                    </span>
                  )}
                </div>
                <Badge variant="secondary" className="absolute right-1 top-1">{e.count}</Badge>
                {/* origin marker (inventory item) + cheese state + freshness countdown.
                    The timer is always shown for a tray item that can spoil, red only
                    in its final minute. */}
                <div className="absolute left-1 top-1 flex items-center gap-0.5">
                  {secs != null && (
                    <span className={cn(
                      "flex items-center gap-0.5 rounded px-1 py-px text-[9px] font-bold tabular-nums",
                      expiring
                        ? "bg-red-500/25 text-red-300 ring-1 ring-red-500/40"
                        : "border border-border bg-background/70 text-muted-foreground"
                    )}>
                      <Timer className="h-2.5 w-2.5" />{fmtExpiry(secs)}
                    </span>
                  )}
                  {fromInv && (
                    <span className="rounded border border-border bg-background/70 px-1 py-px text-[8px] font-semibold uppercase tracking-wide text-muted-foreground">
                      {_L("cook.item_badge")}
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
