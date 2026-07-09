import { useMemo, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { type Item } from "@/components/ItemPicker";
import {
  ItemImage, labelOf, type Recipe, BLANK_RECIPE, STATION_LABEL,
  RecipeForm, DrinkFields, AssemblyFields, FinishFields,
} from "@/components/editors";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Plus, Trash2, Pencil, X, TriangleAlert, EyeOff, Check, Loader2, Tags, ChevronDown } from "lucide-react";

type Props = {
  recipes: Recipe[]; assembly: any[]; drinks: any[]; finishes: any[];
  settings: Record<string, any>; items: Item[]; groups: string[]; onSaved: () => void;
};

const KIND_LABEL: Record<string, string> = {
  recipe: "menu.kind_recipe", assembly: "menu.kind_assembly", drink: "menu.kind_drink", finish: "menu.kind_finish",
};

// strip the server-side annotations (valid/missing/defaultPrice) so we never
// persist them back into the settings blob when saving the whole array. Kept in
// local state for display; removed only on the way out to the server.
const clean = (e: any) => { const { valid, missing, defaultPrice, ...rest } = e; return rest; };

export default function Menu({ recipes, assembly, drinks, finishes, settings, items, groups, onSaved }: Props) {
  // Assembly + drinks live in the `settings` blob and save as a whole array.
  const [asm, setAsm] = useState<any[]>(() => (Array.isArray(assembly) ? assembly : []));
  const [drinkList, setDrinkList] = useState<any[]>(() => (Array.isArray(drinks) ? drinks : []));
  // Finishes are authored in Settings; here only their group is editable (saved as
  // the whole finishes array) and their stock/ingredient cost (the ingredient_costs
  // map, keyed by the finish tool — saved whole so other costs aren't clobbered).
  const [finishList, setFinishList] = useState<any[]>(() => (Array.isArray(finishes) ? finishes : []));
  const [costs, setCosts] = useState<Record<string, number>>(() => ({ ...(settings?.ingredient_costs || {}) }));
  const asmStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { assembly: asm.map(clean) } }).then(onSaved), [asm]);
  const drinkStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { drinks: drinkList.map(clean) } }).then(onSaved), [drinkList]);
  const finishStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { finishes: finishList.map(clean) } }).then(onSaved), [finishList]);
  const costStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { ingredient_costs: costs } }).then(onSaved), [costs]);
  const listStatus = [asmStatus, drinkStatus, finishStatus, costStatus].includes("saving") ? "saving"
    : [asmStatus, drinkStatus, finishStatus, costStatus].includes("saved") ? "saved" : "idle";

  const updateAsm = (i: number, patch: any) => setAsm((l) => l.map((a, idx) => (idx === i ? { ...a, ...patch } : a)));
  const updateDrink = (i: number, patch: any) => setDrinkList((l) => l.map((d, idx) => (idx === i ? { ...d, ...patch } : d)));
  const updateFinish = (i: number, patch: any) => setFinishList((l) => l.map((f, idx) => (idx === i ? { ...f, ...patch } : f)));

  // One row is expanded/edited at a time. `editKey` = which; recipes edit a
  // working copy (`draft`) auto-saved per-row, assembly/drinks edit the array.
  const [editKey, setEditKey] = useState<string | null>(null);
  const [draft, setDraft] = useState<Recipe | null>(null);
  const lastSaved = useRef<string>("");
  const [newOpen, setNewOpen] = useState(false);

  const recipeStatus = useAutoSave(() => {
    if (!draft || !draft.input_item) return;
    const json = JSON.stringify(draft);
    if (json === lastSaved.current) return;
    lastSaved.current = json;
    return Promise.resolve(fetchNui("admin:saveRecipe", draft)).then(() => onSaved());
  }, [draft]);

  const openRecipe = (r: Recipe, key: string) => { lastSaved.current = JSON.stringify(r); setDraft({ ...BLANK_RECIPE, ...r }); setEditKey(key); };
  const close = () => { setEditKey(null); setDraft(null); };

  const addRecipe = () => { setNewOpen(false); openRecipe({ ...BLANK_RECIPE }, "recipe:__new__"); };
  const addAssembly = () => {
    setNewOpen(false);
    setAsm((l) => { const next = [...l, { output: "", label: "", model: "pickle_bread_bun_01", components: [] }]; setEditKey(`assembly:${next.length - 1}`); return next; });
  };
  const addDrink = () => {
    setNewOpen(false);
    setDrinkList((l) => { const next = [...l, { input: "", output: "", label: "", model: "pickle_drink_container_01", fill_ms: 3000 }]; setEditKey(`drink:${next.length - 1}`); return next; });
  };

  // Build the unified, grouped row list.
  const groupsOut = useMemo(() => {
    type Row = { kind: string; key: string; group: string; sortLabel: string; index?: number; data: any };
    const rows: Row[] = [];
    recipes.forEach((r) => rows.push({ kind: "recipe", key: `recipe:${r.input_item}`, group: (r.group as string) || "", sortLabel: labelOf(items, r.output_cooked_item || r.input_item), data: r }));
    asm.forEach((a, i) => rows.push({ kind: "assembly", key: `assembly:${i}`, group: a.group || "", sortLabel: a.label || a.output || "", index: i, data: a }));
    drinkList.forEach((d, i) => rows.push({ kind: "drink", key: `drink:${i}`, group: d.group || "", sortLabel: d.label || d.output || "", index: i, data: d }));
    finishList.forEach((f, i) => rows.push({ kind: "finish", key: `finish:${i}`, group: f.group || "", sortLabel: f.tool ? labelOf(items, f.tool) : "", index: i, data: f }));

    const by: Record<string, Row[]> = {};
    rows.forEach((r) => { (by[r.group] ||= []).push(r); });
    const order = ["recipe", "assembly", "drink", "finish"];
    const names = Object.keys(by).sort((a, b) => (a === "" ? 1 : b === "" ? -1 : a.localeCompare(b)));
    return names.map((g) => ({
      name: g,
      rows: by[g].sort((a, b) => (order.indexOf(a.kind) - order.indexOf(b.kind)) || a.sortLabel.localeCompare(b.sortLabel)),
    }));
  }, [recipes, asm, drinkList, finishList, items]);

  const imgItem = (row: any) =>
    row.kind === "recipe" ? row.data.output_cooked_item || row.data.input_item
    : row.kind === "assembly" ? row.data.output
    : row.kind === "drink" ? row.data.input
    : row.data.tool;

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      <div className="flex shrink-0 items-start justify-between gap-2">
        <p className="text-xs text-muted-foreground">{_L("menu.intro")}</p>
        <div className="flex shrink-0 items-center gap-2">
          {listStatus === "saving" && <span className="flex items-center gap-1 text-xs text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" /> {_L("recipes.saving")}</span>}
          {listStatus === "saved" && <span className="flex items-center gap-1 text-xs text-muted-foreground"><Check className="h-3 w-3 text-primary" /> {_L("recipes.saved")}</span>}
          <div className="relative">
            <Button size="sm" onClick={() => setNewOpen((v) => !v)}><Plus className="h-4 w-4" /> {_L("menu.new")} <ChevronDown className="h-3 w-3" /></Button>
            {newOpen && (
              <div className="absolute right-0 z-10 mt-1 w-52 overflow-hidden rounded-md border border-border bg-popover shadow-md">
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={addRecipe}>{_L("menu.new_recipe")}</button>
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={addAssembly}>{_L("menu.new_assembly")}</button>
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={addDrink}>{_L("menu.new_drink")}</button>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto pr-1">
        {/* New-recipe editor (has no row yet) shows at the top while open. */}
        {editKey === "recipe:__new__" && draft && (
          <EditorShell title={_L("recipes.new_recipe")} status={recipeStatus} onClose={close}>
            <RecipeForm form={draft} setForm={setDraft} items={items} groups={groups} />
          </EditorShell>
        )}

        {groupsOut.length === 0 && <div className="py-6 text-center text-sm text-muted-foreground">{_L("menu.none_yet")}</div>}

        {groupsOut.map((grp) => (
          <div key={grp.name || "__ungrouped__"} className="space-y-2">
            <div className="flex items-center gap-2 px-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              <Tags className="h-3.5 w-3.5" /> {grp.name || _L("menu.ungrouped")}
            </div>
            {grp.rows.map((row) => {
              const d = row.data;
              const invalid = d.valid === false;
              const isEditing = editKey === row.key;
              const badModels = (d.invalid_models as string[]) || [];
              return (
                <div key={row.key} className={cn("rounded-lg border p-3", invalid ? "border-destructive/50 bg-destructive/5" : "border-border")}>
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex min-w-0 items-center gap-3">
                      <ItemImage items={items} name={imgItem(row)} className="h-10 w-10 shrink-0" />
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="truncate font-medium">{row.sortLabel || "—"}</span>
                          <Badge variant="secondary">{_L(KIND_LABEL[row.kind])}</Badge>
                          {row.kind === "recipe" && <Badge variant="outline">{STATION_LABEL[d.station] || d.station}</Badge>}
                          {row.kind === "drink" && d.drink_item_installed === false && (
                            <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("menu.drink_not_installed")}</Badge>
                          )}
                          {typeof d.defaultPrice === "number" && d.defaultPrice > 0 && (
                            <Badge variant="outline" className="text-emerald-500">{_L("menu.default_price", d.defaultPrice)}</Badge>
                          )}
                          {invalid && (
                            <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("recipes.needs_fixing")}</Badge>
                          )}
                          {badModels.length > 0 && (
                            <Badge variant="outline" className="gap-1 border-amber-500/60 text-amber-500"><TriangleAlert className="h-3 w-3" /> {_L("recipes.invalid_model")}</Badge>
                          )}
                        </div>
                        {invalid && Array.isArray(d.missing) && d.missing.length > 0 && (
                          <div className="mt-1 flex flex-wrap items-center gap-1 text-xs text-destructive">
                            <EyeOff className="h-3 w-3" /> {_L("recipes.hidden_missing")}
                            {d.missing.map((m: string) => <span key={m} className="font-mono">{m}</span>)}
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="flex shrink-0 items-center gap-2">
                      <Button size="sm" variant={isEditing ? "secondary" : "outline"} onClick={() => {
                        if (isEditing) { close(); return; }
                        if (row.kind === "recipe") openRecipe(d, row.key); else setEditKey(row.key);
                      }}><Pencil className="h-4 w-4" /></Button>
                      {/* Finishes are defined in Settings — editable (cost/group) but not deletable here. */}
                      {row.kind !== "finish" && (
                        <Button size="sm" variant="destructive" onClick={async () => {
                          if (row.kind === "recipe") { await fetchNui("admin:deleteRecipe", { input_item: d.input_item }); onSaved(); }
                          else if (row.kind === "assembly") { close(); setAsm((l) => l.filter((_, i) => i !== row.index)); }
                          else if (row.kind === "drink") { close(); setDrinkList((l) => l.filter((_, i) => i !== row.index)); }
                        }}><Trash2 className="h-4 w-4" /></Button>
                      )}
                    </div>
                  </div>

                  {isEditing && (
                    <div className="mt-3 border-t border-border pt-3">
                      {row.kind === "recipe" && draft && <RecipeForm form={draft} setForm={setDraft} items={items} groups={groups} />}
                      {row.kind === "assembly" && row.index !== undefined && <AssemblyFields asm={asm[row.index]} onChange={(p) => updateAsm(row.index!, p)} items={items} groups={groups} />}
                      {row.kind === "drink" && row.index !== undefined && <DrinkFields drink={drinkList[row.index]} onChange={(p) => updateDrink(row.index!, p)} items={items} groups={groups} />}
                      {row.kind === "finish" && row.index !== undefined && (
                        <FinishFields
                          finish={finishList[row.index]}
                          cost={Number(costs[finishList[row.index].tool] ?? 0)}
                          onChangeFinish={(p) => updateFinish(row.index!, p)}
                          onChangeCost={(v) => setCosts((c) => ({ ...c, [finishList[row.index!].tool]: Math.max(0, Math.floor(v || 0)) }))}
                          groups={groups}
                        />
                      )}
                      <div className="mt-3 flex justify-end">
                        <Button size="sm" variant="outline" onClick={close}>{_L("recipes.done")}</Button>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}

function EditorShell({ title, status, onClose, children }: { title: string; status: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-primary/40 bg-primary/5 p-3">
      <div className="mb-2 flex items-center justify-between">
        <span className="flex items-center gap-2 text-sm font-semibold">
          {title}
          {status === "saving" && <span className="flex items-center gap-1 text-xs font-normal text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" /> {_L("recipes.saving")}</span>}
          {status === "saved" && <span className="flex items-center gap-1 text-xs font-normal text-muted-foreground"><Check className="h-3 w-3 text-primary" /> {_L("recipes.saved")}</span>}
        </span>
        <Button size="icon" variant="ghost" onClick={onClose}><X className="h-4 w-4" /></Button>
      </div>
      {children}
    </div>
  );
}
