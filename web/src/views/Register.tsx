import { useEffect, useMemo, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  ShoppingCart, Plus, Minus, Trash2, User, Receipt, Check, X, Loader2, ImageOff, ClipboardList, SlidersHorizontal, Ban, UtensilsCrossed,
} from "lucide-react";

type Mod = { id: string; label: string; item?: string; price?: number; default?: boolean; image?: string; group?: string; color?: string };
type Cat = { key: string; item: string; variant: string; label: string; kind: string; price: number; image?: string; modifiers?: Mod[] };
type LineMod = { id?: string; label: string; price?: number; added?: boolean; removed?: boolean; image?: string; color?: string };
type Line = { item: string; variant: string; label: string; price: number; qty: number; kind: string; image?: string; mods?: LineMod[] };
// A selected option to render as an image chip (added extra, or a removed default).
type OptView = { label: string; image?: string; color?: string };
// One layer of a meal, spelled out for the in-depth picker: the item's label +
// image, plus its toppings (cheese/lettuce as item images, frosting/sprinkles as
// coloured swatches).
type MealItem = { item: string; label: string; image?: string; mods?: OptView[] };
// A meal in the shared pool that (with single items) would complete the whole
// order — offered as a fulfillment option. `items` is its full contents.
type MealOption = { sig: string; label: string; items?: MealItem[] };
// Per-ticket fulfillment state from the shared cooked-items pool (server-computed).
// `ok` = completable with single items alone; `mealOptions` = meals that complete it;
// `missing` = the single-item shortfall shown when nothing can complete it.
type Fulfill = { ok: boolean; mealOptions?: MealOption[]; missing?: string[] };
type Ticket = { orderId: number; ticket: number; customer: string; lines: Line[]; total: number; fulfill?: Fulfill };
type Near = { id: number; name: string };
// A cart entry: which catalog item, how many, and the selected modifier ids.
type CartEntry = { catKey: string; qty: number; sel: string[] };

