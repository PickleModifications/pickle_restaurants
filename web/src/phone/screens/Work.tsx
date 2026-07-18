import { useEffect, useMemo, useState } from "react";
import {
  Clock,
  Play,
  Square,
  Truck,
  Bot,
  ShoppingBag,
  Utensils,
  Check,
  X,
  Settings,
  Trophy,
  DollarSign,
  Users,
  Boxes,
  Megaphone,
  TrendingUp,
  Plus,
  Minus,
  UserPlus,
  Trash2,
  Info,
  MapPin,
  CalendarClock,
} from "lucide-react";
import { fetchNui, useNuiEvent } from "../../lib/nui";
import { cn } from "../../lib/utils";
import { usePhone, money } from "../store";
import { Screen, TopBar, Empty, Spinner, ItemImg, Sheet } from "../ui";

const TYPE_ICON: Record<string, any> = { delivery: Truck, pickup: ShoppingBag, dine_in: Utensils };

function useEmployment(paramRid?: number) {
  const { home } = usePhone();
  const employment: any[] = home?.employment || [];
  const [rid, setRid] = useState<number | null>(paramRid ?? employment[0]?.id ?? null);
  const active = employment.find((e) => e.id === rid);
  return { employment, rid, setRid, active };
}

function fmtDur(seconds: number) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

const TYPE_LABEL: Record<string, string> = { delivery: "Delivery", pickup: "Pickup", dine_in: "Dine-in" };

function modText(mods?: any[]) {
  if (!mods || mods.length === 0) return "";
  return mods.map((m: any) => (m.removed ? `no ${m.label}` : `+${m.label}`)).join(", ");
}

// The delivery claim button, shared by the queue card and the detail sheet.
// A delivery has exactly ONE driver: the first employee to accept it holds it until
// they cancel, serve it, or leave the server. So this is a three-state control —
// free (accept), held by ME (cancel), held by SOMEONE ELSE (inert, just says who).
// The server enforces all of it by identifier; this only decides what to show.
function DeliveryAction({
  t,
  me,
  ready,
  compact,
  onAccept,
  onCancelDelivery,
  onWaypoint,
}: {
  t: any;
  me?: number;
  ready?: boolean;
  compact?: boolean;
  onAccept: () => void;
  onCancelDelivery: () => void;
  onWaypoint: () => void;
}) {
  if (t.orderType !== "delivery") return null;
  const pad = compact ? "py-2" : "py-2.5";
  const mine = t.driver && me != null && t.driver.server === me;

  if (t.driver && !mine) {
    return (
      <div
        className={cn(
          "flex flex-1 items-center justify-center gap-1 rounded-full bg-muted px-3 text-sm font-bold text-muted-foreground",
          pad
        )}
      >
        <Truck className="h-4 w-4" /> With {t.driver.name || "a driver"}
      </div>
    );
  }
  if (mine) {
    // A waypoint is a single global slot anything can clear, so the driver needs it
    // re-settable for the whole run — not just at the moment they accepted.
    return (
      <>
        <button
          onClick={onWaypoint}
          className={cn(
            "flex flex-1 items-center justify-center gap-1 rounded-full bg-brand px-3 text-sm font-bold text-brand-ink",
            pad
          )}
        >
          <MapPin className="h-4 w-4" /> Set Waypoint
        </button>
        <button
          onClick={onCancelDelivery}
          aria-label="Cancel delivery"
          className={cn(
            "grid shrink-0 place-items-center rounded-full bg-destructive/15 px-3 text-destructive",
            compact ? "h-9 w-9" : "h-11 w-11"
          )}
        >
          <X className="h-4 w-4" />
        </button>
      </>
    );
  }
  if (!ready) return null;
  return (
    <button
      onClick={onAccept}
      className={cn("flex flex-1 items-center justify-center gap-1 rounded-full bg-muted px-3 text-sm font-bold", pad)}
    >
      <Truck className="h-4 w-4" /> Accept Delivery
    </button>
  );
}

