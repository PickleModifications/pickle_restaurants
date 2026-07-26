import { useEffect, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Trash2, Check, X, Loader2, Ban, UtensilsCrossed, ShoppingBag } from "lucide-react";
import {
  Thumb, OptRow, arr, groupLines,
  type Ticket, type MealOption, type MealItem, type OptView,
} from "@/components/OrderBuilder";
import { drinkLineImageUrl } from "@/lib/localImages";
import TicketTimer from "@/components/TicketTimer";

// The staff-facing ticket list + fulfillment UI (complete / cancel / meal picker),
// shared by BOTH the full-screen register panel (views/Register.tsx) and the in-world
// register DUI (views/RegisterDui.tsx) so the two can't drift. Purely prop-driven:
// the owner passes the live ticket list (seeded from the open payload, kept current
// off the server's `orders` broadcast) and this renders + acts on it. `big` scales it
// up for the in-world screen, whose virtual cursor wants larger aim targets.
export function Tickets({ id, tickets, big }: { id: number; tickets: Ticket[]; big?: boolean }) {
  // The meal picker is owned here (not per-card) so it overlays the ticket LIST
  // area only — dimming the content, not the panel header — and centres in it.
  const [picker, setPicker] = useState<{ orderId: number; meals: MealOption[] } | null>(null);
  const [busy, setBusy] = useState(false);
  // Drop the picker if its ticket left the list (completed/cancelled elsewhere).
  useEffect(() => {
    if (picker && !tickets.some((t) => t.orderId === picker.orderId)) setPicker(null);
  }, [tickets]); // eslint-disable-line react-hooks/exhaustive-deps

  // `item` says which packed vessel is being handed over — a serving-tray meal or a
  // Restaurant Bag. The server re-validates it (anything else falls back to the meal).
  const fulfillMeal = async (sig: string, item?: string) => {
    if (!picker) return;
    setBusy(true);
    await fetchNui("sales:completeOrder", { id, orderId: picker.orderId, mealSig: sig, mealItem: item });
    setBusy(false);
    setPicker(null); // (also clears via the `orders` broadcast on success)
  };

  if (tickets.length === 0) return <div className={cn("py-8 text-center text-muted-foreground", big ? "text-lg" : "text-sm")}>{_L("register.no_tickets")}</div>;
  return (
    <div className="relative h-full">
      <div className={cn("h-full overflow-y-auto pr-1 pb-4", big ? "space-y-3" : "space-y-2")}>
        {tickets.map((t) => (
          <TicketCard key={t.orderId} id={id} t={t} big={big}
            onOpenPicker={(meals) => setPicker({ orderId: t.orderId, meals })} />
        ))}
      </div>
      {picker && (
        <MealPicker meals={picker.meals} busy={busy} big={big} onFulfill={fulfillMeal} onClose={() => setPicker(null)} />
      )}
    </div>
  );
}

