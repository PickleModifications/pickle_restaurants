import { useEffect, useMemo, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  Plus, Minus, Trash2, User, Receipt, Check, X, Loader2, ImageOff, SlidersHorizontal, Ban, UtensilsCrossed,
} from "lucide-react";

// Shared point-of-sale building blocks used by BOTH the staff register
// (views/Register.tsx) and the customer self-service kiosk (views/Order.tsx), so
// the catalog grid, modifier picker, cart and pricing can never drift between the
// two. The only differences the kiosk makes are: no "who pays" customer picker
// (the customer always pays for their own order) and a different submit event.

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
function ModTile({ m, on, onClick }: { m: Mod; on: boolean; onClick: () => void }) {
  return (
    <button onClick={onClick}
      className={cn("relative flex flex-col items-center gap-1 rounded-lg border p-2 text-center transition-colors",
        on ? "border-primary bg-primary/10 ring-1 ring-primary" : "border-border hover:border-primary/50 hover:bg-accent/50")}>
      {on && (
        <span className="absolute right-1 top-1 grid h-4 w-4 place-items-center rounded-full bg-primary text-primary-foreground">
          <Check className="h-3 w-3" />
        </span>
      )}
      {m.image
        ? <Thumb src={m.image} className="h-12 w-12" />
        : m.color
          ? <span className="h-12 w-12 rounded-full border border-border" style={{ backgroundColor: m.color }} />
          : <div className="grid h-12 w-12 place-items-center rounded bg-muted/60 text-muted-foreground"><ImageOff className="h-1/2 w-1/2" /></div>}
      <span className="line-clamp-2 text-xs font-medium leading-tight">
        {m.label}
        {m.default && <span className="ml-1 text-[9px] text-muted-foreground">{_L("register.mod_default")}</span>}
      </span>
      {!!m.price && !m.default && <span className="text-[11px] text-muted-foreground">+{money(m.price)}</span>}
    </button>
  );
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button onClick={onClick}
      className={cn("rounded-full border px-2.5 py-1 font-mono text-[10px] font-semibold uppercase tracking-wider transition-colors",
        active ? "border-primary/40 bg-primary/15 text-primary" : "border-border text-muted-foreground hover:bg-accent hover:text-foreground")}>
      {children}
    </button>
  );
}

