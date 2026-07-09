import { useEffect, useMemo, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  ShoppingCart, Plus, Minus, Trash2, User, Receipt, Check, X, Loader2, ImageOff, ClipboardList, SlidersHorizontal, Ban,
} from "lucide-react";

type Mod = { id: string; label: string; item?: string; price?: number; default?: boolean; image?: string; group?: string; color?: string };
type Cat = { key: string; item: string; variant: string; label: string; kind: string; price: number; image?: string; modifiers?: Mod[] };
type LineMod = { id?: string; label: string; price?: number; added?: boolean; removed?: boolean; image?: string; color?: string };
type Line = { item: string; variant: string; label: string; price: number; qty: number; kind: string; image?: string; mods?: LineMod[] };
// A selected option to render as an image chip (added extra, or a removed default).
type OptView = { label: string; image?: string; color?: string };
type Ticket = { orderId: number; ticket: number; customer: string; lines: Line[]; total: number };
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
  return <img src={src} onError={() => setBroken(true)} className={cn("rounded bg-muted/40 object-contain", className)} />;
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
// crossed out so "no lettuce" reads at a glance without any text.
function OptChip({ o, removed }: { o: OptView; removed?: boolean }) {
  return (
    <span
      title={(removed ? _L("register.opt_no") + " " : "") + o.label}
      className={cn(
        "relative flex h-6 w-6 shrink-0 items-center justify-center rounded border bg-background/60",
        removed ? "border-destructive/50" : "border-border/60",
      )}
    >
      {o.image
        ? <Thumb src={o.image} className={cn("h-5 w-5", removed && "opacity-40")} />
        : o.color
          ? <span className={cn("h-4 w-4 rounded-full border border-border", removed && "opacity-40")} style={{ backgroundColor: o.color }} />
          : <div className={cn("grid h-5 w-5 place-items-center rounded bg-muted/60 text-muted-foreground", removed && "opacity-40")}><ImageOff className="h-3 w-3" /></div>}
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

        <TabsContent value="tickets" className="min-h-0 flex-1 overflow-y-auto pr-1">
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
                  className="relative flex flex-col items-center gap-1.5 rounded-lg border border-border p-2 text-center transition-colors hover:border-primary/50 hover:bg-accent/50">
                  {customisable && (
                    <span className="absolute right-1 top-1 text-primary/70" title={_L("register.customisable")}><SlidersHorizontal className="h-3.5 w-3.5" /></span>
                  )}
                  <Thumb src={c.image} className="h-12 w-12" />
                  <span className="line-clamp-2 text-xs font-medium leading-tight">{c.label}</span>
                  <span className="text-xs text-muted-foreground">{money(c.price)}</span>
                </button>
              );
            })}
          </div>
        </div>
      </div>

      {/* cart */}
      <div className="col-span-2 flex min-h-0 flex-col rounded-lg border border-border">
        <div className="shrink-0 border-b border-border px-3 py-2 text-sm font-semibold">{_L("register.cart")}</div>
        <div className="min-h-0 flex-1 space-y-1.5 overflow-y-auto p-2">
          {lines.length === 0 && <div className="py-6 text-center text-xs text-muted-foreground">{_L("register.empty_cart")}</div>}
          {lines.map((l) => (
            <div key={l.ck} className="flex items-center gap-2 rounded-md bg-muted/40 p-1.5">
              <Thumb src={l.cat.image} className="h-8 w-8 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-xs font-medium">{l.cat.label}</div>
                <OptRow added={l.added} removed={l.removed} />
                <div className="text-[11px] text-muted-foreground">{money(l.price)}</div>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                <button onClick={() => changeQty(l.ck, -1)} className="grid h-6 w-6 place-items-center rounded border border-border hover:bg-accent"><Minus className="h-3 w-3" /></button>
                <span className="w-5 text-center text-xs tabular-nums">{l.qty}</span>
                <button onClick={() => changeQty(l.ck, 1)} className="grid h-6 w-6 place-items-center rounded border border-border hover:bg-accent"><Plus className="h-3 w-3" /></button>
                <button onClick={() => removeEntry(l.ck)} className="grid h-6 w-6 place-items-center rounded text-muted-foreground hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
              </div>
            </div>
          ))}
        </div>
        <div className="shrink-0 space-y-2 border-t border-border p-3">
          <div className="flex items-center justify-between text-sm font-semibold">
            <span>{_L("register.total")}</span>
            <span>{money(total)}</span>
          </div>
          <label className="flex items-center gap-2 text-xs text-muted-foreground">
            <User className="h-3.5 w-3.5" />
            <select value={customer} onChange={(e) => setCustomer(Number(e.target.value))}
              className="h-8 flex-1 rounded-md border border-input bg-background px-2 text-xs text-foreground">
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
      className={cn("rounded-full border px-2.5 py-0.5 text-xs transition-colors",
        active ? "border-primary/30 bg-primary/15 text-primary" : "border-border text-muted-foreground hover:bg-accent")}>
      {children}
    </button>
  );
}

