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
  return <img src={img} alt={name} onError={() => setBroken(true)} className={cn("rounded object-contain", className)} />;
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

// The drink's `color` is stored as an { r, g, b } triplet (the soda-machine pour
// stream reads it, AND it's the order-UI flavor swatch). Convert to/from the hex
// the native colour picker speaks.
const rgbToHex = (c: any): string => {
  if (Array.isArray(c) && c.length >= 3) {
    const h = (n: number) => Math.max(0, Math.min(255, Math.floor(Number(n) || 0))).toString(16).padStart(2, "0");
    return "#" + h(c[0]) + h(c[1]) + h(c[2]);
  }
  return "#8899aa";
};
const hexToRgb = (hex: string): [number, number, number] => {
  const m = /^#?([0-9a-fA-F]{6})$/.exec((hex || "").trim());
  if (!m) return [136, 153, 170];
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};

export function DrinkFields({ drink, onChange, items, groups }: { drink: any; onChange: (patch: any) => void; items: Item[]; groups: string[] }) {
  const hex = rgbToHex(drink.color);
  return (
    <div className="grid grid-cols-2 gap-3">
      <Field label={_L("settings.cup_input")}><ItemPicker items={items} value={drink.input} onChange={(v) => onChange({ input: v })} /></Field>
      <Field label={_L("settings.filled_output")}><ItemPicker items={items} value={drink.output} onChange={(v) => onChange({ output: v })} /></Field>
      <TextField label={_L("settings.label")} value={drink.label} onChange={(v) => onChange({ label: v })} />
      <TextField label={_L("settings.prop_model")} value={drink.model} onChange={(v) => onChange({ model: v })} />
      <NumberField label={_L("settings.fill_time")} value={Number(drink.fill_ms ?? 3000)} min={0} step={500} onChange={(v) => onChange({ fill_ms: v })} />
      <Field label={_L("settings.drink_color")} hint={_L("settings.drink_color_hint")}>
        <div className="flex items-center gap-2">
          <input type="color" value={hex} onChange={(e) => onChange({ color: hexToRgb(e.target.value) })}
            className="h-9 w-12 shrink-0 cursor-pointer rounded border border-input bg-transparent p-0.5" />
          <span className="font-mono text-xs uppercase text-muted-foreground">{hex}</span>
        </div>
      </Field>
      <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
        value={drink.group || ""} groups={groups} onChange={(v) => onChange({ group: v })} />
    </div>
  );
}

// ─── finish (frosting/sprinkles) ────────────────────────────────────────────────
// A finish is a "rub a tool over a product" recipe: a tool item + one or more
// TARGETS (which cooked product it decorates → what it becomes), each with a list
// of FLAVORS (the pick-one toppings: strawberry/chocolate/…, a prop model + swatch
// colour per flavor). All of it is editable here now; the ingredient cost rides the
// separate `ingredient_costs` map (drives the buy price AND default menu price).

