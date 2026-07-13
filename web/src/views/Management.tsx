import { useEffect, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Field, TextField, NumberField, Toggle } from "@/components/form";
import { type Item } from "@/components/ItemPicker";
import Branding, { ThemeEditor } from "@/components/Branding";
import Combos from "@/components/ComboEditor";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { UserPlus, Trash2, Plus, Minus, MapPin, Banknote, Armchair, ImageOff, PackagePlus, ArrowDownToLine, ArrowUpFromLine, Sparkles, Users } from "lucide-react";

// Inventory thumbnail from a direct nui:// url the server resolved.
function Thumb({ src, className }: { src?: string; className?: string }) {
  const [broken, setBroken] = useState(false);
  if (!src || broken) {
    return (
      <div className={cn("flex items-center justify-center rounded bg-muted/60 text-muted-foreground", className)}>
        <ImageOff className="h-1/2 w-1/2" />
      </div>
    );
  }
  return <img src={src} onError={() => setBroken(true)} className={cn("rounded object-contain", className)} />;
}

export default function Management({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const perms = data?.perms || {};
  const roles: any[] = data?.roles || [];
  const items: Item[] = data?.items || [];
  const focus = data?.focus; // { section } — set after a placement reopen
  // A placement reopen lands on the Stations tab (if allowed) instead of the default.
  const initialTab = (focus?.section && perms.manage_props) ? "stations" : firstTab(perms);

  return (
    <Panel title={data?.restaurant?.label || _L("mgmt.title")} subtitle={_L("mgmt.balance", money(data?.restaurant?.balance))} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue={initialTab} className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          {perms.manage_employees && <TabsTrigger value="employees">{_L("mgmt.tab_employees")}</TabsTrigger>}
          {perms.manage_menu && <TabsTrigger value="menu">{_L("mgmt.tab_menu")}</TabsTrigger>}
          {perms.manage_menu && <TabsTrigger value="combos">{_L("mgmt.tab_combos")}</TabsTrigger>}
          {perms.manage_stock && <TabsTrigger value="supplies">{_L("mgmt.tab_supplies")}</TabsTrigger>}
          {perms.view_finances && <TabsTrigger value="finances">{_L("mgmt.tab_finances")}</TabsTrigger>}
          {perms.manage_props && <TabsTrigger value="stations">{_L("mgmt.tab_stations")}</TabsTrigger>}
          {perms.manage_props && <TabsTrigger value="branding">{_L("mgmt.tab_branding")}</TabsTrigger>}
        </TabsList>

        {perms.manage_employees && (
          <TabsContent value="employees" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Employees id={id} roles={roles} employees={data?.employees || []} nearby={data?.nearby || []} />
          </TabsContent>
        )}
        {perms.manage_menu && (
          <TabsContent value="menu" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Menu id={id} priceList={data?.priceList || []} stale={data?.stale || []} />
          </TabsContent>
        )}
        {perms.manage_menu && (
          <TabsContent value="combos" className="min-h-0 flex-1 overflow-y-auto pr-1">
            {/* Option picker is over sellable KEYS: map the price list to the ItemPicker
                shape (name = catalog key, so drink flavors are pickable too). */}
            <Combos
              id={id}
              combos={data?.combos || []}
              sellables={(data?.priceList || []).map((e: any) => ({ name: e.key, label: e.label, image: e.image }))}
              groups={data?.comboGroups || []}
            />
          </TabsContent>
        )}
        {perms.manage_stock && (
          <TabsContent value="supplies" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Supplies id={id} supplies={data?.supplies || []} />
          </TabsContent>
        )}
        {perms.view_finances && (
          <TabsContent value="finances" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Finances id={id} balance={data?.restaurant?.balance} ledger={data?.ledger || []} canManage={!!perms.manage_balance} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="stations" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Stations id={id} props={data?.props || []} hasShell={data?.restaurant?.hasShell} hasNpcSpawn={data?.restaurant?.hasNpcSpawn} focusSection={focus?.section} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="branding" className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
            <ThemeEditor id={id} theme={data?.restaurant?.theme} event="management:setTheme" />
            <Branding id={id} brand={data?.restaurant?.brand_image || ""} brandImages={data?.restaurant?.brand_images || {}} event="management:setBrandImage" />
          </TabsContent>
        )}
      </Tabs>
    </Panel>
  );
}

function firstTab(perms: any) {
  if (perms.manage_employees) return "employees";
  if (perms.manage_menu) return "menu";
  if (perms.view_finances) return "finances";
  return "stations";
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
  drink: "register.kind_drink",
  finish: "register.kind_finish",
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
            <div key={s.key} className="flex items-center justify-between py-1 text-sm">
              <span className="text-muted-foreground">{s.label} · {money(s.price)}</span>
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
      {supplies.map((s) => <SupplyRow key={s.item} id={id} supply={s} />)}
    </div>
  );
}