// A full-detail ticket sheet: every line with its photo + mods, the customer /
// order-type / delivery meta, fulfillment state, and the serve/delivery/cancel
// actions. Opened from a ticket's info button in the queue.
function TicketSheet({
  t,
  currency,
  onClose,
  onServe,
  onAccept,
  onCancelDelivery,
  onWaypoint,
  onCancel,
  me,
}: {
  t: any;
  currency: string;
  onClose: () => void;
  onServe: () => void;
  onAccept: () => void;
  onCancelDelivery: () => void;
  onWaypoint: () => void;
  onCancel: () => void;
  me?: number;
}) {
  const ready = t.fulfill?.ready;
  const Icon = t.npc ? Bot : TYPE_ICON[t.orderType] || ShoppingBag;
  const typeLabel = t.npc ? "Walk-in" : TYPE_LABEL[t.orderType] || "Pickup";
  return (
    <Sheet onClose={onClose}>
      <>
        <div className="pf-grab" />
        {/* header */}
        <div className="flex items-center gap-3 px-4 pb-3 pt-1">
          <span className="grid h-11 w-11 place-items-center rounded-xl bg-muted">
            <Icon className="h-5 w-5" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="font-display text-lg font-extrabold leading-tight">Ticket #{t.ticket}</div>
            <div className="text-[0.72rem] text-muted-foreground">
              {typeLabel} · {t.customer || "Guest"}
            </div>
          </div>
          <span className="font-mono text-base font-bold">{money(currency, t.total)}</span>
        </div>

        {/* meta (delivery address / scheduled) */}
        {(t.address || t.scheduled) && (
          <div className="mx-4 mb-3 space-y-1.5 rounded-xl border border-border bg-card px-3 py-2 text-[0.76rem]">
            {t.address && (
              <div className="flex items-start gap-2">
                <MapPin className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />
                <span className="text-foreground">{t.address}</span>
              </div>
            )}
            {t.scheduled && (
              <div className="flex items-center gap-2">
                <CalendarClock className="h-3.5 w-3.5 shrink-0 text-brand" />
                <span className="text-foreground">Scheduled · {t.scheduled}</span>
              </div>
            )}
          </div>
        )}

        {/* line items with photos — scrolls if long */}
        <div className="min-h-0 flex-1 overflow-y-auto px-4">
          <div className="space-y-2">
            {(t.lines || []).map((l: any, i: number) => (
              <div key={i} className="flex items-center gap-3 rounded-xl border border-border bg-card p-2">
                <ItemImg src={l.image} alt={l.label} className="h-12 w-12 shrink-0 rounded-lg bg-muted" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-semibold">
                    <span className="font-mono text-muted-foreground">{l.qty}×</span> {l.label}
                  </div>
                  {l.mods && l.mods.length > 0 && (
                    <div className="truncate text-[0.7rem] text-muted-foreground">{modText(l.mods)}</div>
                  )}
                </div>
                <span className="font-mono text-[0.78rem] text-muted-foreground">
                  {money(currency, (l.price || 0) * (l.qty || 1))}
                </span>
              </div>
            ))}
          </div>

          {!ready && t.fulfill?.missing && (
            <div className="mt-3 rounded-lg bg-warn/15 px-3 py-2 text-[0.74rem] text-warn">
              Still cooking: {t.fulfill.missing.join(", ")}
            </div>
          )}
        </div>

        {/* actions */}
        <div className="flex gap-2 border-t border-border p-4" style={{ paddingBottom: "calc(1rem + var(--pf-bottom))" }}>
          <DeliveryAction
            t={t}
            me={me}
            ready={ready}
            onAccept={onAccept}
            onCancelDelivery={onCancelDelivery}
            onWaypoint={onWaypoint}
          />
          <button
            disabled={!ready}
            onClick={onServe}
            className={cn(
              "flex flex-1 items-center justify-center gap-1 rounded-full px-3 py-2.5 text-sm font-bold",
              ready ? "bg-ok text-white" : "bg-muted text-muted-foreground"
            )}
          >
            <Check className="h-4 w-4" /> {ready ? "Serve" : "Not ready"}
          </button>
          <button onClick={onCancel} className="grid h-11 w-11 place-items-center rounded-full bg-muted">
            <X className="h-4 w-4" />
          </button>
        </div>
      </>
    </Sheet>
  );
}

function RestaurantChips({ employment, rid, setRid }: any) {
  if (employment.length < 2) return null;
  return (
    <div className="pf-rail px-4 pb-2 pt-3">
      {employment.map((e: any) => (
        <button
          key={e.id}
          onClick={() => setRid(e.id)}
          className={cn(
            "rounded-full border px-3 py-1.5 text-sm font-semibold",
            rid === e.id ? "border-brand bg-brand text-brand-ink" : "border-border bg-card"
          )}
        >
          {e.label}
        </button>
      ))}
    </div>
  );
}

