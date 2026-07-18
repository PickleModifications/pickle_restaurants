import { useEffect, useMemo, useState } from "react";
import {
  Truck,
  ShoppingBag,
  Utensils,
  CheckCircle2,
  Camera,
  Star,
  ClipboardList,
} from "lucide-react";
import { fetchNui, useNuiEvent } from "../../lib/nui";
import { cn } from "../../lib/utils";
import { usePhone, money } from "../store";
import { Screen, TopBar, ItemImg, Empty, Stars } from "../ui";

const TYPE_ICON: Record<string, any> = { delivery: Truck, pickup: ShoppingBag, dine_in: Utensils };
const TYPE_LABEL: Record<string, string> = { delivery: "Delivery", pickup: "Pickup", dine_in: "Dine-in" };

// The three phases the customer sees. "Ready" wording flips for delivery.
function steps(type: string) {
  return [
    { key: "placed", label: "Order placed" },
    { key: "cooking", label: "In the kitchen" },
    { key: "ready", label: type === "delivery" ? "On the way" : "Ready for pickup" },
    { key: "done", label: "Completed" },
  ];
}

function phaseIndex(o: any) {
  if (o.status === "completed") return 3;
  if (o.status === "cancelled") return -1;
  return o.ready ? 2 : 1;
}

// ─── orders list ──────────────────────────────────────────────────────────────
export function Orders() {
  const { home, currency, go } = usePhone();
  const [tab, setTab] = useState<"active" | "past">("active");
  const orders: any[] = home?.orders || [];
  const active = orders.filter((o) => o.status === "open");
  const past = orders.filter((o) => o.status !== "open");
  const list = tab === "active" ? active : past;

  return (
    <Screen className="pb-20">
      <TopBar title="Your orders" />
      <div className="flex gap-2 px-4 pb-2 pt-3">
        {(["active", "past"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={cn(
              "rounded-full px-3 py-1.5 text-sm font-semibold capitalize",
              tab === t ? "bg-brand text-brand-ink" : "bg-muted text-muted-foreground"
            )}
          >
            {t} {t === "active" && active.length > 0 && `· ${active.length}`}
          </button>
        ))}
      </div>

      {list.length === 0 ? (
        <Empty
          icon={<ClipboardList className="h-8 w-8" />}
          title={tab === "active" ? "No orders in progress" : "No past orders"}
          hint={tab === "active" ? "Your live orders show up here." : "Completed orders will appear here."}
        />
      ) : (
        <div className="space-y-2 px-4">
          {list.map((o) => {
            const Icon = TYPE_ICON[o.type] || ShoppingBag;
            const pi = phaseIndex(o);
            return (
              <button
                key={o.orderId}
                onClick={() => go("order", { orderId: o.orderId, rid: o.restaurantId })}
                className="flex w-full items-center gap-3 rounded-2xl border border-border bg-card p-3 text-left active:scale-[0.99]"
              >
                {o.lines?.[0]?.image ? (
                  <ItemImg src={o.lines[0].image} alt={o.lines[0].label} className="h-11 w-11 shrink-0 rounded-xl bg-muted" />
                ) : (
                  <span className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-muted text-foreground">
                    <Icon className="h-5 w-5" />
                  </span>
                )}
                <div className="min-w-0 flex-1">
                  <div className="truncate font-semibold">{o.restaurant}</div>
                  <div className="text-[0.72rem] text-muted-foreground">
                    #{o.ticket} · {TYPE_LABEL[o.type] || "Pickup"} ·{" "}
                    {o.status === "open" ? (
                      <span className="font-semibold text-primary">{steps(o.type)[pi]?.label}</span>
                    ) : o.status === "cancelled" ? (
                      "Cancelled"
                    ) : (
                      "Completed"
                    )}
                  </div>
                </div>
                <span className="font-mono text-sm">{money(currency, o.total)}</span>
              </button>
            );
          })}
        </div>
      )}
    </Screen>
  );
}