function SupplyRow({ id, supply }: { id: number; supply: any }) {
  const [qty, setQty] = useState(5);
  const [stock, setStock] = useState<number>(supply.stock || 0);
  const [held, setHeld] = useState<number>(supply.held || 0);
  const buy = async () => {
    const res = await fetchNui<any>("management:buyStock", { id, item: supply.item, qty });
    if (res && res.ok) setStock(res.stock);
  };
  // Deposit moves the manager's own items INTO the shared pool; withdraw pulls
  // pool stock back OUT into their pockets. Both echo the fresh stock + held
  // counts so the row stays live without re-fetching the whole panel.
  const move = (event: "management:depositStock" | "management:withdrawStock") => async () => {
    const res = await fetchNui<any>(event, { id, item: supply.item, qty });
    if (res && res.ok) { setStock(res.stock); setHeld(res.held); }
  };
  return (
    <Card>
      <CardContent className="space-y-2.5 pt-4 text-sm">
        <div className="flex items-center gap-3">
          <Thumb src={supply.image} className="h-10 w-10 shrink-0" />
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <span className="truncate font-medium">{supply.label}</span>
              {!supply.installed && <Badge variant="destructive">{_L("mgmt.not_installed")}</Badge>}
            </div>
            <div className="text-[11px] text-muted-foreground">
              {_L("mgmt.cost_each", money(supply.cost))} · {_L("mgmt.in_stock", stock)} · {_L("mgmt.you_hold", held)}
            </div>
          </div>
          <div className="flex shrink-0 items-center">
            <Button size="icon" variant="ghost" onClick={() => setQty((q) => Math.max(1, q - 1))}><Minus className="h-3.5 w-3.5" /></Button>
            <Input type="number" min={1} value={qty} onChange={(e) => setQty(Math.max(1, Math.floor(Number(e.target.value) || 1)))} className="h-8 w-16 text-center" />
            <Button size="icon" variant="ghost" onClick={() => setQty((q) => q + 1)}><Plus className="h-3.5 w-3.5" /></Button>
          </div>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-2">
          <Button size="sm" variant="outline" onClick={move("management:depositStock")} disabled={held < qty} title={_L("mgmt.deposit_stock_hint")}>
            <ArrowDownToLine className="h-4 w-4" /> {_L("mgmt.deposit_stock")}
          </Button>
          <Button size="sm" variant="outline" onClick={move("management:withdrawStock")} disabled={stock < qty} title={_L("mgmt.withdraw_stock_hint")}>
            <ArrowUpFromLine className="h-4 w-4" /> {_L("mgmt.withdraw_stock")}
          </Button>
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

function Stations({ id, props, hasShell, hasNpcSpawn, focusSection }: any) {
  const STATIONS = [
    { key: "soda_machine", label: _L("admin.station_soda_machine") },
    { key: "fryer", label: _L("admin.station_fryer") },
    { key: "stovetop", label: _L("admin.station_stovetop") },
    { key: "kitchen_prep", label: _L("admin.station_kitchen_prep") },
    // The self-service kiosk is a customer ORDER terminal, not a cooking station,
    // so it's placed as a physical world prop only (no virtual-kitchen variant).
    { key: "kiosk", label: _L("admin.station_kiosk"), physicalOnly: true },
    // Free-standing floor kiosk (the _02 body) — same order terminal, ground-placed.
    { key: "kiosk_ground", label: _L("admin.station_kiosk_ground"), physicalOnly: true },
    // Customer info SCREENS — non-interactable wall boards driven by a render target
    // (menu slideshow / live orders). Physical world props only.
    { key: "menu_screen", label: _L("admin.station_menu_screen"), physicalOnly: true },
    { key: "orders_screen", label: _L("admin.station_orders_screen"), physicalOnly: true },
  ];
  const seats = (props as any[]).filter((p) => p.prop_type === "seat");
  const [modes, setModes] = useState<Record<string, "physical" | "virtual">>({});
  const setMode = (k: string, m: "physical" | "virtual") => setModes((prev) => ({ ...prev, [k]: m }));
  const stationsRef = useRef<HTMLDivElement>(null);
  const seatingRef = useRef<HTMLDivElement>(null);

  // Scroll the just-used section into view when reopened from a placement flow.
  // Virtual placement lives in the stations card now, so "virtual" lands there.
  useEffect(() => {
    if (!focusSection) return;
    const el = focusSection === "seating" ? seatingRef.current : stationsRef.current;
    const t = setTimeout(() => el?.scrollIntoView({ behavior: "smooth", block: "start" }), 60);
    return () => clearTimeout(t);
  }, [focusSection]);

  return (
    <div className="space-y-3">
      {/* stations — each type places either a physical world prop or a virtual
          point (opens the station inside the kitchen shell, placed by an admin).
          The per-row toggle picks the mode. */}
      <Card ref={stationsRef}>
        <CardContent className="pt-4">
          <div className="mb-3 flex items-center justify-between gap-2">
            <h3 className="text-sm font-semibold">{_L("mgmt.stations_heading")}</h3>
            <div className="flex items-center gap-1.5">
              <Button variant="outline" size="sm" onClick={() => fetchNui("management:placeNpcSpawn", { id })}>
                <Users className="h-3.5 w-3.5" /> {hasNpcSpawn ? `${_L("mgmt.set_npc_spawn")} ✓` : _L("mgmt.set_npc_spawn")}
              </Button>
              <Button variant="outline" size="sm" onClick={() => fetchNui("management:setCounter", { id })}>
                <MapPin className="h-3.5 w-3.5" /> {_L("mgmt.set_counter")}
              </Button>
            </div>
          </div>
          <div className="space-y-3">
            {STATIONS.map((s) => {
              const physical = (props as any[]).filter((p) => p.prop_type === s.key);
              const virtual = (props as any[]).filter((p) => p.prop_type === "virtual_point" && p.target === s.key);
              const isVirtual = !s.physicalOnly && (modes[s.key] || "physical") === "virtual";
              return (
                <div key={s.key}>
                  <div className="mb-1.5 flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 text-sm">
                      {s.label}
                      <Badge variant="secondary">{physical.length + virtual.length}</Badge>
                    </div>
                    <div className="flex items-center gap-1.5">
                      {!s.physicalOnly && (
                      <div className="flex rounded-md border border-border p-0.5 text-[11px]">
                        <button
                          className={cn("rounded px-2 py-0.5 transition-colors", !isVirtual ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground")}
                          onClick={() => setMode(s.key, "physical")}
                        >{_L("mgmt.mode_physical")}</button>
                        <button
                          className={cn("rounded px-2 py-0.5 transition-colors", isVirtual ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground")}
                          onClick={() => setMode(s.key, "virtual")}
                        >{_L("mgmt.mode_virtual")}</button>
                      </div>
                      )}
                      <Button
                        variant="outline"
                        size="sm"
                        disabled={isVirtual && !hasShell}
                        onClick={() => isVirtual
                          ? fetchNui("management:placeVirtualPoint", { id, target: s.key })
                          : fetchNui("management:placeProp", { id, prop_type: s.key })}
                      >
                        {isVirtual ? <Sparkles className="h-3.5 w-3.5" /> : <Plus className="h-3.5 w-3.5" />} {_L("mgmt.place")}
                      </Button>
                    </div>
                  </div>
                  {isVirtual && !hasShell && (
                    <p className="mb-1 text-[11px] text-muted-foreground">{_L("mgmt.virtual_needs_shell")}</p>
                  )}
                  {(physical.length > 0 || virtual.length > 0) && (
                    <div className="flex flex-wrap gap-1.5">
                      {physical.map((p: any) => (
                        <Badge key={p.id} variant="outline" className="gap-1.5">
                          #{p.id}
                          <button onClick={() => fetchNui("management:removeProp", { id, propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                        </Badge>
                      ))}
                      {virtual.map((p: any) => (
                        <Badge key={p.id} variant="outline" className="gap-1.5" title={_L("mgmt.mode_virtual")}>
                          <Sparkles className="h-3 w-3 text-primary" /> #{p.id}
                          <button onClick={() => fetchNui("management:removeProp", { id, propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                        </Badge>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
          <p className="mt-3 text-[11px] text-muted-foreground">{_L("mgmt.virtual_hint")}</p>
        </CardContent>
      </Card>

      <Card ref={seatingRef}>
        <CardContent className="pt-4">
          <div className="mb-2 flex items-center justify-between">
            <h3 className="flex items-center gap-2 text-sm font-semibold"><Armchair className="h-4 w-4" /> {_L("mgmt.seating")}</h3>
            <Button variant="outline" size="sm" onClick={() => fetchNui("management:placeSeat", { id })}>
              <MapPin className="h-3.5 w-3.5" /> {_L("mgmt.place_seat")}
            </Button>
          </div>
          {seats.length > 0 ? (
            <div className="flex flex-wrap gap-1.5">
              {seats.map((p: any) => (
                <Badge key={p.id} variant="outline" className="gap-1.5">
                  {_L("mgmt.seat_num", p.id)}
                  <button onClick={() => fetchNui("management:removeProp", { id, propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                </Badge>
              ))}
            </div>
          ) : (
            <div className="text-xs text-muted-foreground">{_L("mgmt.no_seats")}</div>
          )}
          <p className="mt-2 text-[11px] text-muted-foreground">{_L("mgmt.seat_hint")}</p>
        </CardContent>
      </Card>
    </div>
  );
}
