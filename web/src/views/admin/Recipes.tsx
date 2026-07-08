import { useEffect, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Field, TextField, NumberField, Select, Toggle } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Plus, Trash2, Pencil, X, TriangleAlert, EyeOff, ImageOff, Boxes, Check, Loader2 } from "lucide-react";

type Recipe = {
  input_item: string; station: string;
  raw_model: string; cooked_model: string; burnt_model: string;
  output_cooked_item: string; output_burnt_item: string;
  cook_ms: number; burn_ms: number;
  output_count?: number; // items one cook yields when collected cooked/burnt (a fry basket is a batch)
  dual_sided?: boolean | number;
  method?: string; // grill | oven | fry
  container_model?: string; // optional prop the food cooks in (cake tin…), visual only
  expire_seconds?: number | null; // freshness window in the tray; null/blank = global default, 0 = never
  valid?: boolean; missing?: string[];
  invalid_models?: string[];
};

// Inventory thumbnail for an item, with a graceful fallback when the image is
// missing or fails to load (different inventories store images differently).
function ItemImage({ items, name, className }: { items: Item[]; name: string; className?: string }) {
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
  return (
    <img
      src={img}
      alt={name}
      onError={() => setBroken(true)}
      className={cn("rounded bg-muted/40 object-contain", className)}
    />
  );
}

const BLANK: Recipe = {
  input_item: "", station: "fryer", raw_model: "", cooked_model: "", burnt_model: "",
  output_cooked_item: "", output_burnt_item: "", cook_ms: 15000, burn_ms: 15000, method: "fry",
};

// The cook methods valid for a station (fryer is always a basket fry).
const METHODS: Record<string, { value: string; label: string }[]> = {
  fryer: [{ value: "fry", label: _L("recipes.method_fry") }],
  stovetop: [
    { value: "grill", label: _L("recipes.method_grill") },
    { value: "oven", label: _L("recipes.method_oven") },
  ],
};