// ─── KITCHEN (KDS) ────────────────────────────────────────────────────────────
export function Kitchen({ params }: { params?: any }) {
  const { home, go, currency, toast } = usePhone();
  const { employment, rid, setRid, active } = useEmployment(params?.rid);
  const [tickets, setTickets] = useState<any[]>([]);
  const [shift, setShift] = useState<any>(null);
  const [detailId, setDetailId] = useState<number | null>(null);
  // Our own server id, carried by BOTH the ticket seed and the live broadcast — it's how
  // a claimed delivery is recognised as OURS (see DeliveryAction).
  const [me, setMe] = useState<number | undefined>(undefined);
  const canManage =
    active && (active.isOwner || ["manage_menu", "view_finances", "manage_employees", "manage_stock"].some((p) => active.perms?.[p]));

  const loadTickets = () =>
    rid &&
    fetchNui("phone:tickets", { id: rid }).then((d) => {
      if (!d?.ok) return;
      setTickets(d.tickets || []);
      if (typeof d.me === "number") setMe(d.me);
    });
  const loadShift = () => rid && fetchNui("phone:shiftStatus", { id: rid }).then((d) => d?.ok && setShift(d));
  useEffect(() => {
    setTickets([]);
    loadTickets();
    loadShift();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rid]);

  useNuiEvent("orders", (d) => {
    if (d.rid !== rid) return;
    setTickets(d.orders || []);
    if (typeof d.me === "number") setMe(d.me);
  });

  const clock = async () => {
    const cb = shift?.clockedIn ? "phone:clockOut" : "phone:clockIn";
    const res = await fetchNui(cb, { id: rid });
    if (res?.ok) {
      toast(shift?.clockedIn ? "Clocked out" : "Clocked in");
      loadShift();
    } else toast(res?.error || "Failed", "err");
  };

  const complete = async (t: any) => {
    const sig = t.fulfill?.mealOptions?.[0]?.sig;
    const res = await fetchNui("phone:completeOrder", { id: rid, orderId: t.orderId, mealSig: sig });
    if (res?.ok) {
      toast(`Ticket #${t.ticket} served`);
      setDetailId(null);
      loadTickets();
    } else toast(res?.error || "Can't complete", "err");
  };
  const cancel = async (t: any) => {
    const res = await fetchNui("phone:cancelOrder", { id: rid, orderId: t.orderId });
    if (res?.ok) {
      setDetailId(null);
      loadTickets();
    } else toast(res?.error || "Can't cancel", "err");
  };
  const acceptDelivery = async (t: any) => {
    const res = await fetchNui("phone:startDelivery", { id: rid, orderId: t.orderId });
    if (res?.ok) toast("Delivery accepted — route set");
    else toast(res?.error || "Failed", "err");
  };
  const setWaypoint = async (t: any) => {
    const res = await fetchNui("phone:setWaypoint", { id: rid, orderId: t.orderId });
    if (!res?.ok) toast(res?.error || "No delivery location saved", "err");
  };
  const cancelDelivery = async (t: any) => {
    const res = await fetchNui("phone:cancelDelivery", { id: rid, orderId: t.orderId });
    if (res?.ok) toast("Delivery cancelled");
    else toast(res?.error || "Failed", "err");
  };

  if (!rid) return <Empty title="You're not on any team" hint="Get hired at a restaurant to see the kitchen." />;

  return (
    <Screen className="pb-20">
      <TopBar
        title="Kitchen"
        subtitle={active?.label}
        right={
          <button onClick={() => go("leaderboard", { rid })} className="grid h-8 w-8 place-items-center rounded-full bg-muted">
            <Trophy className="h-4 w-4 text-warn" />
          </button>
        }
      />
      <RestaurantChips employment={employment} rid={rid} setRid={setRid} />

      {/* shift + manage */}
      <div className={cn("flex gap-2 px-4 pb-3", employment.length < 2 && "pt-3")}>
        <button
          onClick={clock}
          className={cn(
            "flex flex-1 items-center justify-center gap-2 rounded-2xl px-3 py-2.5 font-bold active:scale-[0.99]",
            shift?.clockedIn ? "bg-destructive text-destructive-foreground" : "bg-brand text-brand-ink"
          )}
        >
          {shift?.clockedIn ? <Square className="h-4 w-4" /> : <Play className="h-4 w-4" />}
          {shift?.clockedIn ? "Clock out" : "Clock in"}
        </button>
        <button onClick={() => go("staff", { rid })} className="grid place-items-center rounded-2xl bg-muted px-4">
          <Clock className="h-5 w-5" />
        </button>
        {canManage && (
          <button onClick={() => go("manage", { rid })} className="grid place-items-center rounded-2xl bg-muted px-4">
            <Settings className="h-5 w-5" />
          </button>
        )}
      </div>

      {/* queue */}
      <div className="flex items-center justify-between px-4 pb-2">
        <h2 className="font-display text-base font-bold">Ticket queue</h2>
        <span className="text-[0.72rem] text-muted-foreground">{tickets.length} open</span>
      </div>
      {tickets.length === 0 ? (
        <Empty icon={<Check className="h-8 w-8" />} title="All caught up" hint="No open tickets right now." />
      ) : (
        <div className="space-y-2 px-4">
          {tickets.map((t) => {
            const Icon = t.npc ? Bot : TYPE_ICON[t.orderType] || ShoppingBag;
            const ready = t.fulfill?.ready;
            return (
              <div
                key={t.orderId}
                className={cn("rounded-2xl border bg-card p-3", ready ? "border-ok/50" : "border-border")}
              >
                <div className="flex items-center gap-2">
                  <span className="grid h-8 w-8 place-items-center rounded-lg bg-muted">
                    <Icon className="h-4 w-4" />
                  </span>
                  <div className="flex-1">
                    <div className="font-display font-bold leading-tight">
                      #{t.ticket} <span className="text-sm font-normal text-muted-foreground">{t.customer || "Guest"}</span>
                    </div>
                    <div className="text-[0.66rem] uppercase tracking-wide text-muted-foreground">
                      {t.npc ? "Walk-in" : t.orderType || "pickup"}
                    </div>
                  </div>
                  <span className="font-mono text-sm">{money(currency, t.total)}</span>
                  <button
                    onClick={() => setDetailId(t.orderId)}
                    className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-muted text-muted-foreground active:scale-90"
                    aria-label="Ticket details"
                  >
                    <Info className="h-4 w-4" />
                  </button>
                </div>

                {/* photo strip — tap to open full details */}
                <button
                  onClick={() => setDetailId(t.orderId)}
                  className="mt-2 flex w-full items-center gap-2 text-left"
                >
                  <div className="flex flex-1 flex-wrap gap-1.5">
                    {(t.lines || []).map((l: any, i: number) => (
                      <span key={i} className="relative">
                        <ItemImg src={l.image} alt={l.label} className="h-9 w-9 rounded-lg bg-muted" />
                        {l.qty > 1 && (
                          <span className="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-brand px-1 font-mono text-[0.55rem] font-bold text-brand-ink">
                            {l.qty}
                          </span>
                        )}
                      </span>
                    ))}
                  </div>
                </button>

                <div className="mt-2 space-y-0.5 font-mono text-[0.78rem]">
                  {(t.lines || []).map((l: any, i: number) => (
                    <div key={i} className="flex justify-between text-muted-foreground">
                      <span className="text-foreground">
                        {l.qty}× {l.label}
                      </span>
                      {l.mods && l.mods.length > 0 && (
                        <span className="truncate pl-2 text-right text-[0.66rem]">
                          {l.mods.map((m: any) => (m.removed ? `no ${m.label}` : m.label)).join(", ")}
                        </span>
                      )}
                    </div>
                  ))}
                </div>

                {!ready && t.fulfill?.missing && (
                  <div className="mt-2 rounded-lg bg-warn/15 px-2 py-1 text-[0.7rem] text-warn">
                    Still cooking: {t.fulfill.missing.join(", ")}
                  </div>
                )}

                <div className="mt-2 flex gap-2">
                  <DeliveryAction
                    t={t}
                    me={me}
                    ready={ready}
                    compact
                    onAccept={() => acceptDelivery(t)}
                    onCancelDelivery={() => cancelDelivery(t)}
                    onWaypoint={() => setWaypoint(t)}
                  />
                  <button
                    disabled={!ready}
                    onClick={() => complete(t)}
                    className={cn(
                      "flex flex-1 items-center justify-center gap-1 rounded-full px-3 py-2 text-sm font-bold",
                      ready ? "bg-ok text-white" : "bg-muted text-muted-foreground"
                    )}
                  >
                    <Check className="h-4 w-4" /> {ready ? "Serve" : "Not ready"}
                  </button>
                  <button onClick={() => cancel(t)} className="grid h-9 w-9 place-items-center rounded-full bg-muted">
                    <X className="h-4 w-4" />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {detailId != null && (() => {
        const t = tickets.find((x) => x.orderId === detailId);
        if (!t) return null;
        return (
          <TicketSheet
            t={t}
            currency={currency}
            onClose={() => setDetailId(null)}
            onServe={() => complete(t)}
            onAccept={() => acceptDelivery(t)}
            onCancelDelivery={() => cancelDelivery(t)}
            onWaypoint={() => setWaypoint(t)}
            onCancel={() => cancel(t)}
            me={me}
          />
        );
      })()}
    </Screen>
  );
}

// ─── STAFF (shift + tip pool) ─────────────────────────────────────────────────
export function Staff({ params }: { params?: any }) {
  const { back, currency, toast } = usePhone();
  const rid = params?.rid;
  const [shift, setShift] = useState<any>(null);
  const [tick, setTick] = useState(0);

  const load = () => fetchNui("phone:shiftStatus", { id: rid }).then((d) => d?.ok && setShift(d));
  useEffect(() => {
    load();
    const t = setInterval(() => setTick((n) => n + 1), 1000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rid]);

  const clock = async () => {
    const cb = shift?.clockedIn ? "phone:clockOut" : "phone:clockIn";
    const res = await fetchNui(cb, { id: rid });
    if (res?.ok) {
      toast(shift?.clockedIn ? "Clocked out" : "Clocked in");
      load();
    } else toast(res?.error || "Failed", "err");
  };

  const elapsed = shift?.since ? Math.max(0, Math.floor(Date.now() / 1000) - shift.since) : 0;
  const roster: any[] = shift?.roster || [];

  return (
    <Screen className="pb-8">
      <TopBar title="My shift" onBack={back} />
      <div className="space-y-4 p-4">
        <div className="rounded-2xl border border-border bg-card p-4 text-center">
          <div className="text-[0.66rem] font-bold uppercase tracking-wider text-muted-foreground">{shift?.clockedIn ? "On the clock" : "Off duty"}</div>
          <div className="my-1 font-mono text-3xl font-extrabold tabular-nums">
            {shift?.clockedIn ? fmtDur(elapsed) : "—"}
          </div>
          <div className="text-[0.72rem] text-muted-foreground">
            Tips this shift: <span className="font-mono font-bold text-foreground">{money(currency, shift?.tips || 0)}</span>
          </div>
          <button
            onClick={clock}
            className={cn(
              "mt-3 w-full rounded-full px-4 py-3 font-bold active:scale-[0.99]",
              shift?.clockedIn ? "bg-destructive text-destructive-foreground" : "bg-brand text-brand-ink"
            )}
          >
            {shift?.clockedIn ? "Clock out" : "Clock in"}
          </button>
        </div>

        <section>
          <h2 className="mb-2 font-display text-base font-bold">Tip pool</h2>
          <p className="mb-2 text-[0.72rem] text-muted-foreground">
            Tips are split evenly across everyone on shift. Right now:
          </p>
          {roster.length === 0 ? (
            <Empty title="Nobody's clocked in" hint="Clock in to join the pool." />
          ) : (
            <div className="space-y-1.5">
              {roster.map((m, i) => (
                <div key={i} className="flex items-center justify-between rounded-xl border border-border bg-card px-3 py-2">
                  <span className="flex items-center gap-2 text-sm font-medium">
                    <Users className="h-4 w-4 text-muted-foreground" /> {m.name}
                  </span>
                  <span className="font-mono text-sm">{money(currency, m.tips || 0)}</span>
                </div>
              ))}
            </div>
          )}
        </section>
      </div>
    </Screen>
  );
}

// ─── MANAGE (owner hub) ───────────────────────────────────────────────────────
const MANAGE_TABS = [
  { id: "sales", label: "Sales", icon: TrendingUp, perm: "view_finances" },
  { id: "menu", label: "Menu", icon: Utensils, perm: "manage_menu" },
  { id: "staff", label: "Staff", icon: Users, perm: "manage_employees" },
  { id: "stock", label: "Stock", icon: Boxes, perm: "manage_stock" },
  { id: "promos", label: "Promos", icon: Megaphone, perm: "manage_menu" },
];

export function Manage({ params }: { params: any }) {
  const { back, home } = usePhone();
  const rid = params.rid;
  const emp = (home?.employment || []).find((e: any) => e.id === rid);
  const allowed = MANAGE_TABS.filter((t) => emp?.isOwner || emp?.perms?.[t.perm]);
  const [tab, setTab] = useState(allowed[0]?.id || "sales");
  const [mgmt, setMgmt] = useState<any>(null);

  const loadMgmt = () => fetchNui("phone:mgmtData", { id: rid }).then((d) => d?.ok && setMgmt(d));
  useEffect(() => {
    loadMgmt();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rid]);

  return (
    <Screen className="pb-8">
      <TopBar title="Manage" subtitle={emp?.label} onBack={back} />
      <div className="pf-rail px-4 pb-2">
        {allowed.map((t) => {
          const Icon = t.icon;
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={cn(
                "flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-sm font-semibold",
                tab === t.id ? "border-brand bg-brand text-brand-ink" : "border-border bg-card"
              )}
            >
              <Icon className="h-4 w-4" /> {t.label}
            </button>
          );
        })}
      </div>

      <div className="p-4 pt-1">
        {tab === "sales" && <SalesTab rid={rid} onChange={loadMgmt} />}
        {tab === "menu" && <MenuTab rid={rid} mgmt={mgmt} reload={loadMgmt} />}
        {tab === "staff" && <StaffTab rid={rid} mgmt={mgmt} reload={loadMgmt} />}
        {tab === "stock" && <StockTab rid={rid} mgmt={mgmt} reload={loadMgmt} />}
        {tab === "promos" && <PromosTab rid={rid} />}
      </div>
    </Screen>
  );
}

function SalesTab({ rid, onChange }: { rid: number; onChange: () => void }) {
  const { currency, toast, ask } = usePhone();
  const [a, setA] = useState<any>(null);
  const load = () => fetchNui("phone:analytics", { id: rid }).then((d) => d?.ok && setA(d));
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rid]);
  if (!a) return <Spinner />;
  const maxPeak = Math.max(1, ...a.peak.map((p: any) => p.orders));

  const bank = async (dir: "deposit" | "withdraw") => {
    const raw = await ask({
      title: dir === "deposit" ? "Deposit funds" : "Withdraw funds",
      label: `Balance: ${money(currency, a.balance)}`,
      kind: "number",
      prefix: currency,
      placeholder: "0",
      confirm: dir === "deposit" ? "Deposit" : "Withdraw",
    });
    const amount = Math.floor(Number(raw));
    if (!amount || amount <= 0) return;
    const res = await fetchNui(`phone:${dir}`, { id: rid, amount });
    if (res?.ok) {
      toast(dir === "deposit" ? "Deposited" : "Withdrawn");
      load();
      onChange();
    } else toast(res?.error || "Failed", "err");
  };

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-border bg-card p-4">
        <div className="text-[0.66rem] font-bold uppercase tracking-wider text-muted-foreground">Balance</div>
        <div className="font-mono text-3xl font-extrabold">{money(currency, a.balance)}</div>
        <div className="mt-2 flex gap-2">
          <button onClick={() => bank("deposit")} className="flex-1 rounded-full bg-muted py-2 text-sm font-bold">
            Deposit
          </button>
          <button onClick={() => bank("withdraw")} className="flex-1 rounded-full bg-brand py-2 text-sm font-bold text-brand-ink">
            Withdraw
          </button>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <Kpi label="Revenue · 30d" value={money(currency, a.revenue)} />
        <Kpi label="Tickets" value={String(a.tickets)} />
        <Kpi label="Avg ticket" value={money(currency, a.avgTicket)} />
        <Kpi label="Payroll" value={money(currency, a.payroll)} />
      </div>

      <section>
        <h3 className="mb-2 font-display font-bold">Peak hours</h3>
        <div className="flex h-24 items-end gap-0.5 rounded-2xl border border-border bg-card p-2">
          {a.peak.map((p: any) => (
            <div key={p.hour} className="flex flex-1 flex-col items-center gap-1">
              <div
                className="w-full rounded-sm bg-brand"
                style={{ height: `${(p.orders / maxPeak) * 100}%`, minHeight: p.orders ? 3 : 0 }}
                title={`${p.hour}:00 — ${p.orders}`}
              />
            </div>
          ))}
        </div>
        <div className="mt-1 flex justify-between text-[0.6rem] text-muted-foreground">
          <span>12a</span>
          <span>6a</span>
          <span>12p</span>
          <span>6p</span>
          <span>11p</span>
        </div>
      </section>

      <section>
        <h3 className="mb-2 font-display font-bold">Best sellers</h3>
        {a.bestSellers.length === 0 ? (
          <div className="text-[0.72rem] text-muted-foreground">No sales yet.</div>
        ) : (
          <div className="space-y-1.5">
            {a.bestSellers.map((s: any, i: number) => (
              <div key={i} className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2">
                <span className="font-mono text-sm text-muted-foreground">{i + 1}</span>
                <span className="flex-1 text-sm font-medium">{s.label}</span>
                <span className="font-mono text-sm">{s.qty} sold</span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function Kpi({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-border bg-card p-3">
      <div className="text-[0.62rem] uppercase tracking-wide text-muted-foreground">{label}</div>
      <div className="font-mono text-lg font-bold">{value}</div>
    </div>
  );
}

function MenuTab({ rid, mgmt, reload }: { rid: number; mgmt: any; reload: () => void }) {
  const { currency, toast, ask } = usePhone();
  if (!mgmt) return <Spinner />;
  const items: any[] = mgmt.priceList || [];

  const toggle = async (it: any) => {
    const res = await fetchNui("phone:saveMenuItem", { id: rid, key: it.key, price: it.price, enabled: !it.enabled });
    if (res?.ok) reload();
    else toast(res?.error || "Failed", "err");
  };
  const reprice = async (it: any) => {
    const raw = await ask({
      title: `Price · ${it.label}`,
      label: "Set the menu price for this item.",
      kind: "number",
      prefix: currency,
      initial: it.price,
      confirm: "Save price",
    });
    const price = Math.floor(Number(raw));
    if (!price || price <= 0) return;
    const res = await fetchNui("phone:saveMenuItem", { id: rid, key: it.key, price, enabled: it.enabled });
    if (res?.ok) reload();
    else toast(res?.error || "Failed", "err");
  };

  return (
    <div className="space-y-1.5">
      {items.length === 0 && <Empty title="No priced items" hint="Prices are set in the in-world admin panel." />}
      {items.map((it) => (
        <div key={it.key} className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2">
          <div className="min-w-0 flex-1">
            <div className="truncate text-sm font-semibold">{it.label}</div>
            <button onClick={() => reprice(it)} className="font-mono text-[0.72rem] text-primary">
              {money(currency, it.price)} · edit
            </button>
          </div>
          <button
            onClick={() => toggle(it)}
            className={cn(
              "rounded-full px-2.5 py-1 text-[0.68rem] font-bold",
              it.enabled ? "bg-ok/20 text-ok" : "bg-muted text-muted-foreground"
            )}
          >
            {it.enabled ? "Available" : "Sold out"}
          </button>
        </div>
      ))}
    </div>
  );
}

function StaffTab({ rid, mgmt, reload }: { rid: number; mgmt: any; reload: () => void }) {
  const { toast } = usePhone();
  if (!mgmt) return <Spinner />;
  const employees: any[] = mgmt.employees || [];
  const nearby: any[] = mgmt.nearby || [];
  const roles: any[] = mgmt.roles || [];

  const hire = async (p: any) => {
    const res = await fetchNui("phone:hire", { id: rid, target: p.id, grade: 0 });
    if (res?.ok) {
      toast(`Hired ${p.name}`);
      reload();
    } else toast(res?.error || "Failed", "err");
  };
  const fire = async (e: any) => {
    const res = await fetchNui("phone:fire", { id: rid, identifier: e.identifier });
    if (res?.ok) reload();
    else toast(res?.error || "Failed", "err");
  };
  const setGrade = async (e: any, grade: number) => {
    await fetchNui("phone:setGrade", { id: rid, identifier: e.identifier, grade });
    reload();
  };

  return (
    <div className="space-y-4">
      <section>
        <h3 className="mb-2 font-display font-bold">Team</h3>
        {employees.length === 0 ? (
          <div className="text-[0.72rem] text-muted-foreground">No employees yet.</div>
        ) : (
          <div className="space-y-1.5">
            {employees.map((e) => (
              <div key={e.identifier} className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2">
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-semibold">{e.name}</div>
                  <div className="text-[0.7rem] text-muted-foreground">
                    {e.gradeLabel} · {e.commission}% commission
                  </div>
                </div>
                <select
                  value={e.grade}
                  onChange={(ev) => setGrade(e, Number(ev.target.value))}
                  className="rounded-lg border border-border bg-background px-1 py-1 text-xs"
                >
                  {roles.map((r) => (
                    <option key={r.grade} value={r.grade}>
                      {r.label}
                    </option>
                  ))}
                </select>
                <button onClick={() => fire(e)} className="grid h-8 w-8 place-items-center rounded-full bg-muted text-destructive">
                  <Trash2 className="h-4 w-4" />
                </button>
              </div>
            ))}
          </div>
        )}
      </section>

      <section>
        <h3 className="mb-2 font-display font-bold">Hire nearby</h3>
        {nearby.length === 0 ? (
          <div className="text-[0.72rem] text-muted-foreground">Nobody's standing near you.</div>
        ) : (
          <div className="space-y-1.5">
            {nearby.map((p) => (
              <button
                key={p.id}
                onClick={() => hire(p)}
                className="flex w-full items-center gap-2 rounded-xl border border-border bg-card px-3 py-2 text-left active:scale-[0.99]"
              >
                <UserPlus className="h-4 w-4 text-primary" />
                <span className="flex-1 text-sm font-medium">{p.name}</span>
                <span className="text-[0.7rem] font-bold text-primary">Hire</span>
              </button>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function StockTab({ rid, mgmt, reload }: { rid: number; mgmt: any; reload: () => void }) {
  const { currency, toast } = usePhone();
  const [qty, setQty] = useState<Record<string, number>>({});
  if (!mgmt) return <Spinner />;
  const supplies: any[] = mgmt.supplies || [];

  const buy = async (s: any) => {
    const q = qty[s.item] || 10;
    const res = await fetchNui("phone:buyStock", { id: rid, item: s.item, qty: q });
    if (res?.ok) {
      toast(`Bought ${q}× ${s.label}`);
      reload();
    } else toast(res?.error || "Failed", "err");
  };

  return (
    <div className="space-y-1.5">
      {supplies.length === 0 && <Empty title="No supplies configured" />}
      {supplies.map((s) => {
        const q = qty[s.item] || 10;
        const low = (s.stock || 0) < 10;
        return (
          <div key={s.item} className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2">
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-semibold">{s.label}</div>
              <div className="text-[0.7rem]">
                <span className={cn("font-mono", low ? "text-warn" : "text-muted-foreground")}>
                  {s.stock} in stock{low && " · low"}
                </span>
                <span className="text-muted-foreground"> · {money(currency, s.cost)}/ea</span>
              </div>
            </div>
            <div className="flex items-center gap-1 rounded-full border border-border px-1">
              <button onClick={() => setQty((m) => ({ ...m, [s.item]: Math.max(1, q - 5) }))}>
                <Minus className="h-3.5 w-3.5" />
              </button>
              <span className="w-6 text-center font-mono text-xs">{q}</span>
              <button onClick={() => setQty((m) => ({ ...m, [s.item]: q + 5 }))}>
                <Plus className="h-3.5 w-3.5" />
              </button>
            </div>
            <button onClick={() => buy(s)} className="rounded-full bg-brand px-2.5 py-1.5 text-[0.7rem] font-bold text-brand-ink">
              Buy
            </button>
          </div>
        );
      })}
    </div>
  );
}

function PromosTab({ rid }: { rid: number }) {
  const { toast } = usePhone();
  const [promos, setPromos] = useState<any[]>([]);
  const [label, setLabel] = useState("");
  const [percent, setPercent] = useState(15);
  const [kind, setKind] = useState<"discount" | "happy_hour">("discount");

  const load = () => fetchNui("phone:promos", { id: rid }).then((d) => d?.ok && setPromos(d.promos || []));
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rid]);

  const save = async () => {
    if (!label.trim()) return toast("Give it a name", "err");
    const res = await fetchNui("phone:savePromo", { id: rid, label, percent, kind, active: true });
    if (res?.ok) {
      toast("Promo pushed to everyone");
      setLabel("");
      load();
    } else toast(res?.error || "Failed", "err");
  };
  const del = async (p: any) => {
    await fetchNui("phone:deletePromo", { id: rid, promoId: p.id });
    load();
  };
  const toggle = async (p: any) => {
    await fetchNui("phone:savePromo", { id: rid, promoId: p.id, label: p.label, percent: p.percent, kind: p.kind, active: !p.active });
    load();
  };

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-border bg-card p-3">
        <div className="mb-2 text-[0.66rem] font-bold uppercase tracking-wider text-muted-foreground">New promotion</div>
        <input
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          placeholder="e.g. Happy Hour"
          className="mb-2 w-full rounded-xl border border-border bg-background px-3 py-2 text-sm outline-none"
        />
        <div className="mb-2 flex gap-2">
          {(["discount", "happy_hour"] as const).map((k) => (
            <button
              key={k}
              onClick={() => setKind(k)}
              className={cn(
                "flex-1 rounded-full py-1.5 text-[0.72rem] font-bold capitalize",
                kind === k ? "bg-brand text-brand-ink" : "bg-muted text-muted-foreground"
              )}
            >
              {k.replace("_", " ")}
            </button>
          ))}
        </div>
        <div className="mb-2 flex items-center gap-2">
          <input
            type="range"
            min={5}
            max={60}
            step={5}
            value={percent}
            onChange={(e) => setPercent(Number(e.target.value))}
            className="flex-1 accent-[rgb(var(--brand))]"
          />
          <span className="w-12 text-right font-mono font-bold">{percent}%</span>
        </div>
        <button onClick={save} className="flex w-full items-center justify-center gap-1 rounded-full bg-brand py-2.5 font-bold text-brand-ink">
          <Megaphone className="h-4 w-4" /> Push promotion
        </button>
      </div>

      <div className="space-y-1.5">
        {promos.map((p) => (
          <div key={p.id} className="flex items-center gap-2 rounded-xl border border-border bg-card px-3 py-2">
            <div className="flex-1">
              <div className="text-sm font-semibold">{p.label}</div>
              <div className="text-[0.7rem] text-muted-foreground">
                {p.percent}% off · {String(p.kind).replace("_", " ")}
              </div>
            </div>
            <button
              onClick={() => toggle(p)}
              className={cn(
                "rounded-full px-2.5 py-1 text-[0.68rem] font-bold",
                p.active ? "bg-ok/20 text-ok" : "bg-muted text-muted-foreground"
              )}
            >
              {p.active ? "Live" : "Off"}
            </button>
            <button onClick={() => del(p)} className="grid h-8 w-8 place-items-center rounded-full bg-muted text-destructive">
              <Trash2 className="h-4 w-4" />
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