// Inventory thumbnail from a direct nui:// url the server resolved, with a
// graceful fallback (different inventories store images differently).
function Thumb({ src, className }: { src?: string; className?: string }) {
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

const KIND_LABEL: Record<string, string> = {
  recipe: "register.kind_recipe",
  assembly: "register.kind_assembly",
  drink: "register.kind_drink",
  finish: "register.kind_finish",
};

// The additions (+X) / removals (no Y) a selection implies, plus the price the
// selected add-ons add on top of the base — computed identically on the server.
function resolveMods(cat: Cat, sel: string[]) {
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
function OptChip({ o, removed }: { o: OptView; removed?: boolean }) {
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
function OptRow({ added, removed }: { added: OptView[]; removed: OptView[] }) {
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

// Coerce a server list to a real array. Lua/JSON encodes an EMPTY list as `{}`
// (an object, not `[]`), so a plain `x || []` would keep that `{}` and any
// `.map`/`.filter` on it would throw and take the whole panel down.
const arr = <T,>(x: unknown): T[] => (Array.isArray(x) ? (x as T[]) : []);

export default function Register({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  // Catalog + nearby come from the initial open payload (they don't churn while
  // the panel is up).
  const catalog: Cat[] = arr<Cat>(data?.catalog);
  const nearby: Near[] = arr<Near>(data?.nearby);

  // The ticket list is LIVE: seeded from the open payload, then kept in sync by
  // the server's `orders` broadcast (fired on any create/cancel/complete, from
  // any cashier). This is the only thing that mutates while the panel is open, so
  // updating just this state — never the whole panel — is flicker-free and can't
  // race a full re-render. Re-seed if the panel is reopened with fresh `data`.
  const [tickets, setTickets] = useState<Ticket[]>(() => arr<Ticket>(data?.tickets));
  useEffect(() => { setTickets(arr<Ticket>(data?.tickets)); }, [data]);
  useNuiEvent("orders", (d) => setTickets(arr<Ticket>(d?.orders)));

  return (
    <Panel
      title={_L("register.title")}
      subtitle={_L("register.subtitle_pos", data?.label || "", money(data?.balance), data?.commission ?? 0)}
      onClose={onClose}
      width="max-w-4xl"
    >
      <Tabs defaultValue="new" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          <TabsTrigger value="new"><ShoppingCart className="h-4 w-4" /> {_L("register.new_order")}</TabsTrigger>
          <TabsTrigger value="tickets"><ClipboardList className="h-4 w-4" /> {_L("register.tickets", tickets.length)}</TabsTrigger>
        </TabsList>

        <TabsContent value="new" className="min-h-0 flex-1">
          <NewOrder id={id} catalog={catalog} nearby={nearby} />
        </TabsContent>

        {/* not overflow-scrolled here — Tickets owns its own scroll so the meal
            picker can overlay (and dim) just the ticket area, not the whole panel */}
        <TabsContent value="tickets" className="min-h-0 flex-1">
          <Tickets id={id} tickets={tickets} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}

function NewOrder({ id, catalog, nearby }: { id: number; catalog: Cat[]; nearby: Near[] }) {
  const [cart, setCart] = useState<Record<string, CartEntry>>({});
  const [customer, setCustomer] = useState(0); // 0 = Myself
  const [kind, setKind] = useState<string>("all");
  const [busy, setBusy] = useState(false);
  const [modFor, setModFor] = useState<Cat | null>(null); // item being customised
  const [modSel, setModSel] = useState<string[]>([]);

  const kinds = useMemo(() => Array.from(new Set(catalog.map((c) => c.kind))), [catalog]);
  const shown = kind === "all" ? catalog : catalog.filter((c) => c.kind === kind);
  const byKey = useMemo(() => Object.fromEntries(catalog.map((c) => [c.key, c])), [catalog]);

  const cartKeyFor = (catKey: string, sel: string[]) => catKey + "#" + [...sel].sort().join(",");
  const addEntry = (catKey: string, sel: string[]) => setCart((c) => {
    const ck = cartKeyFor(catKey, sel);
    const prev = c[ck];
    return { ...c, [ck]: { catKey, sel, qty: Math.min(10, (prev?.qty || 0) + 1) } };
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
      addEntry(c.key, []);
    }
  };
  // Ungrouped modifiers toggle freely; a grouped modifier is single-choice —
  // picking one clears the rest of its group, clicking the picked one = none.
  const toggleMod = (m: Mod) =>
    setModSel((s) => {
      if (!m.group) return s.includes(m.id) ? s.filter((x) => x !== m.id) : [...s, m.id];
      const groupIds = new Set((modFor?.modifiers || []).filter((x) => x.group === m.group).map((x) => x.id));
      const without = s.filter((x) => !groupIds.has(x));
      return s.includes(m.id) ? without : [...without, m.id];
    });

  const lines = Object.entries(cart).map(([ck, e]) => {
    const cat = byKey[e.catKey];
    if (!cat) return null;
    const { added, removed, extra } = resolveMods(cat, e.sel);
    return { ck, cat, qty: e.qty, price: cat.price + extra, added, removed };
  }).filter(Boolean) as { ck: string; cat: Cat; qty: number; price: number; added: Mod[]; removed: Mod[] }[];
  const total = lines.reduce((s, l) => s + l.price * l.qty, 0);

  const charge = async () => {
    if (lines.length === 0 || busy) return;
    setBusy(true);
    const cartArr = Object.values(cart).map((e) => ({ key: e.catKey, qty: e.qty, mods: e.sel }));
    const res: any = await fetchNui("sales:createOrder", { id, customer, cart: cartArr });
    setBusy(false);
    if (res && res.ok) setCart({}); // the new ticket arrives via the `orders` broadcast
  };

  const modExtra = modFor ? resolveMods(modFor, modSel).extra : 0;

  return (
    <div className="relative grid h-full grid-cols-5 gap-4">
      {/* catalog */}
      <div className="col-span-3 flex min-h-0 flex-col">
        <div className="mb-2 flex shrink-0 flex-wrap gap-1.5">
          <FilterChip active={kind === "all"} onClick={() => setKind("all")}>{_L("register.all_items")}</FilterChip>
          {kinds.map((k) => (
            <FilterChip key={k} active={kind === k} onClick={() => setKind(k)}>{_L(KIND_LABEL[k] || "register.kind_recipe")}</FilterChip>
          ))}
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto pr-1">
          {catalog.length === 0 && <div className="py-8 text-center text-sm text-muted-foreground">{_L("register.no_catalog")}</div>}
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
          {lines.length === 0 && (
            <div className="py-6 text-center font-mono text-[11px] uppercase tracking-widest text-muted-foreground">
              {_L("register.empty_cart")}
            </div>
          )}
          {lines.map((l) => (
            <div key={l.ck} className="flex items-center gap-2 rounded-sm bg-muted/50 p-1.5">
              <Thumb src={l.cat.image} className="h-8 w-8 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-xs font-medium">{l.cat.label}</div>
                <OptRow added={l.added} removed={l.removed} />
                <div className="font-mono text-[11px] tabular-nums text-muted-foreground">{money(l.price)}</div>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                <button onClick={() => changeQty(l.ck, -1)} className="grid h-6 w-6 place-items-center rounded border border-border transition-colors hover:bg-accent"><Minus className="h-3 w-3" /></button>
                <span className="w-5 text-center font-mono text-xs tabular-nums">{l.qty}</span>
                <button onClick={() => changeQty(l.ck, 1)} className="grid h-6 w-6 place-items-center rounded border border-border transition-colors hover:bg-accent"><Plus className="h-3 w-3" /></button>
                <button onClick={() => removeEntry(l.ck)} className="grid h-6 w-6 place-items-center rounded text-muted-foreground transition-colors hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
              </div>
            </div>
          ))}
        </div>
        <div className="receipt shrink-0 space-y-2 px-3 pb-3 pt-1.5">
          <div className="receipt-rule" />
          <div className="flex items-center justify-between pt-1 font-mono text-sm font-bold">
            <span className="uppercase tracking-widest">{_L("register.total")}</span>
            <span className="tabular-nums">{money(total)}</span>
          </div>
          <label className="flex items-center gap-2 text-xs text-muted-foreground">
            <User className="h-3.5 w-3.5" />
            <select value={customer} onChange={(e) => setCustomer(Number(e.target.value))}
              className="h-8 flex-1 rounded-md border border-input bg-muted/50 px-2 text-xs text-foreground focus-visible:border-primary/60 focus-visible:outline-none">
              <option value={0}>{_L("register.myself")}</option>
              {nearby.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          <Button className="w-full" disabled={lines.length === 0 || busy} onClick={charge}>
            {busy
              ? <><Loader2 className="h-4 w-4 animate-spin" /> {_L("register.waiting")}</>
              : <><Receipt className="h-4 w-4" /> {_L("register.charge", money(total))}</>}
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
              <Button size="sm" onClick={() => { addEntry(modFor.key, modSel); setModFor(null); }}>
                <Plus className="h-4 w-4" /> {_L("register.add_to_order")}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
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

function Tickets({ id, tickets }: { id: number; tickets: Ticket[] }) {
  // The meal picker is owned here (not per-card) so it overlays the ticket LIST
  // area only — dimming the content, not the panel header — and centres in it.
  const [picker, setPicker] = useState<{ orderId: number; meals: MealOption[] } | null>(null);
  const [busy, setBusy] = useState(false);
  // Drop the picker if its ticket left the list (completed/cancelled elsewhere).
  useEffect(() => {
    if (picker && !tickets.some((t) => t.orderId === picker.orderId)) setPicker(null);
  }, [tickets]); // eslint-disable-line react-hooks/exhaustive-deps

  const fulfillMeal = async (sig: string) => {
    if (!picker) return;
    setBusy(true);
    await fetchNui("sales:completeOrder", { id, orderId: picker.orderId, mealSig: sig });
    setBusy(false);
    setPicker(null); // (also clears via the `orders` broadcast on success)
  };

  if (tickets.length === 0) return <div className="py-8 text-center text-sm text-muted-foreground">{_L("register.no_tickets")}</div>;
  return (
    <div className="relative h-full">
      <div className="h-full space-y-2 overflow-y-auto pr-1">
        {tickets.map((t) => (
          <TicketCard key={t.orderId} id={id} t={t}
            onOpenPicker={(meals) => setPicker({ orderId: t.orderId, meals })} />
        ))}
      </div>
      {picker && (
        <MealPicker meals={picker.meals} busy={busy} onFulfill={fulfillMeal} onClose={() => setPicker(null)} />
      )}
    </div>
  );
}

function TicketCard({ id, t, onOpenPicker }: { id: number; t: Ticket; onOpenPicker: (meals: MealOption[]) => void }) {
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [busy, setBusy] = useState(false);

  const f = t.fulfill;
  const mealOptions = arr<MealOption>(f?.mealOptions);
  const missing = arr<string>(f?.missing);

  // Fire the action; the ticket drops out of the list when the server's `orders`
  // broadcast lands (near-instant). On failure the server notifies and the list
  // is unchanged, so we just un-busy.
  const act = async (event: string, extra?: Record<string, unknown>) => {
    setBusy(true);
    await fetchNui(event, { id, orderId: t.orderId, ...extra });
    setBusy(false);
  };

  return (
    <div className="drop-shadow-md">
      <div className="receipt rounded-t-sm px-3.5 pb-3 pt-3">
        <div className="mb-2 flex items-center justify-between gap-2">
          <div className="flex min-w-0 items-center gap-2">
            <span className="shrink-0 rounded-sm bg-muted px-1.5 py-0.5 font-mono text-[10px] font-bold uppercase tracking-wider tabular-nums">
              {_L("register.ticket_num", t.ticket)}
            </span>
            <span className="truncate text-sm font-medium">{t.customer}</span>
          </div>
          <span className="shrink-0 font-mono text-sm font-bold tabular-nums">{money(t.total)}</span>
        </div>
        <div className="receipt-rule mb-2" />
        <div className="mb-3 space-y-1">
          {t.lines.map((l, i) => {
            const mods = Array.isArray(l.mods) ? l.mods : [];
            const added = mods.filter((m) => !m.removed);
            const removed = mods.filter((m) => m.removed);
            return (
              <div key={i} className="flex items-center gap-2 rounded-sm bg-muted/50 p-1.5">
                <Thumb src={l.image} className="h-9 w-9 shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs font-medium">{l.label}</div>
                  <OptRow added={added} removed={removed} />
                </div>
                <span className="shrink-0 font-mono text-xs font-semibold tabular-nums text-muted-foreground">×{l.qty}</span>
              </div>
            );
          })}
        </div>
        {/* nothing in the pool can complete this order yet (no singles, no meal) */}
        {!f?.ok && mealOptions.length === 0 && missing.length > 0 && (
          <div className="mb-2.5 rounded-sm bg-destructive/10 px-2 py-1.5 text-[11px] font-medium text-destructive">
            {_L("register.missing", missing.join(", "))}
          </div>
        )}
        <div className="flex justify-end gap-2">
          {confirmCancel ? (
            <>
              <span className="mr-auto self-center text-xs text-muted-foreground">{_L("register.confirm_cancel")}</span>
              <button disabled={busy} onClick={() => setConfirmCancel(false)}
                className="rounded-md px-3 py-1.5 text-xs font-semibold text-muted-foreground transition-colors hover:text-foreground disabled:opacity-50">
                {_L("register.keep")}
              </button>
              <button disabled={busy} onClick={() => act("sales:cancelOrder")}
                className="inline-flex items-center gap-1.5 rounded-md bg-destructive px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition-colors hover:bg-[rgb(var(--danger-hover))] disabled:opacity-50">
                <X className="h-3.5 w-3.5" /> {_L("register.cancel_refund")}
              </button>
            </>
          ) : (
            <>
              <button disabled={busy} onClick={() => setConfirmCancel(true)}
                className="inline-flex items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-xs font-semibold text-foreground transition-colors hover:border-destructive hover:text-destructive disabled:opacity-50">
                <Trash2 className="h-3.5 w-3.5" /> {_L("register.cancel")}
              </button>
              {/* a meal (with any single items) can complete this order — open the
                  in-depth picker to review the contents and hand one over */}
              {mealOptions.length > 0 && (
                <button disabled={busy} onClick={() => onOpenPicker(mealOptions)}
                  className="inline-flex items-center gap-1.5 rounded-md border border-primary/50 bg-primary/10 px-3 py-1.5 text-xs font-semibold text-primary shadow-sm transition-colors hover:bg-primary/20 disabled:opacity-50">
                  <UtensilsCrossed className="h-3.5 w-3.5" /> {_L("register.fulfill_with_meal", mealOptions.length)}
                </button>
              )}
              {f?.ok ? (
                <button disabled={busy} onClick={() => act("sales:completeOrder")}
                  className="inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-foreground shadow-sm transition-colors hover:bg-[rgb(var(--brand-hover))] disabled:opacity-50">
                  {busy ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Check className="h-3.5 w-3.5" />} {_L("register.complete")}
                </button>
              ) : mealOptions.length === 0 ? (
                <button disabled title={missing.length ? _L("register.missing", missing.join(", ")) : undefined}
                  className="inline-flex cursor-not-allowed items-center gap-1.5 rounded-md border border-border px-3 py-1.5 text-xs font-semibold text-muted-foreground opacity-70">
                  <Ban className="h-3.5 w-3.5" /> {_L("register.not_complete")}
                </button>
              ) : null}
            </>
          )}
        </div>
      </div>
      <div className="tear-b" />
    </div>
  );
}

// The in-depth meal fulfillment picker: a modal listing every pool meal that (with
// single items) completes this order, each shown with its FULL contents — item
// images + toppings (item images / colour swatches) + names — so the cashier reviews
// exactly what they're handing over before fulfilling with it. Rendered as an
// ABSOLUTE overlay so it dims + centres over the ticket LIST only (never the panel
// header), and fades its backdrop + card in on mount and out on close.
function MealPicker({ meals, busy, onFulfill, onClose }: {
  meals: MealOption[]; busy: boolean; onFulfill: (sig: string) => void; onClose: () => void;
}) {
  const [visible, setVisible] = useState(false);
  // fade in on mount (next frame so the transition has a 0→1 to animate)
  useEffect(() => { const r = requestAnimationFrame(() => setVisible(true)); return () => cancelAnimationFrame(r); }, []);
  // fade out, then unmount via the parent's onClose
  const close = () => { setVisible(false); window.setTimeout(onClose, 180); };
  const fulfill = (sig: string) => { setVisible(false); window.setTimeout(() => onFulfill(sig), 160); };
  return (
    <div
      className={cn("absolute inset-0 z-30 flex items-center justify-center p-4 transition-opacity duration-200",
        visible ? "opacity-100" : "opacity-0")}
      onClick={close}
    >
      <div className="absolute inset-0 bg-black/50" />
      <div
        className={cn("relative flex max-h-full w-full max-w-md flex-col rounded-lg border border-border bg-card shadow-2xl transition-transform duration-200",
          visible ? "scale-100" : "scale-95")}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-2 border-b border-border px-4 py-3">
          <UtensilsCrossed className="h-4 w-4 text-primary" />
          <span className="font-semibold">{_L("register.meal_picker_title")}</span>
          <span className="rounded-full bg-muted px-1.5 py-0.5 font-mono text-[10px] font-bold tabular-nums text-muted-foreground">{meals.length}</span>
          <button onClick={close} className="ml-auto text-muted-foreground transition-colors hover:text-foreground"><X className="h-4 w-4" /></button>
        </div>
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto p-3">
          {meals.map((m, mi) => {
            const items = arr<MealItem>(m.items);
            return (
              <div key={m.sig} className="rounded-lg border border-border bg-muted/30 p-3">
                <div className="tape mb-2 text-muted-foreground">{_L("register.meal_n", mi + 1)}</div>
                <div className="space-y-2">
                  {items.map((it, i) => (
                    <div key={i} className="flex items-start gap-2.5 rounded-sm bg-card/60 p-1.5">
                      <Thumb src={it.image} className="h-11 w-11 shrink-0" />
                      <div className="min-w-0 flex-1">
                        <div className="text-sm font-medium">{it.label}</div>
                        {arr<OptView>(it.mods).length > 0 && (
                          <div className="mt-1 space-y-0.5">
                            {arr<OptView>(it.mods).map((o, j) => (
                              <div key={j} className="flex items-center gap-1.5">
                                {o.image
                                  ? <Thumb src={o.image} className="h-4 w-4" />
                                  : <span className="h-3 w-3 shrink-0 rounded-full border border-border" style={{ backgroundColor: o.color || "transparent" }} />}
                                <span className="truncate text-[11px] text-muted-foreground">{o.label}</span>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
                <Button className="mt-3 w-full" size="sm" disabled={busy} onClick={() => fulfill(m.sig)}>
                  {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} {_L("register.fulfill_this_meal")}
                </Button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
