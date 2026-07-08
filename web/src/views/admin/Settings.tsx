import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave, type SaveStatus } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Field, TextField, NumberField, Toggle, Select, GroupField } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  Settings2, Coins, Users, CupSoda, Sandwich, MapPin, Plus, Trash2, Check, Loader2, TriangleAlert,
} from "lucide-react";

const PERMISSIONS = [
  "cook", "sell", "manage_menu", "manage_props", "manage_employees", "view_finances", "manage_balance",
];

type Props = { settings: Record<string, any>; items: Item[]; groups: string[]; onSaved: () => void };

const GROUPS = [
  { key: "general", label: _L("settings.group_general"), icon: Settings2 },
  { key: "economy", label: _L("settings.group_economy"), icon: Coins },
  { key: "roles", label: _L("settings.group_roles"), icon: Users },
  { key: "drinks", label: _L("settings.group_drinks"), icon: CupSoda },
  { key: "assembly", label: _L("settings.group_assembly"), icon: Sandwich },
  { key: "blip", label: _L("settings.group_blip"), icon: MapPin },
];

export default function Settings({ settings, items, groups, onSaved }: Props) {
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
        {group === "drinks" && <Drinks settings={settings} items={items} groups={groups} onSaved={onSaved} />}
        {group === "assembly" && <Assembly settings={settings} items={items} groups={groups} onSaved={onSaved} />}
        {group === "blip" && <Blip settings={settings} onSaved={onSaved} />}
      </div>
    </div>
  );
}

/** Section frame with a title and an auto-save status hint (no Save button — edits
 * persist automatically, debounced). */
function Section({
  title, description, status, children,
}: {
  title: string; description?: string; status?: SaveStatus; children: React.ReactNode;
}) {
  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-semibold">{title}</h3>
          {description && <p className="text-xs text-muted-foreground">{description}</p>}
        </div>
        <SaveStatusHint status={status} />
      </div>
      {children}
    </div>
  );
}

function SaveStatusHint({ status }: { status?: SaveStatus }) {
  if (!status || status === "idle") return <span className="text-xs text-muted-foreground/60">{_L("settings.auto_saves")}</span>;
  return (
    <span className="flex shrink-0 items-center gap-1 text-xs text-muted-foreground">
      {status === "saving"
        ? <><Loader2 className="h-3 w-3 animate-spin" /> {_L("settings.saving")}</>
        : <><Check className="h-3 w-3 text-primary" /> {_L("settings.saved")}</>}
    </span>
  );
}

// Batched save: the whole group's keys go up together, so an auto-save writes once
// (one sync + one in-game "Settings saved." notification), not per field.
const saveSettings = (obj: Record<string, any>) => fetchNui("admin:saveSettings", { settings: obj });

