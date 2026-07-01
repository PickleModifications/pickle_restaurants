import { useEffect, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Field, TextField, NumberField, Select, Toggle } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { cn } from "@/lib/utils";
import { Plus, Trash2, Pencil, X, TriangleAlert, EyeOff, ImageOff, Boxes } from "lucide-react";

type Recipe = {
  input_item: string; station: string;
  raw_model: string; cooked_model: string; burnt_model: string;
  output_cooked_item: string; output_burnt_item: string;
  cook_ms: number; burn_ms: number;
  dual_sided?: boolean | number;
  method?: string; // grill | oven | fry
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
  fryer: [{ value: "fry", label: "Fry (basket)" }],
  stovetop: [
    { value: "grill", label: "Grill (cooktop, flip)" },
    { value: "oven", label: "Oven (bake inside a door)" },
  ],
};

export default function Recipes({ recipes, items, onSaved }: { recipes: Recipe[]; items: Item[]; onSaved: () => void }) {
  const [form, setForm] = useState<Recipe | null>(null);
  const editing = !!form;

  const save = async () => {
    if (!form) return;
    await fetchNui("admin:saveRecipe", form);
    setForm(null);
    onSaved();
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      <div className="flex shrink-0 items-center justify-between">
        <p className="text-xs text-muted-foreground">
          Cookable recipes. Items are picked from the server catalogue — a recipe with a missing item is flagged and hidden in-game until fixed.
        </p>
        {!editing && (
          <Button size="sm" onClick={() => setForm({ ...BLANK })}><Plus className="h-4 w-4" /> New recipe</Button>
        )}
      </div>

      {editing && (
        <div className="shrink-0 rounded-lg border border-primary/40 bg-primary/5 p-3">
          <div className="mb-2 flex items-center justify-between">
            <span className="text-sm font-semibold">{form!.input_item ? "Edit recipe" : "New recipe"}</span>
            <Button size="icon" variant="ghost" onClick={() => setForm(null)}><X className="h-4 w-4" /></Button>
          </div>
          <RecipeForm form={form!} setForm={setForm} items={items} />
          <div className="mt-3 flex justify-end gap-2">
            <Button size="sm" variant="outline" onClick={() => setForm(null)}>Cancel</Button>
            <Button size="sm" disabled={!form!.input_item} onClick={save}>Save recipe</Button>
          </div>
        </div>
      )}

      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {recipes.length === 0 && <div className="py-6 text-center text-sm text-muted-foreground">No recipes yet.</div>}
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
                      <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> needs fixing</Badge>
                    ) : null}
                    {badModels.length > 0 ? (
                      <Badge variant="outline" className="gap-1 border-amber-500/60 text-amber-500"><TriangleAlert className="h-3 w-3" /> invalid model</Badge>
                    ) : null}
                  </div>
                  <div className="mt-0.5 truncate text-xs text-muted-foreground">
                    from {labelOf(items, r.input_item)} · burns to {labelOf(items, r.output_burnt_item)} · {r.cook_ms}/{r.burn_ms}ms
                  </div>
                  {r.valid === false && (
                    <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-destructive">
                      <EyeOff className="h-3 w-3" /> hidden in-game — missing items:
                      {(r.missing || []).map((m) => <span key={m} className="font-mono">{m}</span>)}
                    </div>
                  )}
                  {badModels.length > 0 && (
                    <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-amber-500">
                      <Boxes className="h-3 w-3" /> model(s) not found in-game:
                      {badModels.map((m) => <span key={m} className="font-mono">{m}</span>)}
                    </div>
                  )}
                </div>
              </div>
              <div className="flex shrink-0 gap-2">
                <Button size="sm" variant="outline" onClick={() => setForm({ ...BLANK, ...r })}><Pencil className="h-4 w-4" /></Button>
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
            <TriangleAlert className="h-3 w-3" /> not found in-game
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="grid grid-cols-3 gap-3">
      {itemField("Input item", "input_item")}
      <Select label="Station" value={form.station}
        onChange={(v) => setForm({ ...form, station: v, method: (METHODS[v] || [])[0]?.value || "grill" })}
        options={[{ value: "fryer", label: "Fryer" }, { value: "stovetop", label: "Stovetop" }]} />
      <Select label="Method" value={form.method || (METHODS[form.station] || [])[0]?.value || "grill"}
        onChange={(v) => set("method", v)} options={METHODS[form.station] || METHODS.stovetop} />
      {itemField("Cooked output", "output_cooked_item")}
      {itemField("Burnt output", "output_burnt_item")}
      <div />
      {modelField("Raw model (_01)", "raw_model")}
      {modelField("Cooked model (_02)", "cooked_model")}
      {modelField("Burnt model (_03)", "burnt_model")}
      <NumberField label="Cook time (ms)" value={form.cook_ms} min={0} step={1000} onChange={(v) => set("cook_ms", v)} />
      <NumberField label="Burn time (ms)" value={form.burn_ms} min={0} step={1000} onChange={(v) => set("burn_ms", v)} />
      {form.station === "stovetop" && (
        <div className="col-span-3">
          <Toggle checked={!!form.dual_sided} onChange={(v) => set("dual_sided", v)}
            label="Dual-sided (two cookable faces — click to flip; each side cooks independently)" />
        </div>
      )}
    </div>
  );
}

function labelOf(items: Item[], name: string) {
  if (!name) return "—";
  return items.find((i) => i.name === name)?.label ?? name;
}
