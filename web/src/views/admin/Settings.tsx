import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Field, TextField, NumberField, Toggle, Select } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import {
  Settings2, Coins, Users, Bot, CupSoda, Sandwich, MapPin, Plus, Trash2, Save, Check, TriangleAlert,
} from "lucide-react";

const PERMISSIONS = [
  "cook", "sell", "manage_menu", "manage_props", "manage_employees", "view_finances", "manage_balance",
];

type Props = { settings: Record<string, any>; items: Item[]; onSaved: () => void };

const GROUPS = [
  { key: "general", label: "General", icon: Settings2 },
  { key: "economy", label: "Economy", icon: Coins },
  { key: "roles", label: "Default Roles", icon: Users },
  { key: "npc", label: "NPC Customers", icon: Bot },
  { key: "drinks", label: "Drinks", icon: CupSoda },
  { key: "assembly", label: "Assembly", icon: Sandwich },
  { key: "blip", label: "Map Blip", icon: MapPin },
];

export default function Settings({ settings, items, onSaved }: Props) {
  const [group, setGroup] = useState("general");

  return (
    <div className="flex min-h-0 flex-1 gap-4">
      {/* group nav */}
      <div className="w-44 shrink-0 space-y-1 overflow-y-auto pr-1">
        {GROUPS.map((g) => {
          const Icon = g.icon;
          return (
            <button
              key={g.key}
              onClick={() => setGroup(g.key)}
              className={cn(
                "flex w-full items-center gap-2 rounded-md px-3 py-2 text-left text-sm transition-colors",
                group === g.key ? "bg-primary/15 text-primary" : "hover:bg-accent"
              )}
            >
              <Icon className="h-4 w-4 shrink-0" />
              {g.label}
            </button>
          );
        })}
      </div>

      {/* group form */}
      <div className="min-w-0 flex-1 overflow-y-auto pr-1">
        {group === "general" && <General settings={settings} onSaved={onSaved} />}
        {group === "economy" && <Economy settings={settings} onSaved={onSaved} />}
        {group === "roles" && <Roles settings={settings} onSaved={onSaved} />}
        {group === "npc" && <Npc settings={settings} onSaved={onSaved} />}
        {group === "drinks" && <Drinks settings={settings} items={items} onSaved={onSaved} />}
        {group === "assembly" && <Assembly settings={settings} items={items} onSaved={onSaved} />}
        {group === "blip" && <Blip settings={settings} onSaved={onSaved} />}
      </div>
    </div>
  );
}

/** Section frame with a title and a sticky save button that confirms on click. */
function Section({
  title, description, onSave, children,
}: {
  title: string; description?: string; onSave: () => Promise<void> | void; children: React.ReactNode;
}) {
  const [saved, setSaved] = useState(false);
  const save = async () => {
    await onSave();
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  };
  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-semibold">{title}</h3>
          {description && <p className="text-xs text-muted-foreground">{description}</p>}
        </div>
        <Button size="sm" onClick={save}>
          {saved ? <><Check className="h-4 w-4" /> Saved</> : <><Save className="h-4 w-4" /> Save</>}
        </Button>
      </div>
      {children}
    </div>
  );
}

const saveSetting = (key: string, value: any) => fetchNui("admin:saveSetting", { key, value });

