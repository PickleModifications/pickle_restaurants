import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Field, TextField, NumberField, Select, Toggle, GroupField } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Plus, Trash2, TriangleAlert, ImageOff } from "lucide-react";

// ─── shared item thumbnail ─────────────────────────────────────────────────────
// Inventory thumbnail for an item, with a graceful fallback when the image is
// missing or fails to load (different inventories store images differently).
export function ItemImage({ items, name, className }: { items: Item[]; name: string; className?: string }) {
  const img = items.find((i) => i.name === name)?.image;
  const [broken, setBroken] = useState(false);
  useEffect(() => setBroken(false), [img]); // a different item gets a fresh try
  if (!name || !img || broken) {
    return (
      <div className={cn("flex items-center justify-center rounded bg-muted/60 text-muted-foreground", className)}>
        <ImageOff className="h-1/2 w-1/2" />
      </div>
    );
  }
  return <img src={img} alt={name} onError={() => setBroken(true)} className={cn("rounded bg-muted/40 object-contain", className)} />;
}

// "frosting" / "raw_beef_patty" -> "Frosting" / "Raw Beef Patty". Fallback for a
// codename with no catalogue label, so names never render lowercase.
export function prettyName(name: string) {
  return name.replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

export function labelOf(items: Item[], name: string) {
  if (!name) return "—";
  return items.find((i) => i.name === name)?.label ?? prettyName(name);
}

// ─── cooked recipe ─────────────────────────────────────────────────────────────

export type Recipe = {
  input_item: string; station: string;
  raw_model: string; cooked_model: string; burnt_model: string;
  output_cooked_item: string; output_burnt_item: string;
  cook_ms: number; burn_ms: number;
  output_count?: number;
  dual_sided?: boolean | number;
  method?: string;
  container_model?: string;
  expire_seconds?: number | null;
  group?: string | null;
  valid?: boolean; missing?: string[];
  invalid_models?: string[];
};

export const BLANK_RECIPE: Recipe = {
  input_item: "", station: "fryer", raw_model: "", cooked_model: "", burnt_model: "",
  output_cooked_item: "", output_burnt_item: "", cook_ms: 15000, burn_ms: 15000, method: "fry",
};

// Friendly station labels for the read-only list badge (the raw value is lowercase).
export const STATION_LABEL: Record<string, string> = {
  fryer: _L("recipes.station_fryer"),
  stovetop: _L("recipes.station_stovetop"),
};

// The cook methods valid for a station (fryer is always a basket fry).
export const METHODS: Record<string, { value: string; label: string }[]> = {
  fryer: [{ value: "fry", label: _L("recipes.method_fry") }],
  stovetop: [
    { value: "grill", label: _L("recipes.method_grill") },
    { value: "oven", label: _L("recipes.method_oven") },
  ],
};

export function RecipeForm({ form, setForm, items, groups }: { form: Recipe; setForm: (r: Recipe) => void; items: Item[]; groups: string[] }) {
  const set = (k: keyof Recipe, v: any) => setForm({ ...form, [k]: v });
  const badModels = new Set(form.invalid_models || []);

  // Render-functions (not nested components) so the inputs keep focus/state
  // across re-renders instead of remounting on every keystroke.
  const itemField = (label: string, k: keyof Recipe) => (
    <Field label={label}>
      <div className="flex items-center gap-2">
        <ItemImage items={items} name={(form[k] as string) || ""} className="h-9 w-9 shrink-0" />
        <div className="min-w-0 flex-1">
          <ItemPicker items={items} value={(form[k] as string) || ""} onChange={(v) => set(k, v)} />
        </div>
      </div>
    </Field>
  );

  const modelField = (label: string, k: keyof Recipe) => {
    const val = (form[k] as string) || "";
    const invalid = !!val && badModels.has(val);
    return (
      <div>
        <TextField label={label} value={val} onChange={(v) => set(k, v)} />
        {invalid && (
          <div className="mt-1 flex items-center gap-1 text-[11px] text-amber-500">
            <TriangleAlert className="h-3 w-3" /> {_L("recipes.not_found")}
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="grid grid-cols-3 gap-3">
      {itemField(_L("recipes.input_item"), "input_item")}
      {itemField(_L("recipes.cooked_output"), "output_cooked_item")}
      <div />
      <Select label={_L("recipes.station")} value={form.station}
        onChange={(v) => setForm({ ...form, station: v, method: (METHODS[v] || [])[0]?.value || "grill" })}
        options={[{ value: "fryer", label: _L("recipes.station_fryer") }, { value: "stovetop", label: _L("recipes.station_stovetop") }]} />
      <Select label={_L("recipes.method")} value={form.method || (METHODS[form.station] || [])[0]?.value || "grill"}
        onChange={(v) => set("method", v)} options={METHODS[form.station] || METHODS.stovetop} />
      <div />
      {modelField(_L("recipes.raw_model"), "raw_model")}
      {modelField(_L("recipes.cooked_model"), "cooked_model")}
      {modelField(_L("recipes.burnt_model"), "burnt_model")}
      <NumberField label={_L("recipes.cook_time")} value={form.cook_ms} min={0} step={1000} onChange={(v) => set("cook_ms", v)} />
      <NumberField label={_L("recipes.burn_time")} value={form.burn_ms} min={0} step={1000} onChange={(v) => set("burn_ms", v)} />
      <NumberField label={_L("recipes.output_count")} value={form.output_count ?? 1} min={1} step={1}
        onChange={(v) => set("output_count", v)} />
      {modelField(_L("recipes.container_model"), "container_model")}
      <TextField label={_L("recipes.expiry")}
        hint={_L("recipes.expiry_hint")}
        value={form.expire_seconds == null ? "" : String(form.expire_seconds)}
        onChange={(v) => set("expire_seconds", (v === "" ? null : Number(v)) as never)} />
      <GroupField label={_L("recipes.group")} hint={_L("recipes.group_hint")}
        value={form.group || ""} groups={groups} onChange={(v) => set("group", v)} />
      {form.station === "stovetop" && (
        <div className="col-span-3">
          <Toggle checked={!!form.dual_sided} onChange={(v) => set("dual_sided", v)}
            label={_L("recipes.dual_sided")} />
        </div>
      )}
    </div>
  );
}

// ─── drink (soda tap) ──────────────────────────────────────────────────────────
// A drink is one entry in the `drinks` settings array. `onChange` patches the
// entry; the parent owns the array and auto-saves it whole.

export function DrinkFields({ drink, onChange, items, groups }: { drink: any; onChange: (patch: any) => void; items: Item[]; groups: string[] }) {
  return (
    <div className="grid grid-cols-2 gap-3">
      <Field label={_L("settings.cup_input")}><ItemPicker items={items} value={drink.input} onChange={(v) => onChange({ input: v })} /></Field>
      <Field label={_L("settings.filled_output")}><ItemPicker items={items} value={drink.output} onChange={(v) => onChange({ output: v })} /></Field>
      <TextField label={_L("settings.label")} value={drink.label} onChange={(v) => onChange({ label: v })} />
      <TextField label={_L("settings.prop_model")} value={drink.model} onChange={(v) => onChange({ model: v })} />
      <NumberField label={_L("settings.fill_time")} value={Number(drink.fill_ms ?? 3000)} min={0} step={500} onChange={(v) => onChange({ fill_ms: v })} />
      <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
        value={drink.group || ""} groups={groups} onChange={(v) => onChange({ group: v })} />
    </div>
  );
}

// ─── finish (frosting/sprinkles) ────────────────────────────────────────────────
// A finish's full config (tool, targets, flavors, models) is authored in the
// settings table — the panel exposes only the two things a boss tunes day-to-day:
// its stock/ingredient cost (drives the buy price in Supplies AND the default menu
// price) and the access group. There is deliberately no delete here.

export function FinishFields({ finish, cost, onChangeFinish, onChangeCost, groups }:
  { finish: any; cost: number; onChangeFinish: (patch: any) => void; onChangeCost: (v: number) => void; groups: string[] }) {
  return (
    <div className="grid grid-cols-2 gap-3">
      <NumberField label={_L("settings.finish_cost")} hint={_L("settings.finish_cost_hint")}
        value={cost} min={0} onChange={onChangeCost} />
      <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
        value={finish.group || ""} groups={groups} onChange={(v) => onChangeFinish({ group: v })} />
    </div>
  );
}

// ─── assembly (kitchen-prep combine) ───────────────────────────────────────────

const modSlug = (s: string) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

export function AssemblyFields({ asm, onChange, items, groups }: { asm: any; onChange: (patch: any) => void; items: Item[]; groups: string[] }) {
  const comps: string[] = asm.components ?? [];
  const mods: any[] = asm.modifiers ?? [];
  const updateMod = (mi: number, patch: any) => {
    const next = mods.map((m, idx) => {
      if (idx !== mi) return m;
      const merged = { ...m, ...patch };
      merged.id = modSlug(merged.item || merged.label) || `mod${mi}`; // keep id in sync with item/label
      return merged;
    });
    onChange({ modifiers: next });
  };
  return (
    <>
      <div className="grid grid-cols-2 gap-3">
        <Field label={_L("settings.result_output")}><ItemPicker items={items} value={asm.output} onChange={(v) => onChange({ output: v })} /></Field>
        <TextField label={_L("settings.label")} value={asm.label} onChange={(v) => onChange({ label: v })} />
        <TextField label={_L("settings.prop_model")} value={asm.model} onChange={(v) => onChange({ model: v })} />
        <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
          value={asm.group || ""} groups={groups} onChange={(v) => onChange({ group: v })} />
      </div>
      <Field label={_L("settings.components")} className="mt-3">
        <div className="space-y-2">
          {comps.map((c, ci) => (
            <div key={ci} className="flex gap-2">
              <ItemPicker className="flex-1" items={items} value={c} onChange={(v) => onChange({ components: comps.map((x, idx) => (idx === ci ? v : x)) })} />
              <Button size="icon" variant="ghost" onClick={() => onChange({ components: comps.filter((_, idx) => idx !== ci) })}><Trash2 className="h-4 w-4" /></Button>
            </div>
          ))}
          <Button size="sm" variant="outline" onClick={() => onChange({ components: [...comps, ""] })}><Plus className="h-4 w-4" /> {_L("settings.add_component")}</Button>
        </div>
      </Field>
      {/* Customer POS modifiers — add cheese, no lettuce… Ticket instructions +
          pricing; the kitchen match is item-only. */}
      <Field label={_L("settings.modifiers")} hint={_L("settings.modifiers_hint")} className="mt-3">
        <div className="space-y-2">
          {mods.map((m, mi) => (
            <div key={mi} className="flex items-end gap-2 rounded-md border border-border/60 p-2">
              <TextField label={_L("settings.mod_label")} className="w-24" value={m.label || ""} onChange={(v) => updateMod(mi, { label: v })} />
              <div className="flex-1"><Field label={_L("settings.mod_item")}><ItemPicker items={items} value={m.item || ""} onChange={(v) => updateMod(mi, { item: v })} /></Field></div>
              <NumberField label={_L("settings.mod_price")} className="w-20" value={Number(m.price || 0)} min={0} onChange={(v) => updateMod(mi, { price: v })} />
              <div className="pb-1.5"><Toggle checked={!!m.default} onChange={(v) => updateMod(mi, { default: v })} label={_L("settings.mod_default")} /></div>
              <Button size="icon" variant="ghost" onClick={() => onChange({ modifiers: mods.filter((_, idx) => idx !== mi) })}><Trash2 className="h-4 w-4" /></Button>
            </div>
          ))}
          <Button size="sm" variant="outline" onClick={() => onChange({ modifiers: [...mods, { id: "", label: "", item: "", price: 0, default: false }] })}>
            <Plus className="h-4 w-4" /> {_L("settings.add_modifier")}
          </Button>
        </div>
      </Field>
    </>
  );
}