export default function Recipes({ recipes, items, onSaved }: { recipes: Recipe[]; items: Item[]; onSaved: () => void }) {
  const [form, setForm] = useState<Recipe | null>(null);
  const editing = !!form;

  // The JSON of the form as it was last persisted, so auto-save only fires on a real
  // change (not just opening the editor, and not repeatedly for the same value).
  const lastSaved = useRef<string>("");
  const openEditor = (r: Recipe) => { lastSaved.current = JSON.stringify(r); setForm(r); };

  // Debounced auto-save — no Save button. Only writes once the recipe has an
  // input_item (the server requires it) and the form actually changed.
  const status = useAutoSave(() => {
    if (!form || !form.input_item) return;
    const json = JSON.stringify(form);
    if (json === lastSaved.current) return;
    lastSaved.current = json;
    return Promise.resolve(fetchNui("admin:saveRecipe", form)).then(() => onSaved());
  }, [form]);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      <div className="flex shrink-0 items-center justify-between">
        <p className="text-xs text-muted-foreground">
          {_L("recipes.intro")}
        </p>
        {!editing && (
          <Button size="sm" onClick={() => openEditor({ ...BLANK })}><Plus className="h-4 w-4" /> {_L("recipes.new_recipe")}</Button>
        )}
      </div>

      {editing && (
        <div className="shrink-0 rounded-lg border border-primary/40 bg-primary/5 p-3">
          <div className="mb-2 flex items-center justify-between">
            <span className="flex items-center gap-2 text-sm font-semibold">
              {form!.input_item ? _L("recipes.edit_recipe") : _L("recipes.new_recipe")}
              {status === "saving" && <span className="flex items-center gap-1 text-xs font-normal text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" /> {_L("recipes.saving")}</span>}
              {status === "saved" && <span className="flex items-center gap-1 text-xs font-normal text-muted-foreground"><Check className="h-3 w-3 text-primary" /> {_L("recipes.saved")}</span>}
              {!form!.input_item && <span className="text-xs font-normal text-muted-foreground">{_L("recipes.pick_input_hint")}</span>}
            </span>
            <Button size="icon" variant="ghost" onClick={() => setForm(null)}><X className="h-4 w-4" /></Button>
          </div>
          <RecipeForm form={form!} setForm={setForm} items={items} />
          <div className="mt-3 flex justify-end">
            <Button size="sm" variant="outline" onClick={() => setForm(null)}>{_L("recipes.done")}</Button>
          </div>
        </div>
      )}

      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {recipes.length === 0 && <div className="py-6 text-center text-sm text-muted-foreground">{_L("recipes.none_yet")}</div>}
        {recipes.map((r) => {
          const badModels = r.invalid_models || [];
          return (
          <div key={r.input_item} className={cn("rounded-lg border p-3", r.valid === false ? "border-destructive/50 bg-destructive/5" : "border-border")}>
            <div className="flex items-center justify-between gap-2">
              <div className="flex min-w-0 items-center gap-3">
                {/* the cooked output stands in as the recipe's image */}
                <ItemImage items={items} name={r.output_cooked_item} className="h-11 w-11 shrink-0" />
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium">{labelOf(items, r.output_cooked_item || r.input_item)}</span>
                    <Badge variant="secondary">{r.station}</Badge>
                    {r.valid === false ? (
                      <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("recipes.needs_fixing")}</Badge>
                    ) : null}
                    {badModels.length > 0 ? (
                      <Badge variant="outline" className="gap-1 border-amber-500/60 text-amber-500"><TriangleAlert className="h-3 w-3" /> {_L("recipes.invalid_model")}</Badge>
                    ) : null}
                  </div>
                  <div className="mt-0.5 truncate text-xs text-muted-foreground">
                    {_L("recipes.from_burns", labelOf(items, r.input_item), labelOf(items, r.output_burnt_item), r.cook_ms, r.burn_ms)}
                  </div>
                  {r.valid === false && (
                    <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-destructive">
                      <EyeOff className="h-3 w-3" /> {_L("recipes.hidden_missing")}
                      {(r.missing || []).map((m) => <span key={m} className="font-mono">{m}</span>)}
                    </div>
                  )}
                  {badModels.length > 0 && (
                    <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-amber-500">
                      <Boxes className="h-3 w-3" /> {_L("recipes.models_not_found")}
                      {badModels.map((m) => <span key={m} className="font-mono">{m}</span>)}
                    </div>
                  )}
                </div>
              </div>
              <div className="flex shrink-0 gap-2">
                <Button size="sm" variant="outline" onClick={() => openEditor({ ...BLANK, ...r })}><Pencil className="h-4 w-4" /></Button>
                <Button size="sm" variant="destructive" onClick={async () => { await fetchNui("admin:deleteRecipe", { input_item: r.input_item }); onSaved(); }}>
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>
          );
        })}
      </div>
    </div>
  );
}

function RecipeForm({ form, setForm, items }: { form: Recipe; setForm: (r: Recipe) => void; items: Item[] }) {
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
      <Select label={_L("recipes.station")} value={form.station}
        onChange={(v) => setForm({ ...form, station: v, method: (METHODS[v] || [])[0]?.value || "grill" })}
        options={[{ value: "fryer", label: _L("recipes.station_fryer") }, { value: "stovetop", label: _L("recipes.station_stovetop") }]} />
      <Select label={_L("recipes.method")} value={form.method || (METHODS[form.station] || [])[0]?.value || "grill"}
        onChange={(v) => set("method", v)} options={METHODS[form.station] || METHODS.stovetop} />
      {itemField(_L("recipes.cooked_output"), "output_cooked_item")}
      {itemField(_L("recipes.burnt_output"), "output_burnt_item")}
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
      {form.station === "stovetop" && (
        <div className="col-span-3">
          <Toggle checked={!!form.dual_sided} onChange={(v) => set("dual_sided", v)}
            label={_L("recipes.dual_sided")} />
        </div>
      )}
    </div>
  );
}

function labelOf(items: Item[], name: string) {
  if (!name) return "—";
  return items.find((i) => i.name === name)?.label ?? name;
}