// The catalog + modifier picker + cart. In "register" mode the cashier can charge
// a nearby player (the customer picker); in "kiosk" mode the customer always pays
// for their own order (no picker) and the submit reads "Place Order". `onOrdered`
// fires with the new ticket number after a successful submit.
export function OrderBuilder({
  id, catalog, combos, nearby, mode, onOrdered,
}: {
  id: number;
  catalog: Cat[];
  combos?: Combo[];
  nearby?: Near[];
  mode: "register" | "kiosk";
  onOrdered?: (ticket?: number) => void;
}) {
  const [cart, setCart] = useState<Record<string, CartEntry>>({});
  const [customer, setCustomer] = useState(0); // 0 = Myself
  const [kind, setKind] = useState<string>("all");
  const [busy, setBusy] = useState(false);
  const [modFor, setModFor] = useState<Cat | null>(null); // item being customised
  const [modSel, setModSel] = useState<string[]>([]);
  const [comboFor, setComboFor] = useState<Combo | null>(null); // combo being built
  const [comboPicks, setComboPicks] = useState<{ key: string; sel: string[] }[]>([]);

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

  const addItemEntry = (catKey: string, sel: string[]) => setCart((c) => {
    const ck = itemCartKey(catKey, sel);
    const prev = c[ck];
    return { ...c, [ck]: { type: "item", catKey, sel, qty: Math.min(10, (prev?.qty || 0) + 1) } };
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

  // Click a card: customise it if it has modifiers, else drop it straight in.
  const clickCard = (c: Cat) => {
    if (c.modifiers && c.modifiers.length) {
      setModFor(c);
      setModSel((c.modifiers || []).filter((m) => m.default).map((m) => m.id));
    } else {
      addItemEntry(c.key, []);
    }
  };
  // Click a combo: open the builder seeded with each slot's first option + that
  // option's default modifiers.
  const clickCombo = (combo: Combo) => {
    setComboFor(combo);
    setComboPicks(combo.slots.map((slot) => {
      const opt = slot.options[0];
      return { key: opt?.key || "", sel: (opt?.modifiers || []).filter((m) => m.default).map((m) => m.id) };
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
    ps.map((p, i) => (i === si ? { key: opt.key, sel: (opt.modifiers || []).filter((m) => m.default).map((m) => m.id) } : p)));
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

  const submit = async () => {
    if (blocks.length === 0 || busy) return;
    setBusy(true);
    const cartArr = Object.values(cart).map((e) =>
      e.type === "combo"
        ? { combo: e.comboId, qty: e.qty, slots: e.picks.map((p) => ({ key: p.key, mods: p.sel })) }
        : { key: e.catKey, qty: e.qty, mods: e.sel });
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
  const isKiosk = mode === "kiosk";

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
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
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
          {blocks.map((b) => {
            const qtyCtrl = (
              <div className="flex shrink-0 items-center gap-1">
                <button onClick={() => changeQty(b.ck, -1)} className="grid h-6 w-6 place-items-center rounded border border-border transition-colors hover:bg-accent"><Minus className="h-3 w-3" /></button>
                <span className="w-5 text-center font-mono text-xs tabular-nums">{b.qty}</span>
                <button onClick={() => changeQty(b.ck, 1)} className="grid h-6 w-6 place-items-center rounded border border-border transition-colors hover:bg-accent"><Plus className="h-3 w-3" /></button>
                <button onClick={() => removeEntry(b.ck)} className="grid h-6 w-6 place-items-center rounded text-muted-foreground transition-colors hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
              </div>
            );
            if (b.type === "item") {
              return (
                <div key={b.ck} className="flex items-center gap-2 rounded-sm bg-muted/50 p-1.5">
                  <Thumb src={b.cat.image} className="h-8 w-8 shrink-0" />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-xs font-medium">{b.cat.label}</div>
                    <OptRow added={b.added} removed={b.removed} />
                    <div className="font-mono text-[11px] tabular-nums text-muted-foreground">{money(b.price)}</div>
                  </div>
                  {qtyCtrl}
                </div>
              );
            }
            return (
              <div key={b.ck} className="rounded-sm bg-muted/50 p-1.5">
                <div className="flex items-center gap-2">
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded bg-primary/15 font-mono text-xs font-bold text-primary tabular-nums">#{b.combo.number}</span>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-xs font-semibold">{b.combo.label}</div>
                    <div className="font-mono text-[11px] tabular-nums text-muted-foreground">{money(b.price)}</div>
                  </div>
                  {qtyCtrl}
                </div>
                <div className="mt-1 space-y-0.5 border-l border-border/60 pl-2">
                  {b.comps.map((comp, i) => (
                    <div key={i} className="flex items-center gap-1.5">
                      <Thumb src={comp.opt.image} className="h-5 w-5 shrink-0" />
                      <span className="truncate text-[11px]">{comp.opt.label}</span>
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
          })}
        </div>
        <div className="receipt shrink-0 space-y-2 px-3 pb-3 pt-1.5">
          <div className="receipt-rule" />
          <div className="flex items-center justify-between pt-1 font-mono text-sm font-bold">
            <span className="uppercase tracking-widest">{_L("register.total")}</span>
            <span className="tabular-nums">{money(total)}</span>
          </div>
          {!isKiosk && (
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
              ? <><Loader2 className="h-4 w-4 animate-spin" /> {isKiosk ? _L("order.placing") : _L("register.waiting")}</>
              : <><Receipt className="h-4 w-4" /> {isKiosk ? _L("order.place", money(total)) : _L("register.charge", money(total))}</>}
          </Button>
        </div>
        <div className="tear-b shrink-0" />
      </div>

      {/* modifier dialog */}
      {modFor && (
        <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/50 p-4" onClick={() => setModFor(null)}>
          <div className="w-full max-w-sm rounded-lg border border-border bg-card p-4 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <div className="mb-3 flex items-center gap-2">
              <Thumb src={modFor.image} className="h-10 w-10 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="truncate font-semibold">{modFor.label}</div>
                <div className="text-xs text-muted-foreground">{money(modFor.price)}</div>
              </div>
              <button onClick={() => setModFor(null)} className="text-muted-foreground hover:text-foreground"><X className="h-4 w-4" /></button>
            </div>
            <div className="max-h-72 space-y-3 overflow-y-auto p-0.5">
              {(() => {
                const all = modFor.modifiers || [];
                const ungrouped = all.filter((m) => !m.group);
                const groupNames = Array.from(new Set(all.filter((m) => m.group).map((m) => m.group as string)));
                return (
                  <>
                    {ungrouped.length > 0 && (
                      <div className="grid grid-cols-3 gap-2">
                        {ungrouped.map((m) => <ModTile key={m.id} m={m} on={modSel.includes(m.id)} onClick={() => toggleMod(m)} />)}
                      </div>
                    )}
                    {groupNames.map((g) => (
                      <div key={g}>
                        <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">{g}</div>
                        <div className="grid grid-cols-3 gap-2">
                          {all.filter((m) => m.group === g).map((m) => <ModTile key={m.id} m={m} on={modSel.includes(m.id)} onClick={() => toggleMod(m)} />)}
                        </div>
                      </div>
                    ))}
                  </>
                );
              })()}
            </div>
            <div className="mt-3 flex items-center justify-between">
              <span className="text-sm font-semibold">{money(modFor.price + modExtra)}</span>
              <Button size="sm" onClick={() => { addItemEntry(modFor.key, modSel); setModFor(null); }}>
                <Plus className="h-4 w-4" /> {_L("register.add_to_order")}
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* combo builder dialog — pick each slot's option + its toppings */}
      {comboFor && (
        <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/50 p-4" onClick={() => setComboFor(null)}>
          <div className="flex max-h-full w-full max-w-md flex-col rounded-lg border border-border bg-card shadow-xl" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-2 border-b border-border p-3">
              <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-primary font-mono text-sm font-bold text-primary-foreground tabular-nums">{comboFor.number}</span>
              <div className="min-w-0 flex-1">
                <div className="truncate font-semibold">{comboFor.label}</div>
                <div className="text-xs text-muted-foreground">{_L("combo.customize_title")}</div>
              </div>
              <button onClick={() => setComboFor(null)} className="text-muted-foreground hover:text-foreground"><X className="h-4 w-4" /></button>
            </div>
            <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-3">
              {comboFor.slots.map((slot, si) => {
                const pick = comboPicks[si];
                const opt = slot.options.find((o) => o.key === pick?.key) || slot.options[0];
                const isChoice = slot.options.length > 1;
                const mods = opt?.modifiers || [];
                return (
                  <div key={si} className="rounded-lg border border-border/70 p-2.5">
                    <div className="mb-1.5 flex items-center gap-2">
                      <span className="tape text-muted-foreground">{slot.label || opt?.label}</span>
                      {isChoice && <Badge variant="secondary">{_L("combo.choose_one")}</Badge>}
                    </div>
                    {isChoice && (
                      <div className="mb-2 grid grid-cols-2 gap-1.5">
                        {slot.options.map((o) => (
                          <button key={o.key} onClick={() => pickComboOption(si, o)}
                            className={cn("flex items-center gap-1.5 rounded-md border p-1.5 text-left transition-colors",
                              o.key === opt?.key ? "border-primary bg-primary/10 ring-1 ring-primary" : "border-border hover:border-primary/50 hover:bg-accent/50")}>
                            <Thumb src={o.image} className="h-7 w-7 shrink-0" />
                            <span className="truncate text-xs font-medium">{o.label}</span>
                          </button>
                        ))}
                      </div>
                    )}
                    {!isChoice && (
                      <div className="mb-2 flex items-center gap-2">
                        <Thumb src={opt?.image} className="h-8 w-8 shrink-0" />
                        <span className="truncate text-sm font-medium">{opt?.label}</span>
                      </div>
                    )}
                    {mods.length > 0 && (
                      <div className="grid grid-cols-3 gap-2">
                        {mods.map((m) => (
                          <ModTile key={m.id} m={m} on={(pick?.sel || []).includes(m.id)} onClick={() => toggleComboMod(si, opt, m)} />
                        ))}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
            <div className="flex items-center justify-between border-t border-border p-3">
              <span className="text-sm font-semibold">{money(comboFor.price + comboExtra)}</span>
              <Button size="sm" onClick={() => { addComboEntry(comboFor.comboId, comboPicks); setComboFor(null); }}>
                <Plus className="h-4 w-4" /> {_L("combo.add_combo", money(comboFor.price + comboExtra))}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
