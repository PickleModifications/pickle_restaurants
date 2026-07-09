import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave, type SaveStatus } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Field, TextField, NumberField, Toggle, Select } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  Settings2, Coins, Users, DollarSign, MapPin, Plus, Trash2, Check, Loader2, RotateCcw,
} from "lucide-react";

const PERMISSIONS = [
  "cook", "sell", "manage_menu", "manage_props", "manage_employees", "view_finances", "manage_balance", "manage_stock",
];

type Props = { settings: Record<string, any>; items: Item[]; groups: string[]; onSaved: () => void };

// Drinks + Assembly editors moved to the Menu tab (foods live together there).
const GROUPS = [
  { key: "general", label: _L("settings.group_general"), icon: Settings2 },
  { key: "economy", label: _L("settings.group_economy"), icon: Coins },
  { key: "pricing", label: _L("settings.group_pricing"), icon: DollarSign },
  { key: "roles", label: _L("settings.group_roles"), icon: Users },
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
        {group === "pricing" && <Pricing settings={settings} items={items} onSaved={onSaved} />}
        {group === "roles" && <Roles settings={settings} onSaved={onSaved} />}
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
      <ResetRecipes onSaved={onSaved} />
    </Section>
  );
}

/** Destructive maintenance action: wipe every recipe and reseed the built-in
 * defaults. Two-step confirm (no accidental resets); refreshes the panel after. */
function ResetRecipes({ onSaved }: { onSaved: () => void }) {
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const reset = async () => {
    setBusy(true);
    await fetchNui("admin:resetRecipes");
    setBusy(false);
    setConfirm(false);
    onSaved();
  };
  return (
    <div className="mt-2 rounded-lg border border-destructive/40 bg-destructive/5 p-3">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="text-sm font-medium">{_L("settings.reset_recipes")}</div>
          <p className="text-xs text-muted-foreground">{_L("settings.reset_recipes_desc")}</p>
        </div>
        {!confirm && (
          <Button variant="destructive" size="sm" className="shrink-0" onClick={() => setConfirm(true)}>
            <RotateCcw className="h-4 w-4" /> {_L("settings.reset_recipes_btn")}
          </Button>
        )}
      </div>
      {confirm && (
        <div className="mt-3 flex items-center justify-between gap-2">
          <span className="text-xs text-destructive">{_L("settings.reset_recipes_confirm")}</span>
          <div className="flex shrink-0 gap-2">
            <Button variant="ghost" size="sm" disabled={busy} onClick={() => setConfirm(false)}>{_L("settings.reset_recipes_cancel")}</Button>
            <Button variant="destructive" size="sm" disabled={busy} onClick={reset}>
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />} {_L("settings.reset_recipes_confirm_btn")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function Economy({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [currency, setCurrency] = useState(settings.currency ?? "money");
  const [starting, setStarting] = useState(Number(settings.starting_balance ?? 0));
  const [commission, setCommission] = useState(Number(settings.default_commission ?? 10));
  const [margin, setMargin] = useState(Number(settings.profit_margin ?? 40));
  const status = useAutoSave(
    () => saveSettings({ currency, starting_balance: starting, default_commission: commission, profit_margin: Math.max(0, Math.floor(margin || 0)) }).then(onSaved),
    [currency, starting, commission, margin]
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
        <NumberField label={_L("settings.profit_margin")} hint={_L("settings.profit_margin_hint")} value={margin} min={0} onChange={setMargin} />
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

/** Ingredient cost map (raw item -> cost). Drives restock spend and the default
 * menu price. Stored as an object; edited here as a list of {item, cost} rows. */
function Pricing({ settings, items, onSaved }: { settings: any; items: Item[]; onSaved: () => void }) {
  const initial = settings.ingredient_costs && typeof settings.ingredient_costs === "object" ? settings.ingredient_costs : {};
  const [rows, setRows] = useState<{ item: string; cost: number }[]>(
    Object.keys(initial).map((k) => ({ item: k, cost: Number(initial[k]) || 0 })).sort((a, b) => a.item.localeCompare(b.item))
  );
  const update = (i: number, patch: any) => setRows((l) => l.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  const add = () => setRows((l) => [...l, { item: "", cost: 0 }]);

  const status = useAutoSave(() => {
    const map: Record<string, number> = {};
    rows.forEach((r) => { if (r.item) map[r.item] = Math.max(0, Math.floor(r.cost || 0)); });
    return saveSettings({ ingredient_costs: map }).then(onSaved);
  }, [rows]);

  return (
    <Section title={_L("settings.pricing_title")} description={_L("settings.pricing_desc")} status={status}>
      <div className="space-y-2">
        {rows.length === 0 && <div className="py-2 text-xs text-muted-foreground">{_L("settings.no_costs")}</div>}
        {rows.map((r, i) => (
          <div key={i} className="flex items-end gap-2">
            <Field label={_L("settings.ingredient")} className="flex-1">
              <ItemPicker items={items} value={r.item} onChange={(v) => update(i, { item: v })} />
            </Field>
            <NumberField label={_L("settings.cost_value")} className="w-28" value={r.cost} min={0} onChange={(v) => update(i, { cost: v })} />
            <Button size="icon" variant="destructive" onClick={() => setRows((l) => l.filter((_, idx) => idx !== i))}><Trash2 className="h-4 w-4" /></Button>
          </div>
        ))}
        <Button variant="outline" size="sm" onClick={add}><Plus className="h-4 w-4" /> {_L("settings.add_cost")}</Button>
      </div>
    </Section>
  );
}
