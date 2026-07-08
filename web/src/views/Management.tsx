import { useEffect, useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Field, TextField, NumberField, Toggle } from "@/components/form";
import { type Item } from "@/components/ItemPicker";
import Branding from "@/components/Branding";
import { money, cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { UserPlus, Trash2, Plus, MapPin, Banknote, Armchair, ImageOff } from "lucide-react";

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
  return <img src={src} onError={() => setBroken(true)} className={cn("rounded bg-muted/40 object-contain", className)} />;
}

export default function Management({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const perms = data?.perms || {};
  const roles: any[] = data?.roles || [];
  const items: Item[] = data?.items || [];

  return (
    <Panel title={data?.restaurant?.label || _L("mgmt.title")} subtitle={_L("mgmt.balance", money(data?.restaurant?.balance))} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue={firstTab(perms)} className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          {perms.manage_employees && <TabsTrigger value="employees">{_L("mgmt.tab_employees")}</TabsTrigger>}
          {perms.manage_menu && <TabsTrigger value="menu">{_L("mgmt.tab_menu")}</TabsTrigger>}
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
        {perms.view_finances && (
          <TabsContent value="finances" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Finances id={id} balance={data?.restaurant?.balance} ledger={data?.ledger || []} canManage={!!perms.manage_balance} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="stations" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Stations id={id} props={data?.props || []} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="branding" className="min-h-0 flex-1 overflow-y-auto pr-1">
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
            <select className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm" value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="">{_L("mgmt.select")}</option>
              {nearby.map((p: any) => <option key={p.id} value={p.id}>{p.name} [{p.id}]</option>)}
            </select>
          </div>
          <div>
            <label className="mb-1 block text-xs text-muted-foreground">{_L("mgmt.grade")}</label>
            <select className="h-9 rounded-md border border-input bg-background px-2 text-sm" value={grade} onChange={(e) => setGrade(Number(e.target.value))}>
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
                className="h-8 rounded-md border border-input bg-background px-2 text-xs"
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
  const [price, setPrice] = useState<number>(entry.price || 0);
  const [enabled, setEnabled] = useState<boolean>(!!entry.enabled);

  // Debounced auto-save on any price/toggle change (no Save button). Skips the
  // initial mount so opening the tab doesn't write every row.
  useEffect(() => {
    if (price === (entry.price || 0) && enabled === !!entry.enabled) return;
    const t = setTimeout(() => {
      fetchNui("management:saveMenuItem", { id, key: entry.key, price: Math.max(0, Math.floor(price || 0)), enabled });
    }, 500);
    return () => clearTimeout(t);
  }, [price, enabled]);

  const orderable = enabled && price > 0;
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
        </div>
        <div className="flex shrink-0 items-center gap-3">
          <div className="flex items-center gap-1">
            <span className="text-muted-foreground">$</span>
            <Input type="number" min={0} value={price} onChange={(e) => setPrice(Number(e.target.value))} className="h-8 w-20" />
          </div>
          <Toggle checked={enabled} onChange={setEnabled} />
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
          <div className="flex items-center gap-2 text-lg font-semibold"><Banknote className="h-5 w-5 text-primary" /> {money(balance)}</div>
          {canManage && (
            <div className="flex items-center gap-2">
              <Input type="number" className="w-28" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
              <Button size="sm" onClick={() => fetchNui("management:deposit", { id, amount })}>{_L("mgmt.deposit")}</Button>
              <Button size="sm" variant="outline" onClick={() => fetchNui("management:withdraw", { id, amount })}>{_L("mgmt.withdraw")}</Button>
            </div>
          )}
        </CardContent>
      </Card>
      <div className="rounded-lg border border-border">
        <div className="grid grid-cols-4 border-b border-border px-3 py-2 text-xs font-semibold text-muted-foreground">
          <span>{_L("mgmt.col_type")}</span><span>{_L("mgmt.col_amount")}</span><span className="col-span-2">{_L("mgmt.col_description")}</span>
        </div>
        {ledger.map((l: any, i: number) => (
          <div key={i} className="grid grid-cols-4 px-3 py-1.5 text-xs">
            <span className="capitalize">{l.type}</span>
            <span className={l.amount < 0 ? "text-destructive" : "text-emerald-400"}>{money(l.amount)}</span>
            <span className="col-span-2 truncate text-muted-foreground">{l.description}</span>
          </div>
        ))}
        {ledger.length === 0 && <div className="px-3 py-3 text-xs text-muted-foreground">{_L("mgmt.no_transactions")}</div>}
      </div>
    </div>
  );
}

function Stations({ id, props }: any) {
  const STATIONS = [
    { key: "soda_machine", label: _L("admin.station_soda_machine") },
    { key: "fryer", label: _L("admin.station_fryer") },
    { key: "stovetop", label: _L("admin.station_stovetop") },
    { key: "kitchen_prep", label: _L("admin.station_kitchen_prep") },
  ];
  const seats = (props as any[]).filter((p) => p.prop_type === "seat");
  const stationProps = (props as any[]).filter((p) => p.prop_type !== "seat");
  return (
    <div className="space-y-3">
      <Card>
        <CardContent className="flex flex-wrap items-center gap-2 pt-4">
          {STATIONS.map((s) => (
            <Button key={s.key} variant="outline" size="sm" onClick={() => fetchNui("management:placeProp", { id, prop_type: s.key })}>
              <MapPin className="h-3.5 w-3.5" /> {_L("mgmt.place_station", s.label)}
            </Button>
          ))}
          <Button variant="outline" size="sm" onClick={() => fetchNui("management:setCounter", { id })}>
            <MapPin className="h-3.5 w-3.5" /> {_L("mgmt.set_counter")}
          </Button>
        </CardContent>
      </Card>

      <Card>
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

      <Card>
        <CardContent className="pt-4">
          <h3 className="mb-2 text-sm font-semibold">{_L("mgmt.stations_heading")}</h3>
          {stationProps.map((p: any) => (
            <div key={p.id} className="flex items-center justify-between py-1 text-sm">
              <span className="capitalize">{p.prop_type.replace("_", " ")}</span>
              <Button size="sm" variant="destructive" onClick={() => fetchNui("management:removeProp", { id, propId: p.id })}>
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
          {stationProps.length === 0 && <div className="text-xs text-muted-foreground">{_L("mgmt.no_stations")}</div>}
        </CardContent>
      </Card>
    </div>
  );
}
