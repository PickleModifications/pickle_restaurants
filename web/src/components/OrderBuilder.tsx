import { useEffect, useMemo, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  Plus, Minus, Trash2, User, Receipt, Check, X, Loader2, ImageOff, SlidersHorizontal, Ban, UtensilsCrossed, ShoppingBag,
} from "lucide-react";

// Shared point-of-sale building blocks used by the staff register — both the
// full-screen NUI panel (views/Register.tsx) and the in-world register DUI
// (views/RegisterDui.tsx) — and the customer self-service kiosk DUI
// (views/KioskDui.tsx), so the catalog grid, modifier picker, cart and pricing can
// never drift between them. The kiosk's only behavioural differences: no "who pays"
// customer picker (the customer always pays for their own order) and a different
// submit event. The `big` prop selects the large in-world layout independently of
// those behaviours (see the OrderBuilder doc-comment).

export type Mod = { id: string; label: string; item?: string; price?: number; default?: boolean; image?: string; group?: string; color?: string };
export type Cat = { key: string; item: string; variant: string; label: string; kind: string; price: number; image?: string; modifiers?: Mod[] };
// A combo option is just a sellable Cat entry surfaced inside a slot (carries its
// own modifiers). A slot with >1 option is a "choose one"; ==1 is a fixed item.
export type ComboOpt = { key: string; item: string; variant: string; label: string; image?: string; kind: string; modifiers?: Mod[] };
export type ComboSlot = { label: string; options: ComboOpt[] };
export type Combo = { comboId: number; number: number; label: string; price: number; slots: ComboSlot[]; photo?: { url: string; crop?: any } | null };
export type LineMod = { id?: string; label: string; price?: number; added?: boolean; removed?: boolean; image?: string; color?: string };
// A server-resolved ticket line. `combo` groups the component lines of one combo
// bundle (all sharing the same id + inst, emitted contiguously by the server).
export type LineCombo = { id: number; number: number; label: string; inst: number; seq: number; size: number };
export type Line = { item: string; variant: string; label: string; price: number; qty: number; kind: string; image?: string; mods?: LineMod[]; combo?: LineCombo };

// Group a ticket's lines into render blocks: a lone item, or a combo (its number,
// label, qty + component lines). Combo component lines are contiguous and share
// combo.id + combo.inst, so a single pass collapses them.
export type LineBlock =
  | { type: "item"; line: Line }
  | { type: "combo"; number: number; label: string; qty: number; comps: Line[] };
export function groupLines(lines: Line[]): LineBlock[] {
  const out: LineBlock[] = [];
  for (let i = 0; i < lines.length; ) {
    const l = lines[i];
    if (l.combo) {
      const comps: Line[] = [];
      let j = i;
      while (j < lines.length && lines[j].combo
        && lines[j].combo!.id === l.combo.id && lines[j].combo!.inst === l.combo.inst) {
        comps.push(lines[j]); j++;
      }
      out.push({ type: "combo", number: l.combo.number, label: l.combo.label, qty: l.qty, comps });
      i = j;
    } else {
      out.push({ type: "item", line: l });
      i++;
    }
  }
  return out;
}
// A selected option to render as an image chip (added extra, or a removed default).
export type OptView = { label: string; image?: string; color?: string };
// One layer of a meal, spelled out for the in-depth picker: the item's label +
// image, plus its toppings (cheese/lettuce as item images, frosting/sprinkles as
// coloured swatches).
export type MealItem = { item: string; label: string; image?: string; mods?: OptView[] };
// A meal in the shared pool that (with single items) would complete the whole
// order — offered as a fulfillment option. `items` is its full contents.
export type MealOption = { sig: string; label: string; items?: MealItem[] };
// Per-ticket fulfillment state from the shared cooked-items pool (server-computed).
// `ok` = completable with single items alone; `mealOptions` = meals that complete it;
// `missing` = the single-item shortfall shown when nothing can complete it.
export type Fulfill = { ok: boolean; mealOptions?: MealOption[]; missing?: string[] };
// `npc` flags an AI walk-in customer; those carry a patience countdown (`expiresIn`
// seconds left at send time, ticked down locally) out of `patience` total seconds
// (the radial's denominator). Player tickets have npc=false and no timer fields.
export type Ticket = { orderId: number; ticket: number; customer: string; lines: Line[]; total: number; fulfill?: Fulfill; npc?: boolean; expiresIn?: number; patience?: number };
export type Near = { id: number; name: string };
// A cart entry: either a single catalog item (which item, how many, selected
// modifier ids) or a combo bundle (which combo, how many, and per-slot chosen
// key + that item's selected modifier ids).
export type CartEntry =
  | { type: "item"; catKey: string; qty: number; sel: string[] }
  | { type: "combo"; comboId: number; qty: number; picks: { key: string; sel: string[] }[] };

// A resolved cart row for rendering/pricing: a single item, or a combo with its
// per-slot resolved components (chosen option + its added/removed mods).
type ItemBlock = { ck: string; type: "item"; cat: Cat; qty: number; price: number; added: Mod[]; removed: Mod[] };
type ComboComp = { opt: ComboOpt; added: Mod[]; removed: Mod[] };
type ComboBlock = { ck: string; type: "combo"; combo: Combo; qty: number; price: number; comps: ComboComp[] };
type CartBlock = ItemBlock | ComboBlock;

// Coerce a server list to a real array. Lua/JSON encodes an EMPTY list as `{}`
// (an object, not `[]`), so a plain `x || []` would keep that `{}` and any
// `.map`/`.filter` on it would throw and take the whole panel down.
export const arr = <T,>(x: unknown): T[] => (Array.isArray(x) ? (x as T[]) : []);

