import { useEffect, useRef, useState } from "react";
import { fetchNui, setPeek } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Field, TextField, NumberField, Toggle } from "@/components/form";
import { type Item } from "@/components/ItemPicker";
import Branding, { ThemeEditor, NameEditor } from "@/components/Branding";
import Thumb from "@/components/Thumb";
import { money, cn, prettyItem } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { UserPlus, Trash2, Pencil, Plus, Minus, MapPin, Banknote, Armchair, Receipt, PackagePlus, ArrowDownToLine, ArrowUpFromLine, Sparkles, Users, Play, Square, Monitor, UtensilsCrossed, TriangleAlert, ScrollText } from "lucide-react";

// NOTE: station / counter / seat PLACEMENT is deliberately not in this panel — it
// is an admin-only job now (the admin panel's restaurant detail), and the placement
// callbacks are gated on admin server-side. The boss panel keeps Branding, which is
// what `manage_props` still means here.

export default function Management({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const perms = data?.perms || {};
  const roles: any[] = data?.roles || [];
  const items: Item[] = data?.items || [];
  const initialTab = firstTab(perms);

  // The panel header follows a live rename (the rename save deliberately does NOT
  // refresh the panel — that would remount the field mid-typing), so keep the
  // label in local state seeded from the payload.
  const [label, setLabel] = useState<string>(data?.restaurant?.label || "");
  useEffect(() => { setLabel(data?.restaurant?.label || ""); }, [data?.restaurant?.label]);

  return (
    <Panel title={label || _L("mgmt.title")} subtitle={_L("mgmt.balance", money(data?.restaurant?.balance))} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue={initialTab} className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          {/* Ungated: the dashboard is the shift clock + the state of the room, which
              every employee working a register needs, not a management privilege. */}
          <TabsTrigger value="dashboard">{_L("mgmt.tab_dashboard")}</TabsTrigger>
          {perms.manage_employees && <TabsTrigger value="employees">{_L("mgmt.tab_employees")}</TabsTrigger>}
          {perms.manage_menu && <TabsTrigger value="menu">{_L("mgmt.tab_menu")}</TabsTrigger>}
          {perms.manage_stock && <TabsTrigger value="supplies">{_L("mgmt.tab_supplies")}</TabsTrigger>}
          {perms.view_finances && <TabsTrigger value="finances">{_L("mgmt.tab_finances")}</TabsTrigger>}
          {perms.manage_props && <TabsTrigger value="branding">{_L("mgmt.tab_branding")}</TabsTrigger>}
        </TabsList>

        <TabsContent value="dashboard" className="min-h-0 flex-1 overflow-y-auto pr-1 pb-4">
          <Dashboard id={id} dash={data?.dashboard} perms={perms} balance={data?.restaurant?.balance} />
        </TabsContent>
        {perms.manage_employees && (
          <TabsContent value="employees" className="min-h-0 flex-1 overflow-y-auto pr-1 pb-4">
            <Employees id={id} roles={roles} employees={data?.employees || []} nearby={data?.nearby || []} />
          </TabsContent>
        )}
        {perms.manage_menu && (
          <TabsContent value="menu" className="min-h-0 flex-1 overflow-y-auto pr-1 pb-4">
            <Menu id={id} priceList={data?.priceList || []} stale={data?.stale || []} />
          </TabsContent>
        )}
        {perms.manage_stock && (
          <TabsContent value="supplies" className="min-h-0 flex-1 overflow-y-auto pr-1 pb-4">
            <Supplies id={id} supplies={data?.supplies || []} />
          </TabsContent>
        )}
        {perms.view_finances && (
          <TabsContent value="finances" className="min-h-0 flex-1 overflow-y-auto pr-1 pb-4">
            <Finances id={id} balance={data?.restaurant?.balance} ledger={data?.ledger || []} canManage={!!perms.manage_balance} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="branding" className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1 pb-4">
            {/* Renaming the business is OWNER-only (server gates on ResolvePerms'
                isOwner) — a shift lead with manage_props can restyle the place but
                not rename it, so the card is hidden for staff. */}
            {data?.isOwner && (
              <NameEditor id={id} label={data?.restaurant?.label || ""} event="management:setName" onChange={setLabel} />
            )}
            <ThemeEditor id={id} theme={data?.restaurant?.theme} event="management:setTheme" />
            <Branding id={id} brand={data?.restaurant?.brand_image || ""} brandImages={data?.restaurant?.brand_images || {}} phoneImage={data?.restaurant?.phone_image || ""} event="management:setBrandImage" renderTargets={data?.renderTargets} />
          </TabsContent>
        )}
      </Tabs>
    </Panel>
  );
}

// The Dashboard is ungated, so it is always a valid landing tab.
function firstTab(_perms: any) {
  return "dashboard";
}

// ─── Dashboard ───────────────────────────────────────────────────────────────

// h:mm:ss in the receipt voice (mono, tabular) — a shift is read at a glance, so
// seconds matter more than a rounded "2h 14m".
function fmtClock(seconds: number) {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${h}:${String(m).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// One headline number.
function Stat({ icon: Icon, label, value, sub, tone }: {
  icon: any; label: string; value: string; sub?: string; tone?: "brand" | "warn";
}) {
  return (
    <Card>
      <CardContent className="flex items-start gap-2.5 p-3">
        <Icon className={cn("mt-0.5 h-4 w-4 shrink-0",
          tone === "warn" ? "text-destructive" : tone === "brand" ? "text-primary" : "text-muted-foreground")} />
        <div className="min-w-0">
          <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{label}</div>
          <div className="font-mono text-lg font-bold tabular-nums leading-tight">{value}</div>
          {sub && <div className="truncate text-[11px] text-muted-foreground">{sub}</div>}
        </div>
      </CardContent>
    </Card>
  );
}

// The register operator's home screen: the shift clock (the SAME shift the phone
// app punches — one ShiftCache server-side, so clocking in here shows up there),
// who else is on, and the state of the room. Polls while the panel sits open so the
// ticket queue and the timer stay honest; any panel refresh replaces the block.
function Dashboard({ id, dash, perms, balance }: any) {
  const [d, setD] = useState<any>(dash);
  const [tick, setTick] = useState(0);
  const [busy, setBusy] = useState(false);
  // A full panel refresh (any other action) brings a fresh dashboard block with it.
  useEffect(() => { if (dash) setD(dash); }, [dash]);

  const refresh = () =>
    fetchNui("management:refresh", { id }).then((r: any) => { if (r?.ok && r.dashboard) setD(r.dashboard); });

  useEffect(() => {
    const s = setInterval(() => setTick((n) => n + 1), 1000);
    const p = setInterval(refresh, 10000);
    return () => { clearInterval(s); clearInterval(p); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  // Anchor the timer to the payload's own server clock the moment it arrives, then
  // run it off the local clock — so it never jumps on a poll and never drifts if the
  // player's machine disagrees with the server about the time of day.
  const anchor = useRef({ base: 0, at: Date.now() });
  useEffect(() => {
    anchor.current = { base: d?.since ? Math.max(0, (d.now || 0) - d.since) : 0, at: Date.now() };
  }, [d]);
  const elapsed = tick >= 0 && d?.clockedIn
    ? anchor.current.base + Math.floor((Date.now() - anchor.current.at) / 1000)
    : 0;

  const clock = async () => {
    if (busy) return;
    setBusy(true);
    await fetchNui(d?.clockedIn ? "management:clockOut" : "management:clockIn", { id });
    await refresh();
    setBusy(false);
  };

  const roster: any[] = d?.roster || [];
  const outOfStock: any[] = d?.outOfStock || [];

  return (
    <div className="space-y-3">
      {/* the shift clock — the one thing on this tab you ACT on */}
      <Card>
        <CardContent className="flex flex-wrap items-center gap-4 p-4">
          <div className="min-w-[9rem]">
            <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
              {d?.clockedIn ? _L("mgmt.dash_on_clock") : _L("mgmt.dash_off_duty")}
            </div>
            <div className="font-mono text-3xl font-extrabold tabular-nums leading-tight">
              {d?.clockedIn ? fmtClock(elapsed) : "—"}
            </div>
          </div>
          <div className="flex gap-4">
            <div>
              <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{_L("mgmt.dash_tips")}</div>
              <div className="font-mono text-lg font-bold tabular-nums">{money(d?.tips || 0)}</div>
            </div>
            <div>
              <div className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{_L("mgmt.dash_cooked")}</div>
              <div className="font-mono text-lg font-bold tabular-nums">{d?.cooked || 0}</div>
            </div>
          </div>
          <Button
            onClick={clock}
            disabled={busy}
            variant={d?.clockedIn ? "destructive" : "default"}
            className="ml-auto min-w-[10rem] gap-2"
          >
            {d?.clockedIn ? <Square className="h-4 w-4" /> : <Play className="h-4 w-4" />}
            {d?.clockedIn ? _L("mgmt.dash_clock_out") : _L("mgmt.dash_clock_in")}
          </Button>
        </CardContent>
      </Card>

      {/* the state of the room */}
      <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
        <Stat icon={Receipt} tone={(d?.openOrders || 0) > 0 ? "brand" : undefined}
          label={_L("mgmt.dash_open_tickets")} value={String(d?.openOrders ?? 0)}
          sub={perms.view_finances && d?.openValue != null ? _L("mgmt.dash_worth", money(d.openValue)) : undefined} />
        <Stat icon={Users} label={_L("mgmt.dash_on_shift")} value={String(roster.length)}
          sub={_L("mgmt.dash_of_staff", d?.employees ?? 0)} />
        {perms.view_finances ? (
          <Stat icon={Banknote} label={_L("mgmt.dash_today")} value={money(d?.todaySales || 0)}
            sub={_L("mgmt.dash_orders_n", d?.todayOrders ?? 0)} />
        ) : (
          <Stat icon={UtensilsCrossed} label={_L("mgmt.dash_menu")} value={String(d?.menuSize ?? 0)} />
        )}
        {perms.view_finances ? (
          <Stat icon={ScrollText} label={_L("mgmt.dash_balance")} value={money(balance)} />
        ) : (
          <Stat icon={Monitor} label={_L("mgmt.dash_registers")} value={String(d?.registers ?? 0)}
            sub={_L("mgmt.dash_kiosks_n", d?.kiosks ?? 0)} />
        )}
      </div>

      {/* the points of sale this place actually has, so you know what else is live */}
      {perms.view_finances && (
        <div className="grid grid-cols-3 gap-2">
          <Stat icon={Monitor} label={_L("mgmt.dash_registers")} value={String(d?.registers ?? 0)} />
          <Stat icon={Sparkles} label={_L("mgmt.dash_kiosks")} value={String(d?.kiosks ?? 0)} />
          <Stat icon={Armchair} label={_L("mgmt.dash_seats")} value={String(d?.seats ?? 0)} />
        </div>
      )}

      {/* anything that will stop the kitchen mid-service */}
      {perms.manage_stock && outOfStock.length > 0 && (
        <Card>
          <CardContent className="p-3">
            <div className="mb-2 flex items-center gap-1.5 text-xs font-semibold text-destructive">
              <TriangleAlert className="h-4 w-4" /> {_L("mgmt.dash_out_of_stock", outOfStock.length)}
            </div>
            <div className="flex flex-wrap gap-1.5">
              {outOfStock.map((s) => (
                <Badge key={s.item} variant="outline" className="gap-1.5">
                  <Thumb src={s.image} className="h-4 w-4" />
                  {s.label || prettyItem(s.item)}
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      )}

      {/* who's on with you — the tip pool this shift splits into */}
      <Card>
        <CardContent className="p-3">
          <div className="mb-2 text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
            {_L("mgmt.dash_tip_pool")}
          </div>
          {roster.length === 0 ? (
            <div className="text-xs text-muted-foreground">{_L("mgmt.dash_nobody_on")}</div>
          ) : (
            <div className="space-y-1.5">
              {roster.map((m, i) => (
                <div key={i} className="flex items-center justify-between rounded-md border border-border bg-muted/30 px-2.5 py-1.5">
                  <span className="flex items-center gap-2 text-sm">
                    <Users className="h-3.5 w-3.5 text-muted-foreground" />
                    {m.name}
                  </span>
                  <span className="flex items-center gap-3 font-mono text-xs tabular-nums text-muted-foreground">
                    <span>{fmtClock(Math.max(0, (d?.now || 0) - (m.since || 0)))}</span>
                    <span className="text-foreground">{money(m.tips || 0)}</span>
                  </span>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function Employees({ id, roles, employees, nearby }: any) {
  const [target, setTarget] = useState("");
  const [grade, setGrade] = useState(roles[0]?.grade ?? 0);
  return (
    <div className="space-y-3">
      <Card>
        <CardContent className="flex items-end gap-2 pt-4">
          <div className="flex-1">
            <label className="mb-1 block text-xs text-muted-foreground">{_L("mgmt.nearby_player")}</label>
            <select className="h-9 w-full rounded-md border border-input bg-muted/50 px-2 text-sm transition-colors focus-visible:border-primary/60 focus-visible:outline-none" value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="">{_L("mgmt.select")}</option>
              {nearby.map((p: any) => <option key={p.id} value={p.id}>{p.name} [{p.id}]</option>)}
            </select>
          </div>
          <div>
            <label className="mb-1 block text-xs text-muted-foreground">{_L("mgmt.grade")}</label>
            <select className="h-9 rounded-md border border-input bg-muted/50 px-2 text-sm transition-colors focus-visible:border-primary/60 focus-visible:outline-none" value={grade} onChange={(e) => setGrade(Number(e.target.value))}>
              {roles.map((r: any) => <option key={r.grade} value={r.grade}>{r.label}</option>)}
            </select>
          </div>
          <Button disabled={!target} onClick={() => fetchNui("management:hire", { id, target: Number(target), grade })}>
            <UserPlus className="h-4 w-4" /> {_L("mgmt.hire")}
          </Button>
        </CardContent>
      </Card>

      {employees.map((e: any) => (
        <Card key={e.identifier}>
          <CardContent className="flex items-center justify-between gap-2 pt-4">
            <div>
              <div className="font-medium">{e.name || e.identifier}</div>
              <div className="text-xs text-muted-foreground">{e.identifier}</div>
            </div>
            <div className="flex items-center gap-2">
              <select
                className="h-8 rounded-md border border-input bg-muted/50 px-2 text-xs transition-colors focus-visible:border-primary/60 focus-visible:outline-none"
                value={e.grade}
                onChange={(ev) => fetchNui("management:setGrade", { id, identifier: e.identifier, grade: Number(ev.target.value) })}
              >
                {roles.map((r: any) => <option key={r.grade} value={r.grade}>{r.label}</option>)}
              </select>
              <div className="flex items-center gap-1">
                <Input
                  type="number"
                  defaultValue={e.commission}
                  className="h-8 w-20"
                  onBlur={(ev) => fetchNui("management:setCommission", { id, identifier: e.identifier, commission: Number(ev.target.value) })}
                />
                <span className="text-xs text-muted-foreground">%</span>
              </div>
              <Button size="sm" variant="destructive" onClick={() => fetchNui("management:fire", { id, identifier: e.identifier })}>
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          </CardContent>
        </Card>
      ))}
      {employees.length === 0 && <div className="py-4 text-center text-sm text-muted-foreground">{_L("mgmt.no_employees")}</div>}
    </div>
  );
}

const KIND_LABEL: Record<string, string> = {
  recipe: "register.kind_recipe",
  assembly: "register.kind_assembly",
  craft: "register.kind_craft",
  drink: "register.kind_drink",
  finish: "register.kind_finish",
  condiment: "register.kind_condiment",
};

// The POS price list: one row per sellable the restaurant can access. A price of
// 0 or a disabled toggle means the item is NOT orderable at the register. Edits
// auto-save (debounced per row) — there are no Save buttons anywhere.
function Menu({ id, priceList, stale }: { id: number; priceList: any[]; stale: any[] }) {
  return (
    <div className="space-y-3">
      <p className="text-[11px] text-muted-foreground">{_L("mgmt.price_list_hint")}</p>
      {priceList.length === 0 && <div className="py-4 text-center text-sm text-muted-foreground">{_L("mgmt.no_sellables")}</div>}
      {priceList.map((e: any) => <PriceRow key={e.key} id={id} entry={e} />)}

      {stale.length > 0 && (
        <div className="mt-4 rounded-lg border border-amber-500/40 p-3">
          <h3 className="mb-2 text-sm font-semibold">{_L("mgmt.price_stale")}</h3>
          {stale.map((s: any) => (
            <div key={s.key} className="flex items-center gap-2 py-1 text-sm">
              {/* a stale row is still a menu entry — it gets its picture like any other,
                  so the owner can see WHAT they're about to delete off the menu */}
              <Thumb src={s.image} alt={s.label} className="h-8 w-8 shrink-0" />
              <span className="min-w-0 flex-1 truncate text-muted-foreground">{s.label} · {money(s.price)}</span>
              <Button size="sm" variant="destructive" onClick={() => fetchNui("management:deleteMenuItem", { id, key: s.key })}>
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function PriceRow({ id, entry }: { id: number; entry: any }) {
  const def = Math.max(0, Math.floor(entry.defaultPrice || 0));
  // The price input is an OVERRIDE: empty = fall back to the ingredient-cost
  // default. `priceIsDefault` means there's no per-restaurant row yet.
  const [price, setPrice] = useState<string>(entry.priceIsDefault ? "" : String(entry.price ?? ""));
  const [enabled, setEnabled] = useState<boolean>(!!entry.enabled);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) { first.current = false; return; }
    const t = setTimeout(() => {
      const raw = price.trim();
      const num = raw === "" ? null : Math.max(0, Math.floor(Number(raw) || 0));
      if (num === null && enabled) {
        // pure default (blank price, orderable) — remove any override row
        fetchNui("management:deleteMenuItem", { id, key: entry.key });
      } else {
        fetchNui("management:saveMenuItem", { id, key: entry.key, price: num ?? def, enabled });
      }
    }, 500);
    return () => clearTimeout(t);
  }, [price, enabled]);

  const effPrice = price.trim() === "" ? def : Math.max(0, Math.floor(Number(price) || 0));
  const orderable = enabled && effPrice > 0;
  return (
    <Card>
      <CardContent className="flex items-center gap-3 pt-4 text-sm">
        <Thumb src={entry.image} className="h-10 w-10 shrink-0" />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="truncate font-medium">{entry.label}</span>
            <Badge variant="secondary">{_L(KIND_LABEL[entry.kind] || "register.kind_recipe")}</Badge>
            {!orderable && <span className="text-[11px] text-muted-foreground">{_L("mgmt.not_orderable")}</span>}
          </div>
          {def > 0 && <div className="text-[11px] text-muted-foreground">{_L("mgmt.price_default_hint", def)}</div>}
        </div>
        <div className="flex shrink-0 items-center gap-3">
          <div className="flex items-center gap-1">
            <span className="text-muted-foreground">$</span>
            <Input type="number" min={0} value={price} placeholder={String(def)} onChange={(e) => setPrice(e.target.value)} className="h-8 w-20" />
          </div>
          <Toggle checked={enabled} onChange={setEnabled} />
        </div>
      </CardContent>
    </Card>
  );
}

// The Supplies tab: buy raw ingredients into the restaurant's shared stock pool
// (paid from the restaurant balance). The kitchen cooks from this stock.
function Supplies({ id, supplies }: { id: number; supplies: any[] }) {
  return (
    <div className="space-y-3">
      <p className="text-[11px] text-muted-foreground">{_L("mgmt.supplies_hint")}</p>
      {supplies.length === 0 && <div className="py-4 text-center text-sm text-muted-foreground">{_L("mgmt.no_supplies")}</div>}
      {supplies.map((s) => <SupplyRow key={s.key || s.item} id={id} supply={s} />)}
    </div>
  );
}

function SupplyRow({ id, supply }: { id: number; supply: any }) {
  const [qty, setQty] = useState(5);
  const [stock, setStock] = useState<number>(supply.stock || 0);
  const [held, setHeld] = useState<number>(supply.held || 0);
  // Everything addresses the STOCK KEY, which for a multi-faced ingredient names
  // the face (`restaurant_toy:lardboy`) rather than the item — that is what the
  // larder counts and prices. `item` is still sent so an older server that only
  // understands item names keeps working.
  const key = supply.key || supply.item;
  const buy = async () => {
    const res = await fetchNui<any>("management:buyStock", { id, key, item: supply.item, qty });
    if (res && res.ok) setStock(res.stock);
  };
  // Deposit moves the manager's own items INTO the shared pool; withdraw pulls
  // pool stock back OUT into their pockets. Both echo the fresh stock + held
  // counts so the row stays live without re-fetching the whole panel.
  const move = (event: "management:depositStock" | "management:withdrawStock") => async () => {
    const res = await fetchNui<any>(event, { id, key, item: supply.item, qty });
    if (res && res.ok) { setStock(res.stock); setHeld(res.held); }
  };
  return (
    <Card>
      {/* ONE row: the identity column and the controls column are siblings on the
          same line, so the card is as tall as its tallest control — not an info row
          stacked over a button row (which left the thumb/label column half-height). */}
      <CardContent className="flex flex-wrap items-center gap-x-3 gap-y-2 py-3 text-sm">
        <Thumb src={supply.image} className="h-10 w-10 shrink-0" />
        <div className="min-w-0 flex-1 basis-48">
          <div className="flex items-center gap-2">
            <span className="truncate font-medium">{supply.label}</span>
            {!supply.installed && <Badge variant="destructive">{_L("mgmt.not_installed")}</Badge>}
          </div>
          <div className="text-[11px] text-muted-foreground">
            {_L("mgmt.cost_each", money(supply.cost))} · {_L("mgmt.in_stock", stock)}
            {/* A face isn't movable between pocket and larder (the inventory item is
                generic), so "you hold N" would always read 0 and mean nothing. */}
            {supply.movable && <> · {_L("mgmt.you_hold", held)}</>}
          </div>
        </div>
        <div className="flex shrink-0 items-center">
          <Button size="icon" variant="ghost" onClick={() => setQty((q) => Math.max(1, q - 1))}><Minus className="h-3.5 w-3.5" /></Button>
          <Input type="number" min={1} value={qty} onChange={(e) => setQty(Math.max(1, Math.floor(Number(e.target.value) || 1)))} className="h-8 w-16 text-center" />
          <Button size="icon" variant="ghost" onClick={() => setQty((q) => q + 1)}><Plus className="h-3.5 w-3.5" /></Button>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {supply.movable && (
            <>
              <Button size="sm" variant="outline" onClick={move("management:depositStock")} disabled={held < qty} title={_L("mgmt.deposit_stock_hint")}>
                <ArrowDownToLine className="h-4 w-4" /> {_L("mgmt.deposit_stock")}
              </Button>
              <Button size="sm" variant="outline" onClick={move("management:withdrawStock")} disabled={stock < qty} title={_L("mgmt.withdraw_stock_hint")}>
                <ArrowUpFromLine className="h-4 w-4" /> {_L("mgmt.withdraw_stock")}
              </Button>
            </>
          )}
          <Button size="sm" onClick={buy}><PackagePlus className="h-4 w-4" /> {_L("mgmt.buy")} · {money(supply.cost * qty)}</Button>
        </div>
      </CardContent>
    </Card>
  );
}

function Finances({ id, balance, ledger, canManage }: any) {
  const [amount, setAmount] = useState(0);
  return (
    <div className="space-y-3">
      <Card>
        <CardContent className="flex items-center justify-between pt-4">
          <div className="flex items-center gap-2.5">
            <div className="grid h-9 w-9 place-items-center rounded-md bg-primary/15 text-primary"><Banknote className="h-5 w-5" /></div>
            <div>
              <div className="tape">{_L("mgmt.balance_label")}</div>
              <div className="font-mono text-xl font-bold leading-tight tabular-nums">{money(balance)}</div>
            </div>
          </div>
          {canManage && (
            <div className="flex items-center gap-2">
              <Input type="number" className="w-28" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
              <Button size="sm" onClick={() => fetchNui("management:deposit", { id, amount })}>{_L("mgmt.deposit")}</Button>
              <Button size="sm" variant="outline" onClick={() => fetchNui("management:withdraw", { id, amount })}>{_L("mgmt.withdraw")}</Button>
            </div>
          )}
        </CardContent>
      </Card>
      <div className="overflow-hidden rounded-lg border border-border bg-card">
        <div className="tape grid grid-cols-4 border-b border-border px-3 py-2">
          <span>{_L("mgmt.col_type")}</span><span>{_L("mgmt.col_amount")}</span><span className="col-span-2">{_L("mgmt.col_description")}</span>
        </div>
        {ledger.map((l: any, i: number) => (
          <div key={i} className="grid grid-cols-4 px-3 py-1.5 text-xs odd:bg-muted/30">
            <span className="capitalize">{l.type}</span>
            <span className={cn("font-mono tabular-nums", l.amount < 0 ? "text-destructive" : "text-ok")}>{money(l.amount)}</span>
            <span className="col-span-2 truncate text-muted-foreground">{l.description}</span>
          </div>
        ))}
        {ledger.length === 0 && <div className="px-3 py-3 text-xs text-muted-foreground">{_L("mgmt.no_transactions")}</div>}
      </div>
    </div>
  );
}