// ─── live tracking hero ───────────────────────────────────────────────────────
export function OrderTrack({ params }: { params: any }) {
  const { home, currency, back, toast, refreshHome } = usePhone();
  const rid = params.rid;
  const seed = (home?.orders || []).find((o: any) => o.orderId === params.orderId);
  const [order, setOrder] = useState<any>(seed || { orderId: params.orderId, status: "open", type: "pickup", lines: [] });
  const [reviewing, setReviewing] = useState(false);

  // Live: the server broadcasts open tickets for this restaurant. Update our
  // ready-flag off it; when our ticket drops out of the open list, it's completed.
  useNuiEvent("orders", (d) => {
    if (d.rid !== rid) return;
    const mine = (d.orders || []).find((t: any) => t.orderId === params.orderId);
    if (mine) {
      setOrder((o: any) => ({ ...o, status: "open", ready: !!mine.fulfill?.ready, lines: mine.lines || o.lines, total: mine.total ?? o.total }));
    } else {
      setOrder((o: any) => (o.status === "open" ? { ...o, status: "completed", ready: true } : o));
      fetchNui("phone:endDeliveryBlip", {});
    }
  });

  const stepList = steps(order.type);
  const pi = phaseIndex(order);
  const Icon = TYPE_ICON[order.type] || ShoppingBag;

  return (
    <Screen className="pb-6">
      <TopBar title={`Ticket #${order.ticket ?? ""}`} subtitle={order.restaurant} onBack={back} />

      {/* status ticket */}
      <div className="px-4">
        <div className="receipt tear-b relative mx-auto mt-2 max-w-sm px-5 pb-6 pt-5">
          <div className="flex items-center justify-between">
            <span className="tape text-paper-muted">{TYPE_LABEL[order.type] || "Pickup"}</span>
            <Icon className="h-5 w-5 text-paper-ink/70" />
          </div>
          <div className="mt-2 font-display text-2xl font-extrabold text-paper-ink">
            {order.status === "completed"
              ? "All done — enjoy!"
              : order.status === "cancelled"
              ? "Order cancelled"
              : stepList[pi]?.label}
          </div>

          {/* stepper */}
          {order.status !== "cancelled" && (
            <div className="mt-4 flex items-center">
              {stepList.map((s, i) => (
                <div key={s.key} className="flex flex-1 items-center last:flex-none">
                  <div
                    className={cn(
                      "pf-track-dot",
                      i < pi && "done",
                      i === pi && order.status !== "completed" && "active",
                      order.status === "completed" && "done"
                    )}
                  />
                  {i < stepList.length - 1 && (
                    <div className={cn("pf-track-line", (i < pi || order.status === "completed") && "done")} />
                  )}
                </div>
              ))}
            </div>
          )}

          {order.type === "delivery" && pi >= 2 && order.status === "open" && (
            <div className="mt-3 flex items-center gap-2 rounded-lg bg-paper-muted/15 px-3 py-2 text-[0.78rem] text-paper-ink">
              <Truck className="h-4 w-4" /> Driver's on the way — follow the blip on your map.
            </div>
          )}

          <div className="receipt-rule my-4" />
          <div className="space-y-1.5 font-mono text-sm text-paper-ink">
            {(order.lines || []).map((l: any, i: number) => (
              <div key={i} className="flex justify-between">
                <span>
                  {l.qty}× {l.label}
                </span>
                <span>{money(currency, (l.price || 0) * (l.qty || 1))}</span>
              </div>
            ))}
            <div className="mt-2 flex justify-between border-t border-paper-muted/40 pt-2 font-bold">
              <span>Total</span>
              <span>{money(currency, order.total || 0)}</span>
            </div>
          </div>
        </div>
      </div>

      {/* completed → review prompt */}
      {order.status === "completed" && !order.rated && !reviewing && (
        <div className="mx-4 mt-4 flex items-center gap-3 rounded-2xl border border-border bg-card p-3">
          <CheckCircle2 className="h-6 w-6 text-ok" />
          <div className="flex-1 text-sm">How was it? Leave a review.</div>
          <button
            onClick={() => setReviewing(true)}
            className="rounded-full bg-brand px-3 py-1.5 text-sm font-bold text-brand-ink"
          >
            Rate
          </button>
        </div>
      )}

      {reviewing && (
        <ReviewSheet
          rid={rid}
          orderId={order.orderId}
          onClose={() => setReviewing(false)}
          onDone={async () => {
            setReviewing(false);
            setOrder((o: any) => ({ ...o, rated: true }));
            toast("Thanks for the review!");
            await refreshHome();
          }}
        />
      )}
    </Screen>
  );
}

// ─── review sheet (optional photo via lb-phone camera) ────────────────────────
export function ReviewSheet({
  rid,
  orderId,
  onClose,
  onDone,
}: {
  rid: number;
  orderId?: number;
  onClose: () => void;
  onDone: () => void;
}) {
  const { toast } = usePhone();
  const [rating, setRating] = useState(5);
  const [comment, setComment] = useState("");
  const [photo, setPhoto] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const attach = () => {
    const cam = (window as any).useCamera || (window as any).selectGallery;
    if (typeof cam === "function") {
      cam((url: string) => url && setPhoto(url));
    } else {
      toast("Camera unavailable here", "err");
    }
  };

  const submit = async () => {
    setBusy(true);
    const res = await fetchNui("phone:submitReview", { id: rid, orderId, rating, comment, photo });
    setBusy(false);
    if (res?.ok) onDone();
    else toast(res?.error || "Couldn't submit", "err");
  };

  return (
    <>
      <div className="pf-scrim" onClick={onClose} />
      <div className="pf-sheet">
        <div className="pf-grab" />
        <div className="p-4">
          <div className="font-display text-lg font-extrabold">Rate your order</div>
          <div className="mt-3 flex justify-center">
            <Stars value={rating} size={34} onPick={setRating} />
          </div>
          <textarea
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            placeholder="Tell others how it was (optional)"
            rows={3}
            className="mt-3 w-full resize-none rounded-xl border border-border bg-background p-3 text-sm outline-none placeholder:text-muted-foreground"
          />
          <button
            onClick={attach}
            className="mt-2 flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2 text-sm font-semibold active:scale-[0.99]"
          >
            <Camera className="h-4 w-4" /> {photo ? "Photo attached" : "Add a photo"}
          </button>
          {photo && <img src={photo} className="mt-2 h-28 w-full rounded-xl object-cover" />}
          <button
            disabled={busy}
            onClick={submit}
            className="mt-4 w-full rounded-full bg-brand px-4 py-3 font-bold text-brand-ink disabled:opacity-60"
          >
            {busy ? "Submitting…" : "Post review"}
          </button>
        </div>
      </div>
    </>
  );
}
