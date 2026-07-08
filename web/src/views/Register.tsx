import { useEffect, useMemo, useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  ShoppingCart, Plus, Minus, Trash2, User, Receipt, Check, X, Loader2, ImageOff, ClipboardList,
} from "lucide-react";

type Cat = { key: string; item: string; variant: string; label: string; kind: string; price: number; image?: string };
type Line = { item: string; variant: string; label: string; price: number; qty: number; kind: string };
type Ticket = { orderId: number; ticket: number; customer: string; lines: Line[]; total: number };
type Near = { id: number; name: string };

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

export default function Register({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const catalog: Cat[] = data?.catalog || [];
  const tickets: Ticket[] = data?.tickets || [];

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
          <NewOrder id={id} catalog={catalog} nearby={data?.nearby || []} />
        </TabsContent>

        <TabsContent value="tickets" className="min-h-0 flex-1 overflow-y-auto pr-1">
          <Tickets id={id} tickets={tickets} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}

function NewOrder({ id, catalog, nearby }: { id: number; catalog: Cat[]; nearby: Near[] }) {
  const [cart, setCart] = useState<Record<string, number>>({});
  const [customer, setCustomer] = useState(0); // 0 = Myself
  const [kind, setKind] = useState<string>("all");
  const [busy, setBusy] = useState(false);

  const kinds = useMemo(() => Array.from(new Set(catalog.map((c) => c.kind))), [catalog]);
  const shown = kind === "all" ? catalog : catalog.filter((c) => c.kind === kind);
  const byKey = useMemo(() => Object.fromEntries(catalog.map((c) => [c.key, c])), [catalog]);

  const add = (k: string) => setCart((c) => ({ ...c, [k]: Math.min(10, (c[k] || 0) + 1) }));
  const sub = (k: string) => setCart((c) => {
    const n = (c[k] || 0) - 1;
    const next = { ...c };
    if (n <= 0) delete next[k]; else next[k] = n;
    return next;
  });
  const remove = (k: string) => setCart((c) => { const n = { ...c }; delete n[k]; return n; });

  const lines = Object.entries(cart).map(([k, qty]) => ({ ...byKey[k], qty })).filter((l) => l.key);
  const total = lines.reduce((s, l) => s + l.price * l.qty, 0);

  const charge = async () => {
    if (lines.length === 0 || busy) return;
    setBusy(true);
    const cartArr = Object.entries(cart).map(([key, qty]) => ({ key, qty }));
    const res: any = await fetchNui("sales:createOrder", { id, customer, cart: cartArr });
    setBusy(false);
    if (res && res.tickets) setCart({}); // success returns a fresh register payload
  };

  return (
    <div className="grid h-full grid-cols-5 gap-4">
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
            {shown.map((c) => (
              <button key={c.key} onClick={() => add(c.key)}
                className="flex flex-col items-center gap-1.5 rounded-lg border border-border p-2 text-center transition-colors hover:border-primary/50 hover:bg-accent/50">
                <Thumb src={c.image} className="h-12 w-12" />
                <span className="line-clamp-2 text-xs font-medium leading-tight">{c.label}</span>
                <span className="text-xs text-muted-foreground">{money(c.price)}</span>
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* cart */}
      <div className="col-span-2 flex min-h-0 flex-col rounded-lg border border-border">
        <div className="shrink-0 border-b border-border px-3 py-2 text-sm font-semibold">{_L("register.cart")}</div>
        <div className="min-h-0 flex-1 space-y-1.5 overflow-y-auto p-2">
          {lines.length === 0 && <div className="py-6 text-center text-xs text-muted-foreground">{_L("register.empty_cart")}</div>}
          {lines.map((l) => (
            <div key={l.key} className="flex items-center gap-2 rounded-md bg-muted/40 p-1.5">
              <Thumb src={l.image} className="h-8 w-8 shrink-0" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-xs font-medium">{l.label}</div>
                <div className="text-[11px] text-muted-foreground">{money(l.price)}</div>
              </div>
              <div className="flex shrink-0 items-center gap-1">
                <button onClick={() => sub(l.key)} className="grid h-6 w-6 place-items-center rounded border border-border hover:bg-accent"><Minus className="h-3 w-3" /></button>
                <span className="w-5 text-center text-xs tabular-nums">{l.qty}</span>
                <button onClick={() => add(l.key)} className="grid h-6 w-6 place-items-center rounded border border-border hover:bg-accent"><Plus className="h-3 w-3" /></button>
                <button onClick={() => remove(l.key)} className="grid h-6 w-6 place-items-center rounded text-muted-foreground hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
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
        <div className="mb-3 flex flex-wrap gap-1.5">
          {t.lines.map((l, i) => (
            <Badge key={i} variant="outline" className="font-normal">{l.qty}× {l.label}</Badge>
          ))}
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