function TicketCard({ id, t, big, onOpenPicker }: { id: number; t: Ticket; big?: boolean; onOpenPicker: (meals: MealOption[]) => void }) {
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

  const btn = cn("inline-flex items-center gap-1.5 rounded-md font-semibold shadow-sm transition-colors disabled:opacity-50",
    big ? "px-4 py-2.5 text-sm" : "px-3 py-1.5 text-xs");
  const ic = big ? "h-4 w-4" : "h-3.5 w-3.5";

  return (
    <div className="drop-shadow-md">
      <div className={cn("receipt rounded-t-sm", big ? "px-4 pb-4 pt-4" : "px-3.5 pb-3 pt-3")}>
        <div className="mb-2 flex items-center justify-between gap-2">
          <div className="flex min-w-0 items-center gap-2">
            <span className={cn("shrink-0 rounded-sm bg-muted px-1.5 py-0.5 font-mono font-bold uppercase tracking-wider tabular-nums", big ? "text-xs" : "text-[10px]")}>
              {_L("register.ticket_num", t.ticket)}
            </span>
            <span className={cn("truncate font-medium", big ? "text-base" : "text-sm")}>{t.customer}</span>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {/* NPC walk-ins run out of patience — show the time left + radial so the
                cashier knows how long the order will still be here to fulfill. */}
            {t.npc && t.expiresIn != null && (
              <TicketTimer expiresIn={t.expiresIn} patience={t.patience} size={big ? 40 : 34} />
            )}
            <span className={cn("font-mono font-bold tabular-nums", big ? "text-base" : "text-sm")}>{money(t.total)}</span>
          </div>
        </div>
        <div className="receipt-rule mb-2" />
        <div className="mb-3 space-y-1">
          {groupLines(t.lines).map((b, bi) => {
            if (b.type === "item") {
              const l = b.line;
              const mods = Array.isArray(l.mods) ? l.mods : [];
              return (
                <div key={bi} className="flex items-center gap-2 rounded-sm bg-muted/50 p-1.5">
                  <Thumb src={drinkLineImageUrl(l.kind, l.variant)} fallbackSrc={l.image} className={cn("shrink-0", big ? "h-11 w-11" : "h-9 w-9")} />
                  <div className="min-w-0 flex-1">
                    <div className={cn("truncate font-medium", big ? "text-sm" : "text-xs")}>{l.label}</div>
                    <OptRow added={mods.filter((m) => !m.removed)} removed={mods.filter((m) => m.removed)} />
                  </div>
                  <span className={cn("shrink-0 font-mono font-semibold tabular-nums text-muted-foreground", big ? "text-sm" : "text-xs")}>×{l.qty}</span>
                </div>
              );
            }
            return (
              <div key={bi} className="rounded-sm bg-muted/50 p-1.5">
                <div className="flex items-center gap-2">
                  <span className="grid h-6 w-6 shrink-0 place-items-center rounded bg-primary/15 font-mono text-[10px] font-bold text-primary tabular-nums">#{b.number}</span>
                  <div className="min-w-0 flex-1 truncate text-xs font-semibold">{b.label}</div>
                  <span className="shrink-0 font-mono text-xs font-semibold tabular-nums text-muted-foreground">×{b.qty}</span>
                </div>
                <div className="mt-1 space-y-0.5 border-l border-border/60 pl-2">
                  {b.comps.map((l, li) => {
                    const mods = Array.isArray(l.mods) ? l.mods : [];
                    return (
                      <div key={li} className="flex items-center gap-1.5">
                        <Thumb src={drinkLineImageUrl(l.kind, l.variant)} fallbackSrc={l.image} className="h-6 w-6 shrink-0" />
                        <span className="truncate text-[11px]">{l.label}</span>
                        <OptRow added={mods.filter((m) => !m.removed)} removed={mods.filter((m) => m.removed)} />
                      </div>
                    );
                  })}
                </div>
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
                className={cn("rounded-md font-semibold text-muted-foreground transition-colors hover:text-foreground disabled:opacity-50", big ? "px-4 py-2.5 text-sm" : "px-3 py-1.5 text-xs")}>
                {_L("register.keep")}
              </button>
              <button disabled={busy} onClick={() => act("sales:cancelOrder")}
                className={cn(btn, "bg-destructive text-white hover:bg-[rgb(var(--danger-hover))]")}>
                <X className={ic} /> {_L("register.cancel_refund")}
              </button>
            </>
          ) : (
            <>
              <button disabled={busy} onClick={() => setConfirmCancel(true)}
                className={cn("inline-flex items-center gap-1.5 rounded-md border border-border font-semibold text-foreground transition-colors hover:border-destructive hover:text-destructive disabled:opacity-50", big ? "px-4 py-2.5 text-sm" : "px-3 py-1.5 text-xs")}>
                <Trash2 className={ic} /> {_L("register.cancel")}
              </button>
              {/* a packed vessel — a meal or a takeaway bag — (with any single items)
                  can complete this order: open the in-depth picker to review the
                  contents and hand one over */}
              {mealOptions.length > 0 && (
                <button disabled={busy} onClick={() => onOpenPicker(mealOptions)}
                  className={cn(btn, "border border-primary/50 bg-primary/10 text-primary hover:bg-primary/20")}>
                  {mealOptions.every((m) => m.bag) ? <ShoppingBag className={ic} /> : <UtensilsCrossed className={ic} />}
                  {" "}
                  {_L(mealOptions.some((m) => m.bag) ? "register.fulfill_with_packed" : "register.fulfill_with_meal", mealOptions.length)}
                </button>
              )}
              {f?.ok ? (
                <button disabled={busy} onClick={() => act("sales:completeOrder")}
                  className={cn(btn, "bg-primary text-primary-foreground hover:bg-[rgb(var(--brand-hover))]")}>
                  {busy ? <Loader2 className={cn(ic, "animate-spin")} /> : <Check className={ic} />} {_L("register.complete")}
                </button>
              ) : mealOptions.length === 0 ? (
                <button disabled title={missing.length ? _L("register.missing", missing.join(", ")) : undefined}
                  className={cn("inline-flex cursor-not-allowed items-center gap-1.5 rounded-md border border-border font-semibold text-muted-foreground opacity-70", big ? "px-4 py-2.5 text-sm" : "px-3 py-1.5 text-xs")}>
                  <Ban className={ic} /> {_L("register.not_complete")}
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
function MealPicker({ meals, busy, big, onFulfill, onClose }: {
  meals: MealOption[]; busy: boolean; big?: boolean; onFulfill: (sig: string, item?: string) => void; onClose: () => void;
}) {
  const [visible, setVisible] = useState(false);
  // fade in on mount (next frame so the transition has a 0→1 to animate)
  useEffect(() => { const r = requestAnimationFrame(() => setVisible(true)); return () => cancelAnimationFrame(r); }, []);
  // fade out, then unmount via the parent's onClose
  const close = () => { setVisible(false); window.setTimeout(onClose, 180); };
  const fulfill = (sig: string, item?: string) => { setVisible(false); window.setTimeout(() => onFulfill(sig, item), 160); };
  return (
    <div
      className={cn("absolute inset-0 z-30 flex items-center justify-center p-4 transition-opacity duration-200",
        visible ? "opacity-100" : "opacity-0")}
      onClick={close}
    >
      <div className="absolute inset-0 bg-black/50" />
      <div
        className={cn("relative flex max-h-full w-full flex-col rounded-lg border border-border bg-card shadow-2xl transition-transform duration-200",
          big ? "max-w-lg" : "max-w-md", visible ? "scale-100" : "scale-95")}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-2 border-b border-border px-4 py-3">
          <UtensilsCrossed className="h-4 w-4 text-primary" />
          <span className="font-semibold">
            {_L(meals.some((m) => m.bag) ? "register.packed_picker_title" : "register.meal_picker_title")}
          </span>
          <span className="rounded-full bg-muted px-1.5 py-0.5 font-mono text-[10px] font-bold tabular-nums text-muted-foreground">{meals.length}</span>
          <button onClick={close} className="ml-auto text-muted-foreground transition-colors hover:text-foreground"><X className="h-4 w-4" /></button>
        </div>
        <div className="min-h-0 flex-1 space-y-2 overflow-y-auto p-3">
          {meals.map((m, mi) => {
            const items = arr<MealItem>(m.items);
            return (
              <div key={m.item + m.sig} className="rounded-lg border border-border bg-muted/30 p-3">
                <div className="tape mb-2 flex items-center gap-1.5 text-muted-foreground">
                  {m.bag ? <ShoppingBag className="h-3 w-3" /> : <UtensilsCrossed className="h-3 w-3" />}
                  {_L(m.bag ? "register.bag_n" : "register.meal_n", mi + 1)}
                </div>
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
                <Button className="mt-3 w-full" size="sm" disabled={busy} onClick={() => fulfill(m.sig, m.item)}>
                  {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
                  {" "}
                  {_L(m.bag ? "register.fulfill_this_bag" : "register.fulfill_this_meal")}
                </Button>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