function Tickets({ id, tickets }: { id: number; tickets: Ticket[] }) {
  if (tickets.length === 0) return <div className="py-8 text-center text-sm text-muted-foreground">{_L("register.no_tickets")}</div>;
  return (
    <div className="space-y-2">
      {tickets.map((t) => <TicketCard key={t.orderId} id={id} t={t} />)}
    </div>
  );
}

function TicketCard({ id, t }: { id: number; t: Ticket }) {
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [busy, setBusy] = useState(false);

  // Fire the action; the ticket drops out of the list when the server's `orders`
  // broadcast lands (near-instant). On failure the server notifies and the list
  // is unchanged, so we just un-busy.
  const act = async (event: string) => {
    setBusy(true);
    await fetchNui(event, { id, orderId: t.orderId });
    setBusy(false);
  };

  return (
    <Card>
      <CardContent className="pt-4">
        <div className="mb-2 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <Badge variant="secondary">{_L("register.ticket_num", t.ticket)}</Badge>
            <span className="text-sm font-medium">{t.customer}</span>
          </div>
          <span className="text-sm font-semibold">{money(t.total)}</span>
        </div>
        <div className="mb-3 space-y-1.5">
          {t.lines.map((l, i) => {
            const mods = Array.isArray(l.mods) ? l.mods : [];
            const added = mods.filter((m) => !m.removed);
            const removed = mods.filter((m) => m.removed);
            return (
              <div key={i} className="flex items-center gap-2 rounded-md bg-muted/40 p-1.5">
                <Thumb src={l.image} className="h-9 w-9 shrink-0" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-xs font-medium">{l.label}</div>
                  <OptRow added={added} removed={removed} />
                </div>
                <span className="shrink-0 rounded bg-background/70 px-1.5 py-0.5 text-xs font-semibold tabular-nums">×{l.qty}</span>
              </div>
            );
          })}
        </div>
        <div className="flex justify-end gap-2">
          {confirmCancel ? (
            <>
              <span className="mr-auto self-center text-xs text-muted-foreground">{_L("register.confirm_cancel")}</span>
              <Button size="sm" variant="ghost" disabled={busy} onClick={() => setConfirmCancel(false)}>{_L("register.keep")}</Button>
              <Button size="sm" variant="destructive" disabled={busy} onClick={() => act("sales:cancelOrder")}>
                <X className="h-4 w-4" /> {_L("register.cancel_refund")}
              </Button>
            </>
          ) : (
            <>
              <Button size="sm" variant="outline" disabled={busy} onClick={() => setConfirmCancel(true)}>
                <Trash2 className="h-4 w-4" /> {_L("register.cancel")}
              </Button>
              <Button size="sm" disabled={busy} onClick={() => act("sales:completeOrder")}>
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} {_L("register.complete")}
              </Button>
            </>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