// Inventory thumbnail from a direct nui:// url the server resolved, with a
// graceful fallback (different inventories store images differently).
export function Thumb({ src, className }: { src?: string; className?: string }) {
  const [broken, setBroken] = useState(false);
  useEffect(() => setBroken(false), [src]);
  if (!src || broken) {
    return (
      <div className={cn("flex items-center justify-center rounded bg-muted/60 text-muted-foreground", className)}>
        <ImageOff className="h-1/2 w-1/2" />
      </div>
    );
  }
  return <img src={src} onError={() => setBroken(true)} className={cn("rounded object-contain", className)} />;
}

// Combo photo (owner-set url + crop). The precise crop is honoured on the menu
// board; here a cover image is enough. Falls back to a utensil placeholder.
export function ComboThumb({ photo, label, className }: { photo?: { url: string; crop?: any } | null; label?: string; className?: string }) {
  const [broken, setBroken] = useState(false);
  useEffect(() => setBroken(false), [photo?.url]);
  if (!photo?.url || broken) {
    return (
      <div className={cn("flex items-center justify-center bg-muted/60 text-muted-foreground", className)}>
        <UtensilsCrossed className="h-1/3 w-1/3" />
      </div>
    );
  }
  return <img src={photo.url} onError={() => setBroken(true)} className={cn("object-cover", className)} alt={label} />;
}

export const KIND_LABEL: Record<string, string> = {
  recipe: "register.kind_recipe",
  assembly: "register.kind_assembly",
  craft: "register.kind_craft",
  drink: "register.kind_drink",
  finish: "register.kind_finish",
};

// The additions (+X) / removals (no Y) a selection implies, plus the price the
// selected add-ons add on top of the base — computed identically on the server.
export function resolveMods(cat: Cat, sel: string[]) {
  const set = new Set(sel);
  const added: Mod[] = [], removed: Mod[] = [];
  let extra = 0;
  for (const m of cat.modifiers || []) {
    const on = set.has(m.id);
    if (on && !m.default) { added.push(m); extra += m.price || 0; }
    else if (m.default && !on) removed.push(m);
  }
  return { added, removed, extra };
}

// A single selected-option chip: the modifier's item image (or a flavor colour
// swatch), captioned by its label on hover. A removed default is dimmed and
// crossed out so "no lettuce" reads at a glance without any text. Styled for
// the receipt paper it always sits on (cart lines, tickets).
export function OptChip({ o, removed }: { o: OptView; removed?: boolean }) {
  return (
    <span
      title={(removed ? _L("register.opt_no") + " " : "") + o.label}
      className={cn(
        "relative flex h-6 w-6 shrink-0 items-center justify-center rounded border bg-muted",
        removed ? "border-destructive/50" : "border-border",
      )}
    >
      {o.image
        ? <Thumb src={o.image} className={cn("h-5 w-5", removed && "opacity-40")} />
        : o.color
          ? <span className={cn("h-4 w-4 rounded-full border border-border", removed && "opacity-40")} style={{ backgroundColor: o.color }} />
          : <div className={cn("grid h-5 w-5 place-items-center rounded text-muted-foreground", removed && "opacity-40")}><ImageOff className="h-3 w-3" /></div>}
      {removed && (
        <span className="pointer-events-none absolute inset-0 flex items-center justify-center text-destructive"><Ban className="h-4 w-4" /></span>
      )}
    </span>
  );
}

// The secondary row of an item line: its selected options rendered as image
// chips (added extras first, then crossed-out removed defaults). Empty = nothing.
export function OptRow({ added, removed }: { added: OptView[]; removed: OptView[] }) {
  if (added.length === 0 && removed.length === 0) return null;
  return (
    <div className="mt-1 flex flex-wrap items-center gap-1">
      {added.map((o, i) => <OptChip key={"a" + i} o={o} />)}
      {removed.map((o, i) => <OptChip key={"r" + i} o={o} removed />)}
    </div>
  );
}

// A single modifier tile: item image, or a flavor colour swatch, or a fallback.
// `big` scales it up for the kiosk's larger dialogs.
function ModTile({ m, on, onClick, big }: { m: Mod; on: boolean; onClick: () => void; big?: boolean }) {
  return (
    <button onClick={onClick}
      className={cn("relative flex flex-col items-center rounded-lg border text-center transition-colors",
        big ? "gap-1.5 p-3" : "gap-1 p-2",
        on ? "border-primary bg-primary/10 ring-1 ring-primary" : "border-border hover:border-primary/50 hover:bg-accent/50")}>
      {on && (
        <span className={cn("absolute right-1 top-1 grid place-items-center rounded-full bg-primary text-primary-foreground", big ? "h-5 w-5" : "h-4 w-4")}>
          <Check className={big ? "h-3.5 w-3.5" : "h-3 w-3"} />
        </span>
      )}
      {m.image
        ? <Thumb src={m.image} className={big ? "h-16 w-16" : "h-12 w-12"} />
        : m.color
          ? <span className={cn("rounded-full border border-border", big ? "h-16 w-16" : "h-12 w-12")} style={{ backgroundColor: m.color }} />
          : <div className={cn("grid place-items-center rounded bg-muted/60 text-muted-foreground", big ? "h-16 w-16" : "h-12 w-12")}><ImageOff className="h-1/2 w-1/2" /></div>}
      <span className={cn("line-clamp-2 font-medium leading-tight", big ? "text-sm" : "text-xs")}>
        {m.label}
        {m.default && <span className={cn("ml-1 text-muted-foreground", big ? "text-[11px]" : "text-[9px]")}>{_L("register.mod_default")}</span>}
      </span>
      {!!m.price && !m.default && <span className={cn("text-muted-foreground", big ? "text-sm" : "text-[11px]")}>+{money(m.price)}</span>}
    </button>
  );
}

