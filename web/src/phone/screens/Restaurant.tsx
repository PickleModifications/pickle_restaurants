import { useEffect, useMemo, useState } from "react";
import {
  Plus,
  Minus,
  Star,
  Heart,
  Truck,
  ShoppingBag,
  Utensils,
  Clock,
  Ticket,
  ChevronRight,
} from "lucide-react";
import { fetchNui } from "../../lib/nui";
import { applyTheme } from "../../lib/theme";
import { cn } from "../../lib/utils";
import { usePhone, money, CatalogItem, Mod } from "../store";
import { Screen, TopBar, Spinner, ItemImg, Rating, PromoTag, PunchCard, Empty } from "../ui";

// ─── modifier selection model ─────────────────────────────────────────────────
type ModState = Record<string, boolean>;

function groupMods(mods: Mod[] = []) {
  const groups: Record<string, Mod[]> = {};
  for (const m of mods) {
    const g = m.group || "__addons";
    (groups[g] = groups[g] || []).push(m);
  }
  return groups;
}

function defaultModState(item: CatalogItem): ModState {
  const st: ModState = {};
  const groups = groupMods(item.modifiers);
  for (const [g, list] of Object.entries(groups)) {
    if (g === "__addons") {
      list.forEach((m) => (st[m.id] = !!m.default));
    } else {
      const pick = list.find((m) => m.default) || list[0];
      if (pick) st[pick.id] = true;
    }
  }
  return st;
}

function priceOf(item: CatalogItem, st: ModState) {
  let p = item.price;
  for (const m of item.modifiers || []) if (st[m.id]) p += m.price || 0;
  return p;
}

