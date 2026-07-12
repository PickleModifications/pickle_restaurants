import { useEffect, useState } from "react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  ShoppingCart, Trash2, Check, X, Loader2, ClipboardList, Ban, UtensilsCrossed,
} from "lucide-react";
import {
  OrderBuilder, Thumb, OptRow, arr,
  type Cat, type Near, type Ticket, type MealOption, type MealItem, type OptView,
} from "@/components/OrderBuilder";
import TicketTimer from "@/components/TicketTimer";

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
          <OrderBuilder id={id} catalog={catalog} nearby={nearby} mode="register" />
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
          <div className="flex shrink-0 items-center gap-2">
            {/* NPC walk-ins run out of patience — show the time left + radial so the
                cashier knows how long the order will still be here to fulfill. */}
            {t.npc && t.expiresIn != null && (
              <TicketTimer expiresIn={t.expiresIn} patience={t.patience} size={34} />
            )}
            <span className="font-mono text-sm font-bold tabular-nums">{money(t.total)}</span>
          </div>
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
