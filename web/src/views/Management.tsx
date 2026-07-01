import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Field, TextField, NumberField } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { money } from "@/lib/utils";
import { UserPlus, Trash2, Plus, MapPin, Banknote, TriangleAlert, Image } from "lucide-react";

export default function Management({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const perms = data?.perms || {};
  const roles: any[] = data?.roles || [];
  const items: Item[] = data?.items || [];

  return (
    <Panel title={data?.restaurant?.label || "Management"} subtitle={`Balance ${money(data?.restaurant?.balance)}`} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue={firstTab(perms)} className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          {perms.manage_employees && <TabsTrigger value="employees">Employees</TabsTrigger>}
          {perms.manage_menu && <TabsTrigger value="menu">Menu</TabsTrigger>}
          {perms.view_finances && <TabsTrigger value="finances">Finances</TabsTrigger>}
          {perms.manage_props && <TabsTrigger value="stations">Stations</TabsTrigger>}
        </TabsList>

        {perms.manage_employees && (
          <TabsContent value="employees" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Employees id={id} roles={roles} employees={data?.employees || []} nearby={data?.nearby || []} />
          </TabsContent>
        )}
        {perms.manage_menu && (
          <TabsContent value="menu" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Menu id={id} menu={data?.menu || []} items={items} />
          </TabsContent>
        )}
        {perms.view_finances && (
          <TabsContent value="finances" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Finances id={id} balance={data?.restaurant?.balance} ledger={data?.ledger || []} canManage={!!perms.manage_balance} />
          </TabsContent>
        )}
        {perms.manage_props && (
          <TabsContent value="stations" className="min-h-0 flex-1 overflow-y-auto pr-1">
            <Stations id={id} props={data?.props || []} stock={data?.stock || []} brand={data?.restaurant?.brand_image || ""} />
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
            <label className="mb-1 block text-xs text-muted-foreground">Nearby player</label>
            <select className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm" value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="">Select…</option>
              {nearby.map((p: any) => <option key={p.id} value={p.id}>{p.name} [{p.id}]</option>)}
            </select>
          </div>
          <div>
            <label className="mb-1 block text-xs text-muted-foreground">Grade</label>
            <select className="h-9 rounded-md border border-input bg-background px-2 text-sm" value={grade} onChange={(e) => setGrade(Number(e.target.value))}>
              {roles.map((r: any) => <option key={r.grade} value={r.grade}>{r.label}</option>)}
            </select>
          </div>
          <Button disabled={!target} onClick={() => fetchNui("management:hire", { id, target: Number(target), grade })}>
            <UserPlus className="h-4 w-4" /> Hire
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
      {employees.length === 0 && <div className="py-4 text-center text-sm text-muted-foreground">No employees yet.</div>}
    </div>
  );
}

function Menu({ id, menu, items }: { id: number; menu: any[]; items: Item[] }) {
  const blank = { item: "", label: "", price: 0, category: "food", enabled: true };
  const [form, setForm] = useState<any>(blank);
  const set = (k: string, v: any) => setForm((f: any) => ({ ...f, [k]: v }));
  const known = (name: string) => !name || items.some((i) => i.name === name);
  return (
    <div className="space-y-3">
      <div className="rounded-lg border border-border p-3">
        <div className="grid grid-cols-5 items-end gap-2">
          <Field label="Item" className="col-span-2">
            <ItemPicker items={items} value={form.item} onChange={(v) => set("item", v)} />
          </Field>
          <TextField label="Label" value={form.label} onChange={(v) => set("label", v)} />
          <NumberField label="Price" value={form.price} min={0} onChange={(v) => set("price", v)} />
          <Button onClick={() => { if (form.item) { fetchNui("management:saveMenuItem", { id, ...form, label: form.label || form.item, enabled: true }); setForm(blank); } }}>
            <Plus className="h-4 w-4" /> Save
          </Button>
        </div>
        <p className="mt-2 text-[11px] text-muted-foreground">Pick the item players receive when they buy this menu entry.</p>
      </div>

      {menu.map((m: any) => (
        <Card key={m.item}>
          <CardContent className="flex items-center justify-between pt-4 text-sm">
            <div className="min-w-0">
              <div className="flex items-center gap-2">
                <span className="truncate font-medium">{m.label}</span>
                {!known(m.item) && <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> unknown item</Badge>}
              </div>
              <span className="text-xs text-muted-foreground">{m.item} · {money(m.price)} · {m.category}</span>
            </div>
            <div className="flex items-center gap-2">
              <Button size="sm" variant="outline" onClick={() => fetchNui("management:saveMenuItem", { id, ...m, enabled: m.enabled ? 0 : 1 })}>
                {m.enabled ? "Disable" : "Enable"}
              </Button>
              <Button size="sm" variant="destructive" onClick={() => fetchNui("management:deleteMenuItem", { id, item: m.item })}>
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          </CardContent>
        </Card>
      ))}
      {menu.length === 0 && <div className="py-4 text-center text-sm text-muted-foreground">No menu items yet.</div>}
    </div>
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
              <Button size="sm" onClick={() => fetchNui("management:deposit", { id, amount })}>Deposit</Button>
              <Button size="sm" variant="outline" onClick={() => fetchNui("management:withdraw", { id, amount })}>Withdraw</Button>
            </div>
          )}
        </CardContent>
      </Card>
      <div className="rounded-lg border border-border">
        <div className="grid grid-cols-4 border-b border-border px-3 py-2 text-xs font-semibold text-muted-foreground">
          <span>Type</span><span>Amount</span><span className="col-span-2">Description</span>
        </div>
        {ledger.map((l: any, i: number) => (
          <div key={i} className="grid grid-cols-4 px-3 py-1.5 text-xs">
            <span className="capitalize">{l.type}</span>
            <span className={l.amount < 0 ? "text-destructive" : "text-emerald-400"}>{money(l.amount)}</span>
            <span className="col-span-2 truncate text-muted-foreground">{l.description}</span>
          </div>
        ))}
        {ledger.length === 0 && <div className="px-3 py-3 text-xs text-muted-foreground">No transactions yet.</div>}
      </div>
    </div>
  );
}

function Stations({ id, props, stock, brand }: any) {
  const STATIONS = ["soda_machine", "fryer", "stovetop", "kitchen_prep"];
  return (
    <div className="space-y-3">
      <Card>
        <CardContent className="pt-4">
          <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold"><Image className="h-4 w-4" /> Branding</h3>
          <Input
            defaultValue={brand}
            placeholder="https://…/logo.png — image shown on cups, boxes, trays"
            className="h-9"
            onBlur={(e) => fetchNui("management:setBrandImage", { id, url: e.target.value.trim() })}
          />
          <p className="mt-1.5 text-[11px] text-muted-foreground">
            Direct image URL. It replaces the brand texture on this restaurant's food packaging. Leave blank to reset.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="flex flex-wrap items-center gap-2 pt-4">
          {STATIONS.map((s) => (
            <Button key={s} variant="outline" size="sm" onClick={() => fetchNui("management:placeProp", { id, prop_type: s })}>
              <MapPin className="h-3.5 w-3.5" /> place {s.replace("_", " ")}
            </Button>
          ))}
          <Button variant="outline" size="sm" onClick={() => fetchNui("management:setCounter", { id })}>
            <MapPin className="h-3.5 w-3.5" /> set counter
          </Button>
        </CardContent>
      </Card>

      <div className="grid grid-cols-2 gap-3">
        <Card>
          <CardContent className="pt-4">
            <h3 className="mb-2 text-sm font-semibold">Stations</h3>
            {props.map((p: any) => (
              <div key={p.id} className="flex items-center justify-between py-1 text-sm">
                <span className="capitalize">{p.prop_type.replace("_", " ")}</span>
                <Button size="sm" variant="destructive" onClick={() => fetchNui("management:removeProp", { id, propId: p.id })}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            ))}
            {props.length === 0 && <div className="text-xs text-muted-foreground">No stations placed.</div>}
          </CardContent>
        </Card>
        <Card>
          <CardContent className="pt-4">
            <h3 className="mb-2 text-sm font-semibold">Counter stock</h3>
            {stock.map((s: any) => (
              <div key={s.item} className="flex items-center justify-between py-1 text-sm">
                <span>{s.label}</span>
                <Badge variant="secondary">{s.count}</Badge>
              </div>
            ))}
            {stock.length === 0 && <div className="text-xs text-muted-foreground">No stock. Cook & stock items at the register.</div>}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