function General({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [cmd, setCmd] = useState(settings.admin_command ?? "restaurants");
  return (
    <Section
      title="General"
      description="Core command and behaviour."
      onSave={async () => { await saveSetting("admin_command", cmd); onSaved(); }}
    >
      <TextField label="Admin command" hint="Chat command admins run to open this panel." value={cmd} onChange={setCmd} />
    </Section>
  );
}

function Economy({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [currency, setCurrency] = useState(settings.currency ?? "money");
  const [starting, setStarting] = useState(Number(settings.starting_balance ?? 0));
  const [commission, setCommission] = useState(Number(settings.default_commission ?? 10));
  return (
    <Section
      title="Economy"
      description="Currency, opening balance and the fallback commission rate."
      onSave={async () => {
        await saveSetting("currency", currency);
        await saveSetting("starting_balance", starting);
        await saveSetting("default_commission", commission);
        onSaved();
      }}
    >
      <div className="grid grid-cols-2 gap-3">
        <Select
          label="Currency"
          value={currency}
          onChange={setCurrency}
          options={[{ value: "money", label: "Cash (money)" }, { value: "dirty", label: "Dirty money" }]}
        />
        <NumberField label="Starting balance" value={starting} min={0} onChange={setStarting} />
        <NumberField label="Default commission %" value={commission} min={0} onChange={setCommission} />
      </div>
    </Section>
  );
}

function Roles({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  // default_roles is a map keyed by grade number -> { label, commission, permissions }
  const initial = settings.default_roles ?? {};
  const [roles, setRoles] = useState<{ grade: string; label: string; commission: number; permissions: Record<string, boolean> }[]>(
    Object.keys(initial)
      .map((k) => ({
        grade: k,
        label: initial[k].label ?? `Grade ${k}`,
        commission: Number(initial[k].commission ?? 0),
        permissions: initial[k].permissions ?? {},
      }))
      .sort((a, b) => Number(a.grade) - Number(b.grade))
  );

  const update = (i: number, patch: any) => setRoles((rs) => rs.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  const togglePerm = (i: number, perm: string) =>
    setRoles((rs) => rs.map((r, idx) => (idx === i ? { ...r, permissions: { ...r.permissions, [perm]: !r.permissions[perm] } } : r)));
  const addRole = () => {
    const nextGrade = roles.reduce((m, r) => Math.max(m, Number(r.grade)), -1) + 1;
    setRoles((rs) => [...rs, { grade: String(nextGrade), label: `Grade ${nextGrade}`, commission: 0, permissions: {} }]);
  };
  const removeRole = (i: number) => setRoles((rs) => rs.filter((_, idx) => idx !== i));

  return (
    <Section
      title="Default Roles"
      description="The role ladder new restaurants start with. Owners can customise their own later."
      onSave={async () => {
        const map: Record<string, any> = {};
        roles.forEach((r) => {
          map[String(r.grade)] = { label: r.label, commission: r.commission, permissions: r.permissions };
        });
        await saveSetting("default_roles", map);
        onSaved();
      }}
    >
      <div className="space-y-3">
        {roles.map((r, i) => (
          <div key={i} className="rounded-lg border border-border p-3">
            <div className="flex items-end gap-2">
              <NumberField label="Grade" className="w-20" value={Number(r.grade)} min={0} onChange={(v) => update(i, { grade: String(v) })} />
              <TextField label="Label" className="flex-1" value={r.label} onChange={(v) => update(i, { label: v })} />
              <NumberField label="Commission %" className="w-28" value={r.commission} min={0} onChange={(v) => update(i, { commission: v })} />
              <Button size="icon" variant="destructive" onClick={() => removeRole(i)}><Trash2 className="h-4 w-4" /></Button>
            </div>
            <div className="mt-3 flex flex-wrap gap-2">
              {PERMISSIONS.map((p) => (
                <button
                  key={p}
                  onClick={() => togglePerm(i, p)}
                  className={cn(
                    "rounded-full border px-2.5 py-0.5 text-xs transition-colors",
                    r.permissions[p] ? "border-primary/30 bg-primary/15 text-primary" : "border-border text-muted-foreground hover:bg-accent"
                  )}
                >
                  {p.replace(/_/g, " ")}
                </button>
              ))}
            </div>
          </div>
        ))}
        <Button variant="outline" size="sm" onClick={addRole}><Plus className="h-4 w-4" /> Add role</Button>
      </div>
    </Section>
  );
}

function Npc({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const n = settings.npc ?? {};
  const [enabled, setEnabled] = useState(n.enabled !== false);
  const [max, setMax] = useState(Number(n.max ?? 2));
  const [interval, setInterval] = useState(Number(n.interval ?? 45000));
  const [patience, setPatience] = useState(Number(n.patience ?? 60000));
  const [models, setModels] = useState<string[]>(Array.isArray(n.models) ? n.models : []);
  const [modelInput, setModelInput] = useState("");

  return (
    <Section
      title="NPC Customers"
      description="Walk-in customers that queue at the counter."
      onSave={async () => { await saveSetting("npc", { enabled, max, interval, patience, models }); onSaved(); }}
    >
      <Toggle checked={enabled} onChange={setEnabled} label="Spawn NPC customers" />
      <div className="grid grid-cols-3 gap-3">
        <NumberField label="Max at once" value={max} min={0} onChange={setMax} />
        <NumberField label="Spawn interval (ms)" value={interval} min={0} step={1000} onChange={setInterval} />
        <NumberField label="Patience (ms)" value={patience} min={0} step={1000} onChange={setPatience} />
      </div>
      <Field label="Ped models" hint="Models picked at random for each customer.">
        <div className="mb-2 flex flex-wrap gap-1.5">
          {models.map((m) => (
            <Badge key={m} variant="secondary" className="gap-1">
              <span className="font-mono text-[10px]">{m}</span>
              <button onClick={() => setModels((ms) => ms.filter((x) => x !== m))}><Trash2 className="h-3 w-3" /></button>
            </Badge>
          ))}
          {models.length === 0 && <span className="text-xs text-muted-foreground">No models — defaults will be used.</span>}
        </div>
        <div className="flex gap-2">
          <input
            value={modelInput}
            onChange={(e) => setModelInput(e.target.value)}
            placeholder="a_m_y_business_01"
            className="h-9 flex-1 rounded-md border border-input bg-background/60 px-3 font-mono text-xs outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <Button size="sm" variant="outline" onClick={() => { if (modelInput.trim()) { setModels((ms) => [...new Set([...ms, modelInput.trim()])]); setModelInput(""); } }}>
            <Plus className="h-4 w-4" /> Add
          </Button>
        </div>
      </Field>
    </Section>
  );
}

function Blip({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const b = settings.blip ?? {};
  const [enabled, setEnabled] = useState(b.enabled !== false);
  const [sprite, setSprite] = useState(Number(b.sprite ?? 93));
  const [color, setColor] = useState(Number(b.color ?? 1));
  const [scale, setScale] = useState(Number(b.scale ?? 0.8));
  return (
    <Section
      title="Map Blip"
      description="Default blip applied to new restaurants."
      onSave={async () => { await saveSetting("blip", { enabled, sprite, color, scale }); onSaved(); }}
    >
      <Toggle checked={enabled} onChange={setEnabled} label="Show blip on the map" />
      <div className="grid grid-cols-3 gap-3">
        <NumberField label="Sprite" value={sprite} min={0} onChange={setSprite} />
        <NumberField label="Colour" value={color} min={0} onChange={setColor} />
        <NumberField label="Scale" value={scale} min={0} step={0.1} onChange={setScale} />
      </div>
    </Section>
  );
}

/** Shared list editor used by Drinks + Assembly — both reference items. */
function MissingBadge({ missing }: { missing: string[] }) {
  if (!missing?.length) return null;
  return (
    <Badge variant="destructive" className="gap-1">
      <TriangleAlert className="h-3 w-3" /> missing: {missing.join(", ")}
    </Badge>
  );
}

function Drinks({ settings, items, onSaved }: { settings: any; items: Item[]; onSaved: () => void }) {
  const [list, setList] = useState<any[]>(Array.isArray(settings.drinks) ? settings.drinks : []);
  const update = (i: number, patch: any) => setList((l) => l.map((d, idx) => (idx === i ? { ...d, ...patch } : d)));
  const add = () => setList((l) => [...l, { input: "", output: "", label: "", model: "pickle_drink_container_01", fill_ms: 3000 }]);
  const has = (name: string) => !name || items.some((it) => it.name === name);
  return (
    <Section
      title="Drinks"
      description="Soda-machine fills: a cup item becomes a filled drink item."
      onSave={async () => { await saveSetting("drinks", list); onSaved(); }}
    >
      <div className="space-y-3">
        {list.map((d, i) => {
          const missing = [d.input, d.output].filter((x) => x && !has(x));
          return (
            <div key={i} className="rounded-lg border border-border p-3">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-sm font-medium">{d.label || d.output || "New drink"}</span>
                <div className="flex items-center gap-2">
                  <MissingBadge missing={missing} />
                  <Button size="icon" variant="destructive" onClick={() => setList((l) => l.filter((_, idx) => idx !== i))}><Trash2 className="h-4 w-4" /></Button>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Field label="Cup item (input)"><ItemPicker items={items} value={d.input} onChange={(v) => update(i, { input: v })} /></Field>
                <Field label="Filled drink (output)"><ItemPicker items={items} value={d.output} onChange={(v) => update(i, { output: v })} /></Field>
                <TextField label="Label" value={d.label} onChange={(v) => update(i, { label: v })} />
                <TextField label="Prop model" value={d.model} onChange={(v) => update(i, { model: v })} />
                <NumberField label="Fill time (ms)" value={Number(d.fill_ms ?? 3000)} min={0} step={500} onChange={(v) => update(i, { fill_ms: v })} />
              </div>
            </div>
          );
        })}
        <Button variant="outline" size="sm" onClick={add}><Plus className="h-4 w-4" /> Add drink</Button>
      </div>
    </Section>
  );
}

function Assembly({ settings, items, onSaved }: { settings: any; items: Item[]; onSaved: () => void }) {
  const [list, setList] = useState<any[]>(Array.isArray(settings.assembly) ? settings.assembly : []);
  const update = (i: number, patch: any) => setList((l) => l.map((a, idx) => (idx === i ? { ...a, ...patch } : a)));
  const add = () => setList((l) => [...l, { output: "", label: "", model: "pickle_bread_bun_01", components: [] }]);
  const has = (name: string) => !name || items.some((it) => it.name === name);
  return (
    <Section
      title="Assembly"
      description="Kitchen-prep recipes: combine component items into a finished item."
      onSave={async () => { await saveSetting("assembly", list); onSaved(); }}
    >
      <div className="space-y-3">
        {list.map((a, i) => {
          const comps: string[] = a.components ?? [];
          const missing = [a.output, ...comps].filter((x) => x && !has(x));
          return (
            <div key={i} className="rounded-lg border border-border p-3">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-sm font-medium">{a.label || a.output || "New recipe"}</span>
                <div className="flex items-center gap-2">
                  <MissingBadge missing={missing} />
                  <Button size="icon" variant="destructive" onClick={() => setList((l) => l.filter((_, idx) => idx !== i))}><Trash2 className="h-4 w-4" /></Button>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Field label="Result item (output)"><ItemPicker items={items} value={a.output} onChange={(v) => update(i, { output: v })} /></Field>
                <TextField label="Label" value={a.label} onChange={(v) => update(i, { label: v })} />
                <TextField label="Prop model" value={a.model} onChange={(v) => update(i, { model: v })} />
              </div>
              <Field label="Components" className="mt-3">
                <div className="space-y-2">
                  {comps.map((c, ci) => (
                    <div key={ci} className="flex gap-2">
                      <ItemPicker className="flex-1" items={items} value={c} onChange={(v) => update(i, { components: comps.map((x, idx) => (idx === ci ? v : x)) })} />
                      <Button size="icon" variant="ghost" onClick={() => update(i, { components: comps.filter((_, idx) => idx !== ci) })}><Trash2 className="h-4 w-4" /></Button>
                    </div>
                  ))}
                  <Button size="sm" variant="outline" onClick={() => update(i, { components: [...comps, ""] })}><Plus className="h-4 w-4" /> Add component</Button>
                </div>
              </Field>
            </div>
          );
        })}
        <Button variant="outline" size="sm" onClick={add}><Plus className="h-4 w-4" /> Add recipe</Button>
      </div>
    </Section>
  );
}