function General({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [cmd, setCmd] = useState(settings.admin_command ?? "restaurants");
  const [expire, setExpire] = useState(Number(settings.cooked_expire_seconds ?? 0));
  const status = useAutoSave(
    () => saveSettings({ admin_command: cmd, cooked_expire_seconds: Math.max(0, Math.floor(expire || 0)) }).then(onSaved),
    [cmd, expire]
  );
  return (
    <Section title={_L("settings.general_title")} description={_L("settings.general_desc")} status={status}>
      <TextField label={_L("settings.admin_command")} hint={_L("settings.admin_command_hint")} value={cmd} onChange={setCmd} />
      <NumberField
        label={_L("settings.cooked_expiry")}
        hint={_L("settings.cooked_expiry_hint")}
        value={expire} min={0} step={10} onChange={setExpire}
      />
    </Section>
  );
}

function Economy({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [currency, setCurrency] = useState(settings.currency ?? "money");
  const [starting, setStarting] = useState(Number(settings.starting_balance ?? 0));
  const [commission, setCommission] = useState(Number(settings.default_commission ?? 10));
  const status = useAutoSave(
    () => saveSettings({ currency, starting_balance: starting, default_commission: commission }).then(onSaved),
    [currency, starting, commission]
  );
  return (
    <Section title={_L("settings.economy_title")} description={_L("settings.economy_desc")} status={status}>
      <div className="grid grid-cols-2 gap-3">
        <Select
          label={_L("settings.currency")}
          value={currency}
          onChange={setCurrency}
          options={[{ value: "money", label: _L("settings.currency_cash") }, { value: "dirty", label: _L("settings.currency_dirty") }]}
        />
        <NumberField label={_L("settings.starting_balance")} value={starting} min={0} onChange={setStarting} />
        <NumberField label={_L("settings.default_commission")} value={commission} min={0} onChange={setCommission} />
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
        label: initial[k].label ?? _L("settings.grade_n", k),
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
    setRoles((rs) => [...rs, { grade: String(nextGrade), label: _L("settings.grade_n", nextGrade), commission: 0, permissions: {} }]);
  };
  const removeRole = (i: number) => setRoles((rs) => rs.filter((_, idx) => idx !== i));

  const status = useAutoSave(() => {
    const map: Record<string, any> = {};
    roles.forEach((r) => { map[String(r.grade)] = { label: r.label, commission: r.commission, permissions: r.permissions }; });
    return saveSettings({ default_roles: map }).then(onSaved);
  }, [roles]);

  return (
    <Section
      title={_L("settings.roles_title")}
      description={_L("settings.roles_desc")}
      status={status}
    >
      <div className="space-y-3">
        {roles.map((r, i) => (
          <div key={i} className="rounded-lg border border-border p-3">
            <div className="flex items-end gap-2">
              <NumberField label={_L("settings.grade")} className="w-20" value={Number(r.grade)} min={0} onChange={(v) => update(i, { grade: String(v) })} />
              <TextField label={_L("settings.label")} className="flex-1" value={r.label} onChange={(v) => update(i, { label: v })} />
              <NumberField label={_L("settings.commission")} className="w-28" value={r.commission} min={0} onChange={(v) => update(i, { commission: v })} />
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
        <Button variant="outline" size="sm" onClick={addRole}><Plus className="h-4 w-4" /> {_L("settings.add_role")}</Button>
      </div>
    </Section>
  );
}

function Blip({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const b = settings.blip ?? {};
  const [enabled, setEnabled] = useState(b.enabled !== false);
  const [sprite, setSprite] = useState(Number(b.sprite ?? 93));
  const [color, setColor] = useState(Number(b.color ?? 1));
  const [scale, setScale] = useState(Number(b.scale ?? 0.8));
  const status = useAutoSave(
    () => saveSettings({ blip: { enabled, sprite, color, scale } }).then(onSaved),
    [enabled, sprite, color, scale]
  );
  return (
    <Section title={_L("settings.blip_title")} description={_L("settings.blip_desc")} status={status}>
      <Toggle checked={enabled} onChange={setEnabled} label={_L("settings.blip_show")} />
      <div className="grid grid-cols-3 gap-3">
        <NumberField label={_L("settings.blip_sprite")} value={sprite} min={0} onChange={setSprite} />
        <NumberField label={_L("settings.blip_colour")} value={color} min={0} onChange={setColor} />
        <NumberField label={_L("settings.blip_scale")} value={scale} min={0} step={0.1} onChange={setScale} />
      </div>
    </Section>
  );
}

/** Shared list editor used by Drinks + Assembly — both reference items. */
function MissingBadge({ missing }: { missing: string[] }) {
  if (!missing?.length) return null;
  return (
    <Badge variant="destructive" className="gap-1">
      <TriangleAlert className="h-3 w-3" /> {_L("settings.missing")} {missing.join(", ")}
    </Badge>
  );
}

function Drinks({ settings, items, groups, onSaved }: { settings: any; items: Item[]; groups: string[]; onSaved: () => void }) {
  const [list, setList] = useState<any[]>(Array.isArray(settings.drinks) ? settings.drinks : []);
  const update = (i: number, patch: any) => setList((l) => l.map((d, idx) => (idx === i ? { ...d, ...patch } : d)));
  const add = () => setList((l) => [...l, { input: "", output: "", label: "", model: "pickle_drink_container_01", fill_ms: 3000 }]);
  const has = (name: string) => !name || items.some((it) => it.name === name);
  const status = useAutoSave(() => saveSettings({ drinks: list }).then(onSaved), [list]);
  return (
    <Section
      title={_L("settings.drinks_title")}
      description={_L("settings.drinks_desc")}
      status={status}
    >
      <div className="space-y-3">
        {list.map((d, i) => {
          const missing = [d.input, d.output].filter((x) => x && !has(x));
          return (
            <div key={i} className="rounded-lg border border-border p-3">
              <div className="mb-2 flex items-center justify-between">
                <span className="flex items-center gap-2 text-sm font-medium">
                  {d.label || d.output || _L("settings.new_drink")}
                  <Badge variant="secondary">{i < 6 ? _L("settings.tap_n", i + 1) : _L("settings.no_tap")}</Badge>
                </span>
                <div className="flex items-center gap-2">
                  <MissingBadge missing={missing} />
                  <Button size="icon" variant="destructive" onClick={() => setList((l) => l.filter((_, idx) => idx !== i))}><Trash2 className="h-4 w-4" /></Button>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Field label={_L("settings.cup_input")}><ItemPicker items={items} value={d.input} onChange={(v) => update(i, { input: v })} /></Field>
                <Field label={_L("settings.filled_output")}><ItemPicker items={items} value={d.output} onChange={(v) => update(i, { output: v })} /></Field>
                <TextField label={_L("settings.label")} value={d.label} onChange={(v) => update(i, { label: v })} />
                <TextField label={_L("settings.prop_model")} value={d.model} onChange={(v) => update(i, { model: v })} />
                <NumberField label={_L("settings.fill_time")} value={Number(d.fill_ms ?? 3000)} min={0} step={500} onChange={(v) => update(i, { fill_ms: v })} />
                <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
                  value={d.group || ""} groups={groups} onChange={(v) => update(i, { group: v })} />
              </div>
            </div>
          );
        })}
        <Button variant="outline" size="sm" onClick={add}><Plus className="h-4 w-4" /> {_L("settings.add_drink")}</Button>
      </div>
    </Section>
  );
}

function Assembly({ settings, items, groups, onSaved }: { settings: any; items: Item[]; groups: string[]; onSaved: () => void }) {
  const [list, setList] = useState<any[]>(Array.isArray(settings.assembly) ? settings.assembly : []);
  const update = (i: number, patch: any) => setList((l) => l.map((a, idx) => (idx === i ? { ...a, ...patch } : a)));
  const add = () => setList((l) => [...l, { output: "", label: "", model: "pickle_bread_bun_01", components: [] }]);
  const has = (name: string) => !name || items.some((it) => it.name === name);
  const status = useAutoSave(() => saveSettings({ assembly: list }).then(onSaved), [list]);
  return (
    <Section
      title={_L("settings.assembly_title")}
      description={_L("settings.assembly_desc")}
      status={status}
    >
      <div className="space-y-3">
        {list.map((a, i) => {
          const comps: string[] = a.components ?? [];
          const missing = [a.output, ...comps].filter((x) => x && !has(x));
          return (
            <div key={i} className="rounded-lg border border-border p-3">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-sm font-medium">{a.label || a.output || _L("settings.new_recipe")}</span>
                <div className="flex items-center gap-2">
                  <MissingBadge missing={missing} />
                  <Button size="icon" variant="destructive" onClick={() => setList((l) => l.filter((_, idx) => idx !== i))}><Trash2 className="h-4 w-4" /></Button>
                </div>
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Field label={_L("settings.result_output")}><ItemPicker items={items} value={a.output} onChange={(v) => update(i, { output: v })} /></Field>
                <TextField label={_L("settings.label")} value={a.label} onChange={(v) => update(i, { label: v })} />
                <TextField label={_L("settings.prop_model")} value={a.model} onChange={(v) => update(i, { model: v })} />
                <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
                  value={a.group || ""} groups={groups} onChange={(v) => update(i, { group: v })} />
              </div>
              <Field label={_L("settings.components")} className="mt-3">
                <div className="space-y-2">
                  {comps.map((c, ci) => (
                    <div key={ci} className="flex gap-2">
                      <ItemPicker className="flex-1" items={items} value={c} onChange={(v) => update(i, { components: comps.map((x, idx) => (idx === ci ? v : x)) })} />
                      <Button size="icon" variant="ghost" onClick={() => update(i, { components: comps.filter((_, idx) => idx !== ci) })}><Trash2 className="h-4 w-4" /></Button>
                    </div>
                  ))}
                  <Button size="sm" variant="outline" onClick={() => update(i, { components: [...comps, ""] })}><Plus className="h-4 w-4" /> {_L("settings.add_component")}</Button>
                </div>
              </Field>
            </div>
          );
        })}
        <Button variant="outline" size="sm" onClick={add}><Plus className="h-4 w-4" /> {_L("settings.add_recipe")}</Button>
      </div>
    </Section>
  );
}