const modSlug2 = (s: string) => (s || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");

// One flavor row inside a target: id/label/model + a hex colour swatch. Finish
// flavor colours are stored as hex strings (unlike drink colours' rgb triplets).
function FlavorRow({ fl, onChange, onRemove }: { fl: any; onChange: (patch: any) => void; onRemove: () => void }) {
  const hex = /^#?[0-9a-fA-F]{6}$/.test(fl.color || "") ? (fl.color[0] === "#" ? fl.color : "#" + fl.color) : "#cccccc";
  return (
    <div className="flex items-end gap-2 rounded-md border border-border/60 p-2">
      <TextField label={_L("settings.flavor_label")} className="w-28" value={fl.label || ""}
        onChange={(v) => onChange({ label: v, id: fl.id || modSlug2(v) })} />
      <TextField label={_L("settings.flavor_id")} className="w-24" value={fl.id || ""} onChange={(v) => onChange({ id: modSlug2(v) })} />
      <div className="flex-1"><TextField label={_L("settings.flavor_model")} value={fl.model || ""} onChange={(v) => onChange({ model: v })} /></div>
      <label className="flex shrink-0 flex-col gap-1">
        <span className="text-xs text-muted-foreground">{_L("settings.flavor_color")}</span>
        <input type="color" value={hex} onChange={(e) => onChange({ color: e.target.value })}
          className="h-9 w-10 cursor-pointer rounded border border-input bg-transparent p-0.5" />
      </label>
      <Button size="icon" variant="ghost" onClick={onRemove}><Trash2 className="h-4 w-4" /></Button>
    </div>
  );
}

// One target card: which cooked item this finish decorates, what it produces, the
// apply mode, an optional pre-requisite finish, and the flavor list.
function TargetCard({ target, items, onChange, onRemove }:
  { target: any; items: Item[]; onChange: (patch: any) => void; onRemove: () => void }) {
  const flavors: any[] = target.flavors ?? [];
  const updateFlavor = (fi: number, patch: any) => onChange({ flavors: flavors.map((f, i) => (i === fi ? { ...f, ...patch } : f)) });
  return (
    <div className="rounded-lg border border-border/70 p-2.5">
      <div className="mb-2 flex items-start justify-between gap-2">
        <div className="grid flex-1 grid-cols-2 gap-2">
          <Field label={_L("settings.finish_target_item")}><ItemPicker items={items} value={target.item || ""} onChange={(v) => onChange({ item: v })} /></Field>
          <Field label={_L("settings.finish_target_output")}><ItemPicker items={items} value={target.output || ""} onChange={(v) => onChange({ output: v })} /></Field>
          <Select label={_L("settings.finish_mode")} value={target.mode || "overlay"} onChange={(v) => onChange({ mode: v })}
            options={[{ value: "overlay", label: _L("settings.finish_mode_overlay") }, { value: "replace", label: _L("settings.finish_mode_replace") }]} />
          <TextField label={_L("settings.finish_requires")} hint={_L("settings.finish_requires_hint")}
            value={target.requires_finish || ""} onChange={(v) => onChange({ requires_finish: v || undefined })} />
        </div>
        <Button size="icon" variant="ghost" onClick={onRemove}><Trash2 className="h-4 w-4" /></Button>
      </div>
      <Field label={_L("settings.finish_flavors")}>
        <div className="space-y-2">
          {flavors.map((fl, fi) => (
            <FlavorRow key={fi} fl={fl} onChange={(p) => updateFlavor(fi, p)}
              onRemove={() => onChange({ flavors: flavors.filter((_, i) => i !== fi) })} />
          ))}
          <Button size="sm" variant="outline" onClick={() => onChange({ flavors: [...flavors, { id: "", label: "", model: "", color: "#cccccc" }] })}>
            <Plus className="h-4 w-4" /> {_L("settings.finish_add_flavor")}
          </Button>
        </div>
      </Field>
    </div>
  );
}

export function FinishFields({ finish, cost, onChangeFinish, onChangeCost, items, groups }:
  { finish: any; cost: number; onChangeFinish: (patch: any) => void; onChangeCost: (v: number) => void; items: Item[]; groups: string[] }) {
  const targets: any[] = finish.targets ?? [];
  const updateTarget = (ti: number, patch: any) => onChangeFinish({ targets: targets.map((t, i) => (i === ti ? { ...t, ...patch } : t)) });
  return (
    <>
      <div className="grid grid-cols-2 gap-3">
        <Field label={_L("settings.finish_tool")}><ItemPicker items={items} value={finish.tool || ""} onChange={(v) => onChangeFinish({ tool: v })} /></Field>
        <TextField label={_L("settings.finish_tool_model")} value={finish.tool_model || ""} onChange={(v) => onChangeFinish({ tool_model: v })} />
        <NumberField label={_L("settings.finish_rub_dist")} hint={_L("settings.finish_rub_dist_hint")}
          value={Number(finish.rub_dist ?? 1.2)} min={0} step={0.1} onChange={(v) => onChangeFinish({ rub_dist: v })} />
        <NumberField label={_L("settings.finish_cost")} hint={_L("settings.finish_cost_hint")}
          value={cost} min={0} onChange={onChangeCost} />
        <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
          value={finish.group || ""} groups={groups} onChange={(v) => onChangeFinish({ group: v })} />
      </div>
      <Field label={_L("settings.finish_targets")} hint={_L("settings.finish_targets_hint")} className="mt-3">
        <div className="space-y-2">
          {targets.map((t, ti) => (
            <TargetCard key={ti} target={t} items={items} onChange={(p) => updateTarget(ti, p)}
              onRemove={() => onChangeFinish({ targets: targets.filter((_, i) => i !== ti) })} />
          ))}
          <Button size="sm" variant="outline" onClick={() => onChangeFinish({ targets: [...targets, { item: "", output: "", mode: "overlay", flavors: [] }] })}>
            <Plus className="h-4 w-4" /> {_L("settings.finish_add_target")}
          </Button>
        </div>
      </Field>
    </>
  );
}

// ─── condiment (squeeze-bottle sauce) ───────────────────────────────────────────
// A condiment is one entry in the `condiments` settings array: the bottle `item`
// (consumed at Make + priced via ingredient_costs) plus two visual-only props — the
// held bottle (`container_model`) and the sauce left on the food (`applied_model`).

export function CondimentFields({ condiment, cost, onChange, onChangeCost, items }:
  { condiment: any; cost: number; onChange: (patch: any) => void; onChangeCost: (v: number) => void; items: Item[] }) {
  return (
    <div className="grid grid-cols-2 gap-3">
      <Field label={_L("settings.condiment_item")}><ItemPicker items={items} value={condiment.item || ""} onChange={(v) => onChange({ item: v })} /></Field>
      <NumberField label={_L("settings.finish_cost")} hint={_L("settings.finish_cost_hint")}
        value={cost} min={0} onChange={onChangeCost} />
      <TextField label={_L("settings.condiment_container")} value={condiment.container_model || ""} onChange={(v) => onChange({ container_model: v })} />
      <TextField label={_L("settings.condiment_applied")} value={condiment.applied_model || ""} onChange={(v) => onChange({ applied_model: v })} />
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

// ─── craft (Restaurant Bag combine) ────────────────────────────────────────────
// A craft is one entry in the `crafts` settings array: a code-less combine recipe
// (soup, salad…). Its components are dropped into the Restaurant Bag at kitchen prep
// and bagged up into the ONE restaurant_bag item — there is NO output picker (the
// output is always the bag; the craft `id` is its POS variation identity). Same
// modifiers as an assembly. `onChange` patches the entry; the parent owns the array.

export function CraftFields({ craft, onChange, items, groups }: { craft: any; onChange: (patch: any) => void; items: Item[]; groups: string[] }) {
  const comps: string[] = craft.components ?? [];
  const mods: any[] = craft.modifiers ?? [];
  const updateMod = (mi: number, patch: any) => {
    const next = mods.map((m, idx) => {
      if (idx !== mi) return m;
      const merged = { ...m, ...patch };
      merged.id = modSlug(merged.item || merged.label) || `mod${mi}`;
      return merged;
    });
    onChange({ modifiers: next });
  };
  return (
    <>
      <div className="grid grid-cols-2 gap-3">
        <TextField label={_L("settings.craft_id")} hint={_L("settings.craft_id_hint")}
          value={craft.id || ""} onChange={(v) => onChange({ id: modSlug(v) })} />
        <TextField label={_L("settings.label")} value={craft.label} onChange={(v) => onChange({ label: v })} />
        <GroupField label={_L("settings.group_field")} hint={_L("settings.group_field_hint")}
          value={craft.group || ""} groups={groups} onChange={(v) => onChange({ group: v })} />
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
      {/* Customer POS modifiers — same as an assembly (ticket instructions + pricing). */}
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