function FilterChip({ active, onClick, big, children }: { active: boolean; onClick: () => void; big?: boolean; children: React.ReactNode }) {
  return (
    <button onClick={onClick}
      className={cn("rounded-full border font-mono font-semibold uppercase tracking-wider transition-colors",
        big ? "px-5 py-2.5 text-base" : "px-2.5 py-1 text-[10px]",
        active ? "border-primary/40 bg-primary/15 text-primary" : "border-border text-muted-foreground hover:bg-accent hover:text-foreground")}>
      {children}
    </button>
  );
}

// The who-pays selector on the in-world register DUI's review sheet: a click target
// (not a native <select>, which the virtual cursor can't open) for "Myself" + each
// nearby player the cashier can charge.
function CustomerChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button onClick={onClick}
      className={cn("rounded-full border px-4 py-2 text-base font-medium transition-colors",
        active ? "border-primary bg-primary/15 text-primary ring-1 ring-primary" : "border-border text-muted-foreground hover:bg-accent hover:text-foreground")}>
      {children}
    </button>
  );
}

// The catalog + modifier picker + cart. In "register" mode the cashier can charge
// a nearby player (the customer picker); in "kiosk" mode the customer always pays
// for their own order (no picker) and the submit reads "Place Order". `onOrdered`
// fires with the new ticket number after a successful submit.
//
// `big` forces the large, in-world layout (big cards + a checkout review sheet)
// used on an interactive DUI screen, whose virtual cursor needs generous aim
// targets. The kiosk mode always implies it; the staff register DUI passes it
// explicitly while keeping register SEMANTICS (the customer picker + "Charge" +
// createOrder). The full-screen register NUI leaves it off for the dense POS layout.
export function OrderBuilder({
  id, catalog, combos, nearby, mode, big: bigProp, onOrdered,
}: {
  id: number;
  catalog: Cat[];
  combos?: Combo[];
  nearby?: Near[];
  mode: "register" | "kiosk";
  big?: boolean;
  onOrdered?: (ticket?: number) => void;
}) {
  const [cart, setCart] = useState<Record<string, CartEntry>>({});
  const [customer, setCustomer] = useState(0); // 0 = Myself
  const [kind, setKind] = useState<string>("all");
  const [busy, setBusy] = useState(false);
  const [modFor, setModFor] = useState<Cat | null>(null); // item being customised
  const [modSel, setModSel] = useState<string[]>([]);
  const [modQty, setModQty] = useState(1); // how many to add from the item dialog
  const [comboFor, setComboFor] = useState<Combo | null>(null); // combo being built
  const [comboPicks, setComboPicks] = useState<{ key: string; sel: string[] }[]>([]);
  const [reviewing, setReviewing] = useState(false); // kiosk: the cart-review sheet is open

  const comboList = useMemo(() => arr<Combo>(combos), [combos]);
  const kinds = useMemo(() => Array.from(new Set(catalog.map((c) => c.kind))), [catalog]);
  const shown = kind === "all" || kind === "combo" ? catalog : catalog.filter((c) => c.kind === kind);
  const showCombos = comboList.length > 0 && (kind === "all" || kind === "combo");
  const showItems = kind !== "combo";
  const byKey = useMemo(() => Object.fromEntries(catalog.map((c) => [c.key, c])), [catalog]);
  const comboById = useMemo(() => Object.fromEntries(comboList.map((c) => [c.comboId, c])), [comboList]);

  const itemCartKey = (catKey: string, sel: string[]) => "i#" + catKey + "#" + [...sel].sort().join(",");
  const comboCartKey = (comboId: number, picks: { key: string; sel: string[] }[]) =>
    "c#" + comboId + "#" + picks.map((p) => p.key + ":" + [...p.sel].sort().join("|")).join(",");

  const addItemEntry = (catKey: string, sel: string[], qty = 1) => setCart((c) => {
    const ck = itemCartKey(catKey, sel);
    const prev = c[ck];
    return { ...c, [ck]: { type: "item", catKey, sel, qty: Math.min(10, (prev?.qty || 0) + qty) } };
  });
  const addComboEntry = (comboId: number, picks: { key: string; sel: string[] }[]) => setCart((c) => {
    const ck = comboCartKey(comboId, picks);
    const prev = c[ck];
    return { ...c, [ck]: { type: "combo", comboId, picks, qty: Math.min(10, (prev?.qty || 0) + 1) } };
  });
  const changeQty = (ck: string, delta: number) => setCart((c) => {
    const prev = c[ck]; if (!prev) return c;
    const q = Math.min(10, prev.qty + delta);
    const next = { ...c };
    if (q <= 0) delete next[ck]; else next[ck] = { ...prev, qty: q };
    return next;
  });
  const removeEntry = (ck: string) => setCart((c) => { const n = { ...c }; delete n[ck]; return n; });

  // The modifier ids a freshly-opened option starts with: its defaults, plus — for a
  // drink (a single-choice flavor group with no default) — the first flavor, so the
  // picker always opens with a flavor chosen (a drink must carry one).
  const seedSel = (c?: { kind?: string; modifiers?: Mod[] }): string[] => {
    const base = (c?.modifiers || []).filter((m) => m.default).map((m) => m.id);
    if (c?.kind === "drink" && !base.length && c.modifiers && c.modifiers.length) base.push(c.modifiers[0].id);
    return base;
  };
  // Click a card: open the item dialog (choose modifiers + quantity, then add). On
  // the register a plain item with no modifiers still drops straight in — the fast
  // path a cashier wants; the kiosk always opens the dialog so a customer gets a
  // confirming "Add to Order" step and a quantity picker.
  const clickCard = (c: Cat) => {
    if ((c.modifiers && c.modifiers.length) || mode === "kiosk") {
      setModFor(c);
      setModSel(seedSel(c));
      setModQty(1);
    } else {
      addItemEntry(c.key, []);
    }
  };
  // Click a combo: open the builder seeded with each slot's first option + that
  // option's default modifiers (and a drink slot's first flavor).
  const clickCombo = (combo: Combo) => {
    setComboFor(combo);
    setComboPicks(combo.slots.map((slot) => {
      const opt = slot.options[0];
      return { key: opt?.key || "", sel: seedSel(opt) };
    }));
  };
  // Ungrouped modifiers toggle freely; a grouped modifier is single-choice —
  // picking one clears the rest of its group, clicking the picked one = none.
  const toggleModOn = (mods: Mod[], sel: string[], m: Mod): string[] => {
    if (!m.group) return sel.includes(m.id) ? sel.filter((x) => x !== m.id) : [...sel, m.id];
    const groupIds = new Set(mods.filter((x) => x.group === m.group).map((x) => x.id));
    const without = sel.filter((x) => !groupIds.has(x));
    return sel.includes(m.id) ? without : [...without, m.id];
  };
  const toggleMod = (m: Mod) => setModSel((s) => toggleModOn(modFor?.modifiers || [], s, m));
  // combo slot: pick a different option (resets that slot's modifiers to its defaults)
  const pickComboOption = (si: number, opt: ComboOpt) => setComboPicks((ps) =>
    ps.map((p, i) => (i === si ? { key: opt.key, sel: seedSel(opt) } : p)));
  const toggleComboMod = (si: number, opt: ComboOpt, m: Mod) => setComboPicks((ps) =>
    ps.map((p, i) => (i === si ? { ...p, sel: toggleModOn(opt.modifiers || [], p.sel, m) } : p)));

  // Cart blocks — either a single item line or a grouped combo (its components).
  const blocks = Object.entries(cart).map(([ck, e]) => {
    if (e.type === "item") {
      const cat = byKey[e.catKey];
      if (!cat) return null;
      const { added, removed, extra } = resolveMods(cat, e.sel);
      return { ck, type: "item" as const, cat, qty: e.qty, price: cat.price + extra, added, removed };
    }
    const combo = comboById[e.comboId];
    if (!combo) return null;
    let extra = 0;
    const comps = combo.slots.map((slot, i) => {
      const pick = e.picks[i];
      const opt = slot.options.find((o) => o.key === pick?.key) || slot.options[0];
      const r = resolveMods(opt as unknown as Cat, pick?.sel || []);
      extra += r.extra;
      return { opt, added: r.added, removed: r.removed };
    });
    return { ck, type: "combo" as const, combo, qty: e.qty, price: combo.price + extra, comps };
  }).filter(Boolean) as CartBlock[];
  const total = blocks.reduce((s, b) => s + b.price * b.qty, 0);
  const count = blocks.reduce((s, b) => s + b.qty, 0);

  // The wire form of the cart: keys + counts + modifier ids, never labels or prices —
  // the server re-derives those from its own priced catalog.
  const cartWire = () => Object.values(cart).map((e) =>
    e.type === "combo"
      ? { combo: e.comboId, qty: e.qty, slots: e.picks.map((p) => ({ key: p.key, mods: p.sel })) }
      : { key: e.catKey, qty: e.qty, mods: e.sel });

  const submit = async () => {
    if (blocks.length === 0 || busy) return;
    setBusy(true);
    const cartArr = cartWire();
    const event = mode === "kiosk" ? "sales:kioskOrder" : "sales:createOrder";
    const payload = mode === "kiosk" ? { id, cart: cartArr } : { id, customer, cart: cartArr };
    const res: any = await fetchNui(event, payload);
    setBusy(false);
    if (res && res.ok) {
      setCart({}); // register: the new ticket arrives via the `orders` broadcast
      onOrdered?.(res.ticket);
    }
  };

  const modExtra = modFor ? resolveMods(modFor, modSel).extra : 0;
  const comboExtra = comboFor
    ? comboFor.slots.reduce((s, slot, i) => {
        const opt = slot.options.find((o) => o.key === comboPicks[i]?.key) || slot.options[0];
        return s + resolveMods(opt as unknown as Cat, comboPicks[i]?.sel || []).extra;
      }, 0)
    : 0;
  // Large in-world layout: the kiosk always, and the staff register DUI on request.
  // Drives every SIZE/LAYOUT decision below; `mode` still drives BEHAVIOUR (who-pays
  // picker, submit event + button copy), so the register DUI reads big but still
  // charges a customer.
  const big = mode === "kiosk" || !!bigProp;

  // Quantity stepper + remove for a cart row. `big` scales it up for the kiosk
  // review sheet (the in-world screen needs larger touch/aim targets).
  const qtyCtrl = (b: CartBlock, big = false) => (
    <div className={cn("flex shrink-0 items-center", big ? "gap-2" : "gap-1")}>
      <button onClick={() => changeQty(b.ck, -1)} className={cn("grid place-items-center rounded border border-border transition-colors hover:bg-accent", big ? "h-10 w-10" : "h-6 w-6")}><Minus className={big ? "h-5 w-5" : "h-3 w-3"} /></button>
      <span className={cn("text-center font-mono tabular-nums", big ? "w-8 text-lg" : "w-5 text-xs")}>{b.qty}</span>
      <button onClick={() => changeQty(b.ck, 1)} className={cn("grid place-items-center rounded border border-border transition-colors hover:bg-accent", big ? "h-10 w-10" : "h-6 w-6")}><Plus className={big ? "h-5 w-5" : "h-3 w-3"} /></button>
      <button onClick={() => removeEntry(b.ck)} className={cn("grid place-items-center rounded text-muted-foreground transition-colors hover:text-destructive", big ? "h-10 w-10" : "h-6 w-6")}><Trash2 className={big ? "h-5 w-5" : "h-3 w-3"} /></button>
    </div>
  );

  // One cart row — a single item or a combo bundle with its component lines.
  // Shared by the register receipt (`big=false`) and the kiosk review (`big=true`).
  const cartLine = (b: CartBlock, big = false) => {
    if (b.type === "item") {
      return (
        <div key={b.ck} className={cn("flex items-center rounded-sm bg-muted/50", big ? "gap-4 p-4" : "gap-2 p-1.5")}>
          <Thumb src={b.cat.image} className={cn("shrink-0", big ? "h-16 w-16" : "h-8 w-8")} />
          <div className="min-w-0 flex-1">
            <div className={cn("truncate font-medium", big ? "text-lg" : "text-xs")}>{b.cat.label}</div>
            <OptRow added={b.added} removed={b.removed} />
            <div className={cn("font-mono tabular-nums text-muted-foreground", big ? "text-base" : "text-[11px]")}>{money(b.price)}</div>
          </div>
          {qtyCtrl(b, big)}
        </div>
      );
    }
    return (
      <div key={b.ck} className={cn("rounded-sm bg-muted/50", big ? "p-4" : "p-1.5")}>
        <div className={cn("flex items-center", big ? "gap-4" : "gap-2")}>
          <span className={cn("grid shrink-0 place-items-center rounded bg-primary/15 font-mono font-bold text-primary tabular-nums", big ? "h-16 w-16 text-lg" : "h-8 w-8 text-xs")}>#{b.combo.number}</span>
          <div className="min-w-0 flex-1">
            <div className={cn("truncate font-semibold", big ? "text-lg" : "text-xs")}>{b.combo.label}</div>
            <div className={cn("font-mono tabular-nums text-muted-foreground", big ? "text-base" : "text-[11px]")}>{money(b.price)}</div>
          </div>
          {qtyCtrl(b, big)}
        </div>
        <div className={cn("mt-1 space-y-0.5 border-l border-border/60", big ? "pl-3" : "pl-2")}>
          {b.comps.map((comp, i) => (
            <div key={i} className="flex items-center gap-1.5">
              <Thumb src={comp.opt.image} className={cn("shrink-0", big ? "h-8 w-8" : "h-5 w-5")} />
              <span className={cn("truncate", big ? "text-base" : "text-[11px]")}>{comp.opt.label}</span>
              {(comp.added.length > 0 || comp.removed.length > 0) && (
                <span className="flex items-center gap-0.5">
                  {comp.added.map((o, j) => <OptChip key={"a" + j} o={o} />)}
                  {comp.removed.map((o, j) => <OptChip key={"r" + j} o={o} removed />)}
                </span>
              )}
            </div>
          ))}
        </div>
      </div>
    );
  };

  // The modifier + combo builder dialogs are absolute overlays shared by both
  // layouts (register grid and kiosk column).
  const dialogs = (
    <>
      {/* modifier dialog */}
      {modFor && (
        <div className={cn(big ? "fixed" : "absolute", "inset-0 z-40 flex items-center justify-center bg-black/50", big ? "p-10" : "p-4")} onClick={() => setModFor(null)}>
          <div className={cn("w-full rounded-2xl border border-border bg-card shadow-xl", big ? "max-w-xl p-6" : "max-w-sm p-4")} onClick={(e) => e.stopPropagation()}>
            <div className={cn("flex items-center", big ? "mb-5 gap-4" : "mb-3 gap-2")}>
              <Thumb src={modFor.image} className={cn("shrink-0", big ? "h-16 w-16" : "h-10 w-10")} />
              <div className="min-w-0 flex-1">
                <div className={cn("truncate font-semibold", big && "text-2xl")}>{modFor.label}</div>
                <div className={cn("text-muted-foreground", big ? "text-lg" : "text-xs")}>{money(modFor.price)}</div>
              </div>
              <button onClick={() => setModFor(null)} className="text-muted-foreground hover:text-foreground"><X className={big ? "h-7 w-7" : "h-4 w-4"} /></button>
            </div>
            {(modFor.modifiers || []).length > 0 && (
              <div className={cn("overflow-y-auto p-0.5", big ? "max-h-[46vh] space-y-4" : "max-h-72 space-y-3")}>
                {(() => {
                  const all = modFor.modifiers || [];
                  const ungrouped = all.filter((m) => !m.group);
                  const groupNames = Array.from(new Set(all.filter((m) => m.group).map((m) => m.group as string)));
                  return (
                    <>
                      {ungrouped.length > 0 && (
                        <div className="grid grid-cols-3 gap-2">
                          {ungrouped.map((m) => <ModTile key={m.id} m={m} big={big} on={modSel.includes(m.id)} onClick={() => toggleMod(m)} />)}
                        </div>
                      )}
                      {groupNames.map((g) => (
                        <div key={g}>
                          <div className={cn("mb-1 font-semibold uppercase tracking-wide text-muted-foreground", big ? "text-sm" : "text-xs")}>{g}</div>
                          <div className="grid grid-cols-3 gap-2">
                            {all.filter((m) => m.group === g).map((m) => <ModTile key={m.id} m={m} big={big} on={modSel.includes(m.id)} onClick={() => toggleMod(m)} />)}
                          </div>
                        </div>
                      ))}
                    </>
                  );
                })()}
              </div>
            )}
            <div className={cn("flex items-center justify-between gap-3", big ? "mt-5" : "mt-3")}>
              <div className={cn("flex items-center", big ? "gap-3" : "gap-2")}>
                <button onClick={() => setModQty((q) => Math.max(1, q - 1))} disabled={modQty <= 1}
                  className={cn("grid place-items-center rounded-md border border-border transition-colors hover:bg-accent disabled:opacity-40", big ? "h-12 w-12" : "h-9 w-9")}><Minus className={big ? "h-6 w-6" : "h-4 w-4"} /></button>
                <span className={cn("text-center font-mono font-semibold tabular-nums", big ? "w-10 text-2xl" : "w-8 text-lg")}>{modQty}</span>
                <button onClick={() => setModQty((q) => Math.min(10, q + 1))} disabled={modQty >= 10}
                  className={cn("grid place-items-center rounded-md border border-border transition-colors hover:bg-accent disabled:opacity-40", big ? "h-12 w-12" : "h-9 w-9")}><Plus className={big ? "h-6 w-6" : "h-4 w-4"} /></button>
              </div>
              <Button size={big ? "lg" : "sm"} className={cn(big && "h-14 gap-2.5 px-8 text-xl")} onClick={() => { addItemEntry(modFor.key, modSel, modQty); setModFor(null); }}>
                <Plus className={big ? "h-6 w-6" : "h-4 w-4"} /> {_L("register.add_to_order")} · {money((modFor.price + modExtra) * modQty)}
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* combo builder dialog — pick each slot's option + its toppings */}
      {comboFor && (
        <div className={cn(big ? "fixed" : "absolute", "inset-0 z-40 flex items-center justify-center bg-black/50", big ? "p-10" : "p-4")} onClick={() => setComboFor(null)}>
          <div className={cn("flex max-h-full w-full flex-col rounded-2xl border border-border bg-card shadow-xl", big ? "max-w-2xl" : "max-w-md")} onClick={(e) => e.stopPropagation()}>
            <div className={cn("flex items-center border-b border-border", big ? "gap-4 p-5" : "gap-2 p-3")}>
              <span className={cn("grid shrink-0 place-items-center rounded-md bg-primary font-mono font-bold text-primary-foreground tabular-nums", big ? "h-12 w-12 text-lg" : "h-8 w-8 text-sm")}>{comboFor.number}</span>
              <div className="min-w-0 flex-1">
                <div className={cn("truncate font-semibold", big && "text-2xl")}>{comboFor.label}</div>
                <div className={cn("text-muted-foreground", big ? "text-base" : "text-xs")}>{_L("combo.customize_title")}</div>
              </div>
              <button onClick={() => setComboFor(null)} className="text-muted-foreground hover:text-foreground"><X className={big ? "h-7 w-7" : "h-4 w-4"} /></button>
            </div>
            <div className={cn("min-h-0 flex-1 overflow-y-auto", big ? "space-y-4 p-5" : "space-y-3 p-3")}>
              {comboFor.slots.map((slot, si) => {
                const pick = comboPicks[si];
                const opt = slot.options.find((o) => o.key === pick?.key) || slot.options[0];
                const isChoice = slot.options.length > 1;
                const mods = opt?.modifiers || [];
                return (
                  <div key={si} className={cn("rounded-lg border border-border/70", big ? "p-4" : "p-2.5")}>
                    <div className={cn("flex items-center gap-2", big ? "mb-2.5" : "mb-1.5")}>
                      <span className={cn("tape text-muted-foreground", big && "text-sm")}>{slot.label || opt?.label}</span>
                      {isChoice && <Badge variant="secondary">{_L("combo.choose_one")}</Badge>}
                    </div>
                    {isChoice && (
                      <div className={cn("grid grid-cols-2", big ? "mb-3 gap-2" : "mb-2 gap-1.5")}>
                        {slot.options.map((o) => (
                          <button key={o.key} onClick={() => pickComboOption(si, o)}
                            className={cn("flex items-center rounded-md border text-left transition-colors",
                              big ? "gap-2.5 p-2.5" : "gap-1.5 p-1.5",
                              o.key === opt?.key ? "border-primary bg-primary/10 ring-1 ring-primary" : "border-border hover:border-primary/50 hover:bg-accent/50")}>
                            <Thumb src={o.image} className={cn("shrink-0", big ? "h-10 w-10" : "h-7 w-7")} />
                            <span className={cn("truncate font-medium", big ? "text-base" : "text-xs")}>{o.label}</span>
                          </button>
                        ))}
                      </div>
                    )}
                    {!isChoice && (
                      <div className={cn("flex items-center gap-2", big ? "mb-3" : "mb-2")}>
                        <Thumb src={opt?.image} className={cn("shrink-0", big ? "h-11 w-11" : "h-8 w-8")} />
                        <span className={cn("truncate font-medium", big ? "text-lg" : "text-sm")}>{opt?.label}</span>
                      </div>
                    )}
                    {mods.length > 0 && (
                      <div className="grid grid-cols-3 gap-2">
                        {mods.map((m) => (
                          <ModTile key={m.id} m={m} big={big} on={(pick?.sel || []).includes(m.id)} onClick={() => toggleComboMod(si, opt, m)} />
                        ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
            <div className={cn("flex items-center justify-between border-t border-border", big ? "p-5" : "p-3")}>
              <span className={cn("font-semibold", big ? "text-xl" : "text-sm")}>{money(comboFor.price + comboExtra)}</span>
              <Button size={big ? "lg" : "sm"} className={cn(big && "h-14 gap-2.5 px-8 text-xl")} onClick={() => { addComboEntry(comboFor.comboId, comboPicks); setComboFor(null); }}>
                <Plus className={big ? "h-6 w-6" : "h-4 w-4"} /> {_L("combo.add_combo", money(comboFor.price + comboExtra))}
              </Button>
            </div>
          </div>
        </div>
      )}
    </>
  );

  // ── Kiosk layout ──────────────────────────────────────────────────────────
  // Portrait self-service screen: the menu owns the FULL width (big, readable
  // cards) and the cart collapses to a fixed footer (bag count + total + a single
  // Checkout button). Checkout opens a review sheet — the only place to edit qty
  // or remove, since the side receipt is gone — where the order is finally placed.
  if (big) {
    return (
      <div className="relative flex h-full flex-col bg-background">
        <div className="flex shrink-0 flex-wrap gap-2 px-5 pb-3 pt-5">
          <FilterChip big active={kind === "all"} onClick={() => setKind("all")}>{_L("register.all_items")}</FilterChip>
          {comboList.length > 0 && (
            <FilterChip big active={kind === "combo"} onClick={() => setKind("combo")}>{_L("register.combos")}</FilterChip>
          )}
          {kinds.map((k) => (
            <FilterChip big key={k} active={kind === k} onClick={() => setKind(k)}>{_L(KIND_LABEL[k] || "register.kind_recipe")}</FilterChip>
          ))}
        </div>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 pb-4">
          {catalog.length === 0 && comboList.length === 0 && <div className="py-12 text-center text-base text-muted-foreground">{_L("register.no_catalog")}</div>}
          {showCombos && (
            <div className="grid grid-cols-3 gap-4">
              {comboList.map((combo) => (
                <button key={combo.comboId} onClick={() => clickCombo(combo)}
                  className="group relative flex flex-col overflow-hidden rounded-2xl border border-border/80 bg-card text-left transition-colors hover:border-primary/60 hover:bg-accent/40 active:bg-accent">
                  <span className="absolute left-3 top-3 z-10 grid h-9 min-w-9 place-items-center rounded-lg bg-primary px-2 font-mono text-lg font-bold text-primary-foreground tabular-nums shadow">
                    {combo.number}
                  </span>
                  <ComboThumb photo={combo.photo} label={combo.label} className="h-36 w-full" />
                  <span className="flex flex-1 flex-col gap-1 p-4">
                    <span className="line-clamp-2 text-xl font-semibold leading-snug">{combo.label}</span>
                    <span className="line-clamp-1 text-base text-muted-foreground">
                      {combo.slots.map((s) => (s.options.length > 1 ? s.label : s.options[0]?.label)).filter(Boolean).join(" + ")}
                    </span>
                    <span className="font-mono text-lg font-bold tabular-nums text-primary">{money(combo.price)}</span>
                  </span>
                </button>
              ))}
            </div>
          )}
          {showItems && (
            <div className="grid grid-cols-3 gap-4">
              {shown.map((c) => {
                const customisable = !!(c.modifiers && c.modifiers.length);
                return (
                  <button key={c.key} onClick={() => clickCard(c)}
                    className="relative flex flex-col items-center gap-3 rounded-2xl border border-border/80 bg-card p-5 text-center transition-colors hover:border-primary/50 hover:bg-accent/60 active:bg-accent">
                    {customisable && (
                      <span className="absolute right-3 top-3 text-primary/70" title={_L("register.customisable")}><SlidersHorizontal className="h-6 w-6" /></span>
                    )}
                    <Thumb src={c.image} className="h-28 w-28" />
                    <span className="line-clamp-2 text-xl font-semibold leading-snug">{c.label}</span>
                    <span className="font-mono text-lg font-bold tabular-nums text-primary">{money(c.price)}</span>
                  </button>
                );
              })}
            </div>
          )}
        </div>

        {/* fixed footer — bag count, total, and the single Checkout button */}
        <div className="mx-5 mb-1 shrink-0 rounded-2xl border border-border bg-card px-6 py-4 shadow-lg">
          <div className="flex items-center gap-5">
            <div className="relative shrink-0">
              <ShoppingBag className="h-11 w-11 text-primary" />
              {count > 0 && (
                <span className="absolute -right-2 -top-2 grid h-7 min-w-7 place-items-center rounded-full bg-primary px-1.5 font-mono text-sm font-bold text-primary-foreground tabular-nums">{count}</span>
              )}
            </div>
            <div className="min-w-0 flex-1">
              <div className="tape text-base text-muted-foreground">{_L("register.total")}</div>
              <div className="font-mono text-4xl font-bold leading-none tabular-nums">{money(total)}</div>
            </div>
            <Button size="lg" className="h-20 shrink-0 gap-2.5 px-12 text-2xl" disabled={count === 0} onClick={() => setReviewing(true)}>
              <ShoppingBag className="h-7 w-7" /> {_L("order.checkout")}
            </Button>
          </div>
        </div>

        {/* review sheet — the full bag, editable, then Place Order */}
        {reviewing && (
          <div className="absolute inset-0 z-30 flex flex-col bg-background">
            <div className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-6 py-5">
              <div className="font-display text-3xl font-semibold">{_L("order.review_title")}</div>
              <button onClick={() => setReviewing(false)} className="grid h-12 w-12 place-items-center rounded-full text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"><X className="h-7 w-7" /></button>
            </div>
            <div className="min-h-0 flex-1 space-y-3 overflow-y-auto px-6 py-4">
              {blocks.length === 0
                ? <div className="py-12 text-center text-lg text-muted-foreground">{_L("register.empty_cart")}</div>
                : blocks.map((b) => cartLine(b, true))}
            </div>
            <div className="shrink-0 space-y-3 border-t border-border bg-card px-6 py-4">
              {/* who pays — register only; a kiosk customer always pays for their own.
                  A click-based row (not a native <select>, which a virtual cursor on the
                  in-world screen can't drive). */}
              {mode === "register" && (
                <div>
                  <div className="tape mb-1.5 flex items-center gap-2 text-muted-foreground"><User className="h-4 w-4" /> {_L("register.customer")}</div>
                  <div className="flex flex-wrap gap-2">
                    <CustomerChip active={customer === 0} onClick={() => setCustomer(0)}>{_L("register.myself")}</CustomerChip>
                    {(nearby || []).map((p) => (
                      <CustomerChip key={p.id} active={customer === p.id} onClick={() => setCustomer(p.id)}>{p.name}</CustomerChip>
                    ))}
                  </div>
                </div>
              )}
              <div className="flex items-center justify-between font-mono text-2xl font-bold">
                <span className="uppercase tracking-widest">{_L("register.total")}</span>
                <span className="tabular-nums">{money(total)}</span>
              </div>
              <div className="flex gap-3">
                <Button variant="outline" size="lg" className="h-16 flex-1 text-xl" onClick={() => setReviewing(false)}>{_L("order.add_more")}</Button>
                <Button size="lg" className="h-16 flex-[2] gap-2.5 text-xl" disabled={blocks.length === 0 || busy} onClick={submit}>
                  {busy
                    ? <><Loader2 className="h-6 w-6 animate-spin" /> {mode === "register" ? _L("register.waiting") : _L("order.placing")}</>
                    : <><Receipt className="h-6 w-6" /> {mode === "register" ? _L("register.charge", money(total)) : _L("order.place", money(total))}</>}
                </Button>
              </div>
            </div>
          </div>
        )}

        {dialogs}
      </div>
    );
  }

  return (
    <div className="relative grid h-full grid-cols-5 gap-4">
      {/* catalog */}
      <div className="col-span-3 flex min-h-0 flex-col">
        <div className="mb-2 flex shrink-0 flex-wrap gap-1.5">
          <FilterChip active={kind === "all"} onClick={() => setKind("all")}>{_L("register.all_items")}</FilterChip>
          {comboList.length > 0 && (
            <FilterChip active={kind === "combo"} onClick={() => setKind("combo")}>{_L("register.combos")}</FilterChip>
          )}
          {kinds.map((k) => (
            <FilterChip key={k} active={kind === k} onClick={() => setKind(k)}>{_L(KIND_LABEL[k] || "register.kind_recipe")}</FilterChip>
          ))}
        </div>
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1 pb-4">
          {catalog.length === 0 && comboList.length === 0 && <div className="py-8 text-center text-sm text-muted-foreground">{_L("register.no_catalog")}</div>}
          {showCombos && (
            <div className="grid grid-cols-2 gap-2">
              {comboList.map((combo) => (
                <button key={combo.comboId} onClick={() => clickCombo(combo)}
                  className="group relative flex overflow-hidden rounded-lg border border-border/80 bg-card text-left transition-colors hover:border-primary/60 hover:bg-accent/40 active:bg-accent">
                  <span className="absolute left-1.5 top-1.5 z-10 grid h-6 min-w-6 place-items-center rounded-md bg-primary px-1 font-mono text-xs font-bold text-primary-foreground tabular-nums shadow">
                    {combo.number}
                  </span>
                  <ComboThumb photo={combo.photo} label={combo.label} className="h-20 w-24 shrink-0" />
                  <span className="flex min-w-0 flex-1 flex-col justify-center gap-0.5 p-2">
                    <span className="line-clamp-2 text-xs font-semibold leading-tight">{combo.label}</span>
                    <span className="truncate text-[10px] text-muted-foreground">
                      {combo.slots.map((s) => (s.options.length > 1 ? s.label : s.options[0]?.label)).filter(Boolean).join(" + ")}
                    </span>
                    <span className="font-mono text-[11px] font-bold tabular-nums text-primary">{money(combo.price)}</span>
                  </span>
                </button>
              ))}
            </div>
          )}
          {showItems && (
            <div className="grid grid-cols-3 gap-2">
              {shown.map((c) => {
                const customisable = !!(c.modifiers && c.modifiers.length);
                return (
                  <button key={c.key} onClick={() => clickCard(c)}
                    className="relative flex flex-col items-center gap-1.5 rounded-lg border border-border/80 bg-card p-2 text-center transition-colors hover:border-primary/50 hover:bg-accent/60 active:bg-accent">
                    {customisable && (
                      <span className="absolute right-1 top-1 text-primary/70" title={_L("register.customisable")}><SlidersHorizontal className="h-3.5 w-3.5" /></span>
                    )}
                    <Thumb src={c.image} className="h-12 w-12" />
                    <span className="line-clamp-2 text-xs font-medium leading-tight">{c.label}</span>
                    <span className="font-mono text-[11px] tabular-nums text-muted-foreground">{money(c.price)}</span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* cart — the order prints onto the register tape as it's built (themed
          receipt surface + a torn bottom edge, matching the tickets) */}
      <div className="col-span-2 flex min-h-0 flex-col drop-shadow-lg">
        <div className="receipt shrink-0 rounded-t-sm px-3 pb-1.5 pt-2.5">
          <div className="flex items-center justify-between">
            <span className="tape">{_L("register.cart")}</span>
            <Receipt className="h-3.5 w-3.5 text-muted-foreground" />
          </div>
          <div className="receipt-rule mt-2" />
        </div>
        <div className="receipt min-h-0 flex-1 space-y-1 overflow-y-auto px-2.5 py-1.5">
          {blocks.length === 0 && (
            <div className="py-6 text-center font-mono text-[11px] uppercase tracking-widest text-muted-foreground">
              {_L("register.empty_cart")}
            </div>
          )}
          {blocks.map((b) => cartLine(b))}
        </div>
        <div className="receipt shrink-0 space-y-2 px-3 pb-3 pt-1.5">
          <div className="receipt-rule" />
          <div className="flex items-center justify-between pt-1 font-mono text-sm font-bold">
            <span className="uppercase tracking-widest">{_L("register.total")}</span>
            <span className="tabular-nums">{money(total)}</span>
          </div>
          {!big && (
            <label className="flex items-center gap-2 text-xs text-muted-foreground">
              <User className="h-3.5 w-3.5" />
              <select value={customer} onChange={(e) => setCustomer(Number(e.target.value))}
                className="h-8 flex-1 rounded-md border border-input bg-muted/50 px-2 text-xs text-foreground focus-visible:border-primary/60 focus-visible:outline-none">
                <option value={0}>{_L("register.myself")}</option>
                {(nearby || []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
          )}
          <Button className="w-full" disabled={blocks.length === 0 || busy} onClick={submit}>
            {busy
              ? <><Loader2 className="h-4 w-4 animate-spin" /> {big ? _L("order.placing") : _L("register.waiting")}</>
              : <><Receipt className="h-4 w-4" /> {big ? _L("order.place", money(total)) : _L("register.charge", money(total))}</>}
          </Button>
        </div>
        <div className="tear-b shrink-0" />
      </div>

      {dialogs}
    </div>
  );
}