// ─── item options sheet ───────────────────────────────────────────────────────
function ItemSheet({
  item,
  onClose,
  onAdd,
}: {
  item: CatalogItem;
  onClose: () => void;
  onAdd: (qty: number, st: ModState) => void;
}) {
  const { currency } = usePhone();
  const [st, setSt] = useState<ModState>(() => defaultModState(item));
  const [qty, setQty] = useState(1);
  const groups = useMemo(() => groupMods(item.modifiers), [item]);
  const unit = priceOf(item, st);

  const pickRadio = (list: Mod[], id: string) =>
    setSt((s) => {
      const next = { ...s };
      list.forEach((m) => (next[m.id] = m.id === id));
      return next;
    });

  return (
    <>
      <div className="pf-scrim" onClick={onClose} />
      <div className="pf-sheet">
        <div className="pf-grab" />
        <div className="max-h-[70vh] overflow-y-auto px-4 pb-2">
          <div className="flex gap-3 pt-1">
            <ItemImg src={item.image} className="h-16 w-16 rounded-xl" />
            <div className="min-w-0 flex-1">
              <div className="font-display text-lg font-extrabold leading-tight">{item.label}</div>
              <div className="font-mono text-sm text-muted-foreground">
                {money(currency, item.price)}
              </div>
            </div>
          </div>

          {Object.entries(groups).map(([g, list]) => {
            const isAddon = g === "__addons";
            return (
              <div key={g} className="mt-4">
                <div className="tape mb-1.5 text-muted-foreground">
                  {isAddon ? "Add-ons" : (list[0]?.group || "Choose one")}
                </div>
                <div className="space-y-1.5">
                  {list.map((m) => {
                    const on = !!st[m.id];
                    return (
                      <button
                        key={m.id}
                        onClick={() =>
                          isAddon
                            ? setSt((s) => ({ ...s, [m.id]: !s[m.id] }))
                            : pickRadio(list, m.id)
                        }
                        className={cn(
                          "flex w-full items-center gap-2 rounded-xl border px-3 py-2 text-left active:scale-[0.99]",
                          on ? "border-brand bg-brand/10" : "border-border bg-card"
                        )}
                      >
                        <span
                          className={cn(
                            "grid h-5 w-5 place-items-center rounded-full border-2",
                            isAddon ? "rounded-md" : "rounded-full",
                            on ? "border-brand bg-brand text-brand-ink" : "border-border"
                          )}
                        >
                          {on && <Star className="h-3 w-3" fill="currentColor" />}
                        </span>
                        <span className="flex-1 text-sm font-medium">{m.label}</span>
                        {m.price ? (
                          <span className="font-mono text-xs text-muted-foreground">
                            +{money(currency, m.price)}
                          </span>
                        ) : null}
                      </button>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>

        <div className="flex items-center gap-3 border-t border-border p-3">
          <div className="flex items-center gap-3 rounded-full border border-border px-2 py-1">
            <button onClick={() => setQty((q) => Math.max(1, q - 1))} className="p-1">
              <Minus className="h-4 w-4" />
            </button>
            <span className="w-5 text-center font-mono font-bold">{qty}</span>
            <button onClick={() => setQty((q) => Math.min(10, q + 1))} className="p-1">
              <Plus className="h-4 w-4" />
            </button>
          </div>
          <button
            onClick={() => onAdd(qty, st)}
            className="flex flex-1 items-center justify-between rounded-full bg-brand px-4 py-2.5 font-bold text-brand-ink active:scale-[0.99]"
          >
            <span>Add to cart</span>
            <span className="font-mono">{money(currency, unit * qty)}</span>
          </button>
        </div>
      </div>
    </>
  );
}

// ─── combo sheet ──────────────────────────────────────────────────────────────
function ComboSheet({ combo, onClose, onAdd }: { combo: any; onClose: () => void; onAdd: (picks: any[]) => void }) {
  const { currency } = usePhone();
  const [picks, setPicks] = useState<Record<number, string>>(() => {
    const p: Record<number, string> = {};
    combo.slots.forEach((s: any, i: number) => (p[i] = s.options[0]?.key));
    return p;
  });
  return (
    <>
      <div className="pf-scrim" onClick={onClose} />
      <div className="pf-sheet">
        <div className="pf-grab" />
        <div className="max-h-[70vh] overflow-y-auto px-4 pb-2 pt-1">
          <div className="font-display text-lg font-extrabold">{combo.label}</div>
          <div className="font-mono text-sm text-muted-foreground">{money(currency, combo.price)}</div>
          {combo.slots.map((slot: any, i: number) => (
            <div key={i} className="mt-4">
              <div className="tape mb-1.5 text-muted-foreground">{slot.label || `Pick ${i + 1}`}</div>
              <div className="space-y-1.5">
                {slot.options.map((o: any) => {
                  const on = picks[i] === o.key;
                  return (
                    <button
                      key={o.key}
                      onClick={() => setPicks((p) => ({ ...p, [i]: o.key }))}
                      className={cn(
                        "flex w-full items-center gap-2 rounded-xl border px-3 py-2 text-left",
                        on ? "border-brand bg-brand/10" : "border-border bg-card"
                      )}
                    >
                      <ItemImg src={o.image} className="h-8 w-8 rounded-lg" />
                      <span className="flex-1 text-sm font-medium">{o.label}</span>
                      {on && <Star className="h-4 w-4 text-brand" fill="currentColor" />}
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
        <div className="border-t border-border p-3">
          <button
            onClick={() => onAdd(combo.slots.map((_: any, i: number) => ({ key: picks[i] })))}
            className="flex w-full items-center justify-between rounded-full bg-brand px-4 py-2.5 font-bold text-brand-ink"
          >
            <span>Add combo</span>
            <span className="font-mono">{money(currency, combo.price)}</span>
          </button>
        </div>
      </div>
    </>
  );
}

// ─── storefront ───────────────────────────────────────────────────────────────
export function Restaurant({ params }: { params: any }) {
  const { back, addToCart, currency, go, refreshHome } = usePhone();
  const rid = params.rid;
  const [data, setData] = useState<any>(null);
  const [sheet, setSheet] = useState<{ item?: CatalogItem; combo?: any } | null>(null);

  useEffect(() => {
    let live = true;
    fetchNui("phone:menu", { id: rid }).then((d) => {
      if (!live) return;
      if (d?.ok) {
        setData(d);
        applyTheme(d.theme);
      }
    });
    return () => {
      live = false;
      applyTheme(null);
    };
  }, [rid]);

  // Reorder: seed the cart from a saved favorite (best-effort by key match).
  useEffect(() => {
    if (data && params.reorder?.cart) {
      const byKey: Record<string, CatalogItem> = {};
      (data.catalog || []).forEach((c: CatalogItem) => (byKey[c.key] = c));
      params.reorder.cart.forEach((e: any) => {
        const it = byKey[e.key];
        if (it) {
          const st: ModState = {};
          (e.mods || []).forEach((id: string) => (st[id] = true));
          addLine(it, e.qty || 1, st);
        }
      });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data]);

  const addLine = (item: CatalogItem, qty: number, st: ModState) => {
    const mods = (item.modifiers || []).filter((m) => st[m.id]).map((m) => m.id);
    const modLabels = (item.modifiers || []).filter((m) => st[m.id]).map((m) => m.label);
    addToCart(rid, data.label, {
      key: item.key,
      label: item.label,
      image: item.image,
      price: priceOf(item, st),
      qty,
      mods,
      modLabels,
    });
  };

  if (!data) return <Spinner />;

  const groups: Record<string, CatalogItem[]> = {};
  (data.catalog || []).forEach((c: CatalogItem) => {
    const g = c.kind === "drink" ? "Drinks" : "Menu";
    (groups[g] = groups[g] || []).push(c);
  });

  return (
    <Screen className="pb-24">
      <div className="relative h-40 w-full bg-muted">
        <ItemImg src={data.brand} className="h-full w-full" />
        <div className="absolute inset-0 bg-gradient-to-t from-black/70 via-black/10 to-black/30" />
        <div className="absolute inset-x-0 top-0">
          <TopBar transparent onBack={back} right={<span className="w-8" />} />
        </div>
        <div className="absolute bottom-3 left-4 right-4 text-white">
          <h1 className="font-display text-2xl font-extrabold drop-shadow">{data.label}</h1>
          <div className="mt-1 flex items-center gap-3">
            <Rating value={data.rating} count={data.reviewCount} />
            {data.promo && <PromoTag label={`${data.promo.percent}% off`} />}
          </div>
        </div>
      </div>

      {/* loyalty strip */}
      {data.loyalty?.on && (
        <div className="mx-4 mt-3 rounded-2xl border border-border bg-card p-3">
          <div className="mb-2 flex items-center justify-between">
            <span className="tape text-muted-foreground">Punch card</span>
            <span className="text-[0.72rem] text-muted-foreground">
              {data.loyalty.punches % data.loyalty.goal}/{data.loyalty.goal} to a free item
            </span>
          </div>
          <PunchCard punches={data.loyalty.punches} goal={data.loyalty.goal} />
        </div>
      )}

      {/* combos */}
      {(data.combos?.length || 0) > 0 && (
        <section className="mt-4">
          <h2 className="mb-2 px-4 font-display text-base font-bold">Combos</h2>
          <div className="space-y-2 px-4">
            {data.combos.map((cb: any) => (
              <button
                key={cb.comboId}
                onClick={() => setSheet({ combo: cb })}
                className="flex w-full items-center gap-3 rounded-2xl border border-border bg-card p-2.5 text-left active:scale-[0.99]"
              >
                <ItemImg src={cb.photo?.url} className="h-16 w-16 rounded-xl" />
                <div className="min-w-0 flex-1">
                  <div className="font-semibold leading-tight">
                    #{cb.number} {cb.label}
                  </div>
                  <div className="text-[0.72rem] text-muted-foreground">
                    {cb.slots.length}-item combo
                  </div>
                  <div className="mt-1 font-mono text-sm font-bold text-primary">
                    {money(currency, cb.price)}
                  </div>
                </div>
                <ChevronRight className="h-5 w-5 text-muted-foreground" />
              </button>
            ))}
          </div>
        </section>
      )}

      {/* menu sections */}
      {Object.entries(groups).map(([g, list]) => (
        <section key={g} className="mt-4">
          <h2 className="mb-2 px-4 font-display text-base font-bold">{g}</h2>
          <div className="divide-y divide-border">
            {list.map((it) => (
              <button
                key={it.key}
                onClick={() => setSheet({ item: it })}
                className="flex w-full items-center gap-3 px-4 py-2.5 text-left active:bg-muted/40"
              >
                <ItemImg src={it.image} className="h-16 w-16 rounded-xl" />
                <div className="min-w-0 flex-1">
                  <div className="font-semibold leading-tight">{it.label}</div>
                  <div className="mt-1 font-mono text-sm text-muted-foreground">
                    {money(currency, it.price)}
                  </div>
                </div>
                <span className="grid h-8 w-8 place-items-center rounded-full bg-brand text-brand-ink">
                  <Plus className="h-4 w-4" strokeWidth={3} />
                </span>
              </button>
            ))}
          </div>
        </section>
      ))}

      {(data.catalog?.length || 0) === 0 && (
        <Empty title="Menu coming soon" hint="This restaurant hasn't priced any items yet." />
      )}

      {sheet?.item && (
        <ItemSheet
          item={sheet.item}
          onClose={() => setSheet(null)}
          onAdd={(qty, st) => {
            addLine(sheet.item!, qty, st);
            setSheet(null);
          }}
        />
      )}
      {sheet?.combo && (
        <ComboSheet
          combo={sheet.combo}
          onClose={() => setSheet(null)}
          onAdd={(picks) => {
            addToCart(rid, data.label, {
              key: "combo:" + sheet.combo.comboId,
              label: `#${sheet.combo.number} ${sheet.combo.label}`,
              image: sheet.combo.photo?.url,
              price: sheet.combo.price,
              qty: 1,
              mods: [],
              modLabels: [],
              combo: { comboId: sheet.combo.comboId, slots: picks },
            });
            setSheet(null);
          }}
        />
      )}
    </Screen>
  );
}

// ─── checkout ─────────────────────────────────────────────────────────────────
const TYPES = [
  { id: "delivery", label: "Delivery", icon: Truck },
  { id: "pickup", label: "Pickup", icon: ShoppingBag },
  { id: "dine_in", label: "Dine-in", icon: Utensils },
];
const SCHED = [
  { id: "", label: "ASAP" },
  { id: "+15", label: "In 15 min" },
  { id: "+30", label: "In 30 min" },
  { id: "+60", label: "In 1 hr" },
];

export function Checkout({ params }: { params: any }) {
  const { cart, setQty, clearCart, currency, back, go, refreshHome, toast } = usePhone();
  const [type, setType] = useState("delivery");
  const [sched, setSched] = useState("");
  const [redeem, setRedeem] = useState(false);
  const [placing, setPlacing] = useState(false);
  const [menu, setMenu] = useState<any>(null);

  useEffect(() => {
    if (cart)
      fetchNui("phone:menu", { id: cart.rid }).then((d) => {
        if (d?.ok) {
          setMenu(d);
          applyTheme(d.theme);
        }
      });
    return () => applyTheme(null);
  }, [cart?.rid]);

  const subtotal = cart ? cart.lines.reduce((n, l) => n + l.price * l.qty, 0) : 0;
  const promoPct = menu?.promo?.percent || 0;
  const canRedeem = menu?.loyalty?.on && (menu?.loyalty?.punches || 0) >= (menu?.loyalty?.goal || 999);
  const cheapest = cart?.lines.length ? Math.min(...cart.lines.map((l) => l.price)) : 0;
  const redeemOff = redeem && canRedeem ? cheapest : 0;
  const total = Math.max(0, Math.round((subtotal - redeemOff) * (100 - promoPct)) / 100);

  if (!cart) {
    return (
      <Screen>
        <TopBar title="Checkout" onBack={back} />
        <Empty icon={<ShoppingBag className="h-8 w-8" />} title="Your cart is empty" hint="Add something tasty first." />
      </Screen>
    );
  }

  const place = async () => {
    setPlacing(true);
    const serverCart = cart.lines.map((l) =>
      l.combo ? { combo: l.combo.comboId, qty: l.qty, slots: l.combo.slots } : { key: l.key, qty: l.qty, mods: l.mods }
    );
    const res = await fetchNui("phone:placeOrder", {
      id: cart.rid,
      cart: serverCart,
      orderType: type,
      scheduled: sched || null,
      redeem: redeem && canRedeem,
    });
    setPlacing(false);
    if (res?.ok) {
      toast(`Order placed — ticket #${res.ticket}`);
      clearCart();
      await refreshHome();
      go("order", { orderId: res.orderId, rid: cart.rid });
    } else {
      toast(res?.error || "Couldn't place the order", "err");
    }
  };

  const saveFav = async () => {
    const serverCart = cart.lines.map((l) =>
      l.combo ? { combo: l.combo.comboId, qty: l.qty, slots: l.combo.slots, key: l.key } : { key: l.key, qty: l.qty, mods: l.mods }
    );
    const res = await fetchNui("phone:saveFavorite", { id: cart.rid, label: cart.label, cart: serverCart });
    if (res?.ok) {
      toast("Saved to Order again");
      refreshHome();
    } else toast(res?.error || "Couldn't save", "err");
  };

  return (
    <Screen className="pb-4">
      <TopBar
        title="Checkout"
        subtitle={cart.label}
        onBack={back}
        right={
          <button onClick={saveFav} className="grid h-8 w-8 place-items-center rounded-full bg-muted" title="Save for later">
            <Heart className="h-4 w-4" />
          </button>
        }
      />
      <div className="space-y-4 p-4">
        {/* type */}
        <div>
          <div className="tape mb-1.5 text-muted-foreground">How do you want it</div>
          <div className="grid grid-cols-3 gap-2">
            {TYPES.map((t) => {
              const Icon = t.icon;
              return (
                <button
                  key={t.id}
                  onClick={() => setType(t.id)}
                  className={cn(
                    "flex flex-col items-center gap-1 rounded-2xl border py-3 active:scale-[0.98]",
                    type === t.id ? "border-brand bg-brand/10 text-primary" : "border-border bg-card"
                  )}
                >
                  <Icon className="h-5 w-5" />
                  <span className="text-[0.72rem] font-semibold">{t.label}</span>
                </button>
              );
            })}
          </div>
        </div>

        {/* schedule */}
        <div>
          <div className="tape mb-1.5 flex items-center gap-1 text-muted-foreground">
            <Clock className="h-3 w-3" /> When
          </div>
          <div className="pf-rail">
            {SCHED.map((s) => (
              <button
                key={s.id}
                onClick={() => setSched(s.id)}
                className={cn(
                  "rounded-full border px-3 py-1.5 text-[0.76rem] font-semibold",
                  sched === s.id ? "border-brand bg-brand text-brand-ink" : "border-border bg-card"
                )}
              >
                {s.label}
              </button>
            ))}
          </div>
          <p className="mt-1 text-[0.68rem] text-muted-foreground">
            Order-ahead queues your food in the kitchen so it's ready when you arrive.
          </p>
        </div>

        {/* lines */}
        <div className="rounded-2xl border border-border bg-card">
          {cart.lines.map((l) => (
            <div key={l.uid} className="flex items-center gap-3 border-b border-border px-3 py-2.5 last:border-0">
              <ItemImg src={l.image} className="h-11 w-11 rounded-lg" />
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-semibold">{l.label}</div>
                {l.modLabels.length > 0 && (
                  <div className="truncate text-[0.68rem] text-muted-foreground">
                    {l.modLabels.join(" · ")}
                  </div>
                )}
              </div>
              <div className="flex items-center gap-2 rounded-full border border-border px-1.5 py-0.5">
                <button onClick={() => setQty(l.uid, l.qty - 1)}>
                  <Minus className="h-3.5 w-3.5" />
                </button>
                <span className="w-4 text-center font-mono text-sm">{l.qty}</span>
                <button onClick={() => setQty(l.uid, Math.min(10, l.qty + 1))}>
                  <Plus className="h-3.5 w-3.5" />
                </button>
              </div>
              <div className="w-14 text-right font-mono text-sm">{money(currency, l.price * l.qty)}</div>
            </div>
          ))}
        </div>

        {/* loyalty redeem */}
        {canRedeem && (
          <button
            onClick={() => setRedeem((v) => !v)}
            className={cn(
              "flex w-full items-center gap-3 rounded-2xl border p-3 text-left active:scale-[0.99]",
              redeem ? "border-brand bg-brand/10" : "border-border bg-card"
            )}
          >
            <Ticket className={cn("h-5 w-5", redeem ? "text-primary" : "text-muted-foreground")} />
            <div className="flex-1">
              <div className="text-sm font-semibold">Redeem a free item</div>
              <div className="text-[0.7rem] text-muted-foreground">
                You've earned it — takes the cheapest item off this order.
              </div>
            </div>
            <span
              className={cn(
                "h-5 w-9 rounded-full p-0.5 transition-colors",
                redeem ? "bg-brand" : "bg-muted"
              )}
            >
              <span className={cn("block h-4 w-4 rounded-full bg-white transition-transform", redeem && "translate-x-4")} />
            </span>
          </button>
        )}

        {/* totals */}
        <div className="space-y-1 rounded-2xl border border-border bg-card p-3 font-mono text-sm">
          <Row label="Subtotal" value={money(currency, subtotal)} />
          {promoPct > 0 && <Row label={`Promo (${promoPct}%)`} value={`-${money(currency, subtotal * promoPct / 100)}`} accent />}
          {redeemOff > 0 && <Row label="Free item" value={`-${money(currency, redeemOff)}`} accent />}
          <div className="my-1 border-t border-border" />
          <Row label="Total" value={money(currency, total)} big />
        </div>
      </div>

      <div className="px-4">
        <button
          disabled={placing}
          onClick={place}
          className="flex w-full items-center justify-center gap-2 rounded-full bg-brand px-4 py-3.5 font-bold text-brand-ink active:scale-[0.99] disabled:opacity-60"
        >
          {placing ? "Placing…" : `Place order · ${money(currency, total)}`}
        </button>
      </div>
    </Screen>
  );
}

function Row({ label, value, big, accent }: { label: string; value: string; big?: boolean; accent?: boolean }) {
  return (
    <div className={cn("flex justify-between", big && "text-base font-bold")}>
      <span className={cn(!big && "text-muted-foreground", accent && "text-primary")}>{label}</span>
      <span className={accent ? "text-primary" : ""}>{value}</span>
    </div>
  );
}
