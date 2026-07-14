import { useMemo, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { type Item } from "@/components/ItemPicker";
import {
  ItemImage, labelOf, prettyName, foodSubBadge, foodImageItem,
  FoodForm, ToolForm, IngredientForm,
  type Food, type Step, type Tool, type IngredientDef,
} from "@/components/editors";
import { Modal } from "@/components/ui/modal";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Plus, Trash2, Pencil, TriangleAlert, EyeOff, Check, Loader2, Tags, ChevronDown, UtensilsCrossed, Wrench, Layers } from "lucide-react";

type Props = {
  foods: Food[]; tools: Tool[]; ingredients: IngredientDef[];
  settings: Record<string, any>; items: Item[]; groups: string[]; onSaved: () => void;
};

// strip the server-side annotations (valid/missing/defaultPrice/tap/…) so we
// never persist them back into the settings blob when saving the whole array.
// Kept in local state for display; removed only on the way out to the server.
const clean = (e: any) => {
  const {
    valid, missing, defaultPrice, invalid_models,
    bag_item_installed, drink_item_installed, tap, duplicate_input,
    ...rest
  } = e;
  return rest;
};

// The New Recipe presets: each seeds a steps skeleton (or the bag kind) so the
// editor opens already shaped like the dish being made. The one-line description
// is the point — the menu explains itself.
const PRESETS: { key: string; label: string; desc: string; make: () => Partial<Food> }[] = [
  {
    key: "cook", label: _L("menu.preset_cook"), desc: _L("menu.preset_cook_desc"),
    make: () => ({ kind: "interactive", steps: [{ type: "cook", station: "fryer", method: "fry", cook_ms: 15000, burn_ms: 15000 }] }),
  },
  {
    key: "assemble", label: _L("menu.preset_assemble"), desc: _L("menu.preset_assemble_desc"),
    make: () => ({ kind: "interactive", steps: [{ type: "assemble", components: [] }] }),
  },
  {
    key: "cook_assemble", label: _L("menu.preset_cook_assemble"), desc: _L("menu.preset_cook_assemble_desc"),
    make: () => ({
      kind: "interactive",
      steps: [
        { type: "cook", station: "stovetop", method: "grill", cook_ms: 15000, burn_ms: 15000 },
        { type: "assemble", components: [] },
      ],
    }),
  },
  {
    key: "assemble_bake", label: _L("menu.preset_assemble_bake"), desc: _L("menu.preset_assemble_bake_desc"),
    make: () => ({
      kind: "interactive",
      steps: [
        { type: "assemble", components: [] },
        { type: "cook", station: "stovetop", method: "oven", cook_ms: 15000, burn_ms: 15000 },
      ],
    }),
  },
  {
    key: "pour", label: _L("menu.preset_pour"), desc: _L("menu.preset_pour_desc"),
    make: () => ({ kind: "interactive", steps: [{ type: "pour", fill_ms: 3000 }] }),
  },
  {
    key: "bag", label: _L("menu.preset_bag"), desc: _L("menu.preset_bag_desc"),
    make: () => ({ kind: "bag", components: [] }),
  },
];

export default function Menu({ foods, tools, ingredients, settings, items, groups, onSaved }: Props) {
  // The whole menu lives in the settings blob as three arrays, each saved whole
  // via the batched settings autosave (the server sanitizes + rebuilds + syncs).
  const [foodList, setFoodList] = useState<Food[]>(() => (Array.isArray(foods) ? foods : []));
  const [toolList, setToolList] = useState<Tool[]>(() => (Array.isArray(tools) ? tools : []));
  const [ingList, setIngList] = useState<IngredientDef[]>(() => (Array.isArray(ingredients) ? ingredients : []));
  // Tools + ingredients buy their stock via the ingredient_costs map (keyed by
  // the item — saved whole so other costs aren't clobbered).
  const [costs, setCosts] = useState<Record<string, number>>(() => ({ ...(settings?.ingredient_costs || {}) }));
  const foodStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { foods: foodList.map(clean) } }).then(onSaved), [foodList]);
  const toolStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { tools: toolList.map(clean) } }).then(onSaved), [toolList]);
  const ingStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { ingredients: ingList.map(clean) } }).then(onSaved), [ingList]);
  const costStatus = useAutoSave(() => fetchNui("admin:saveSettings", { settings: { ingredient_costs: costs } }).then(onSaved), [costs]);
  const allStatus = [foodStatus, toolStatus, ingStatus, costStatus];
  const listStatus = allStatus.includes("saving") ? "saving" : allStatus.includes("saved") ? "saved" : "idle";

  const updateFood = (i: number, patch: any) => setFoodList((l) => l.map((f, idx) => (idx === i ? { ...f, ...patch } : f)));
  const updateTool = (i: number, patch: any) => setToolList((l) => l.map((t, idx) => (idx === i ? { ...t, ...patch } : t)));
  const updateIng = (i: number, patch: any) => setIngList((l) => l.map((g, idx) => (idx === i ? { ...g, ...patch } : g)));
  const setCost = (item: string | undefined, v: number) => {
    if (!item) return;
    setCosts((c) => ({ ...c, [item]: Math.max(0, Math.floor(v || 0)) }));
  };

  // Creating/editing happens in a modal dialog (an inline editor fought the
  // scrolling list). `editKey` ("food:3" / "tool:1" / …) names the open entry;
  // `picking` shows the New-Recipe preset chooser instead. At most one is set.
  const [editKey, setEditKey] = useState<string | null>(null);
  const [newOpen, setNewOpen] = useState(false);
  // "New Recipe" first asks WHAT it is (kind + preset) before showing any fields.
  const [picking, setPicking] = useState(false);
  const close = () => { setEditKey(null); setPicking(false); };

  const addFood = (preset: (typeof PRESETS)[number]) => {
    setPicking(false);
    setFoodList((l) => {
      const next = [...l, { label: "", group: "", modifiers: [], ...preset.make() } as Food];
      setEditKey(`food:${next.length - 1}`);
      return next;
    });
  };
  const addTool = () => {
    setNewOpen(false);
    setToolList((l) => {
      const next = [...l, { item: "", tool_model: "", mode: "layer", applied_model: "", group: "" } as Tool];
      setEditKey(`tool:${next.length - 1}`);
      return next;
    });
  };
  const addIngredient = () => {
    setNewOpen(false);
    setIngList((l) => {
      const next = [...l, { item: "", model: "", group: "" } as IngredientDef];
      setEditKey(`ing:${next.length - 1}`);
      return next;
    });
  };

  // Build the unified, grouped row list.
  const groupsOut = useMemo(() => {
    type Row = { kind: string; key: string; group: string; sortLabel: string; index: number; data: any };
    const rows: Row[] = [];
    foodList.forEach((f, i) => rows.push({
      kind: "food", key: `food:${i}`, group: (f.group as string) || "",
      sortLabel: f.label || (f.id ? prettyName(f.id) : labelOf(items, foodImageItem(f))), index: i, data: f,
    }));
    toolList.forEach((t, i) => rows.push({
      kind: "tool", key: `tool:${i}`, group: (t.group as string) || "",
      sortLabel: t.item ? labelOf(items, t.item) : "", index: i, data: t,
    }));
    ingList.forEach((g, i) => rows.push({
      kind: "ing", key: `ing:${i}`, group: (g.group as string) || "",
      sortLabel: g.label || (g.item ? labelOf(items, g.item) : ""), index: i, data: g,
    }));

    const by: Record<string, Row[]> = {};
    rows.forEach((r) => { (by[r.group] ||= []).push(r); });
    const order = ["food", "tool", "ing"];
    const names = Object.keys(by).sort((a, b) => (a === "" ? 1 : b === "" ? -1 : a.localeCompare(b)));
    return names.map((g) => ({
      name: g,
      rows: by[g].sort((a, b) => (order.indexOf(a.kind) - order.indexOf(b.kind)) || a.sortLabel.localeCompare(b.sortLabel)),
    }));
  }, [foodList, toolList, ingList, items]);

  const KIND_LABEL: Record<string, string> = { food: "menu.kind_recipe", tool: "menu.kind_tool", ing: "menu.kind_ingredient" };
  const imgItem = (row: any) =>
    row.kind === "food" ? foodImageItem(row.data)
    : row.kind === "tool" ? row.data.item
    : row.data.item;

  // The entry the dialog is editing, resolved live from the lists by index (the
  // lists only change via the dialog's own patches or a delete that closes it,
  // so the index stays valid while open).
  const editing = editKey ? (() => {
    const [kind, idxStr] = editKey.split(":");
    const index = Number(idxStr);
    // `data` is a plain union across the three kinds; the `kind` tag guards each
    // use, so treat it as any (matching how the row list already types data).
    const data: any = kind === "food" ? foodList[index] : kind === "tool" ? toolList[index] : ingList[index];
    return data ? { kind, index, data } : null;
  })() : null;

  const KIND_ICON: Record<string, JSX.Element> = {
    food: <UtensilsCrossed className="h-4 w-4" />,
    tool: <Wrench className="h-4 w-4" />,
    ing: <Layers className="h-4 w-4" />,
  };
  const editTitle = editing
    ? editing.kind === "food"
      ? (editing.data.label || (editing.data.id ? prettyName(editing.data.id) : _L("menu.kind_recipe")))
      : editing.kind === "tool"
        ? (editing.data.item ? labelOf(items, editing.data.item) : _L("menu.kind_tool"))
        : (editing.data.label || (editing.data.item ? labelOf(items, editing.data.item) : _L("menu.kind_ingredient")))
    : "";

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
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={() => { setNewOpen(false); setPicking(true); setEditKey(null); }}>{_L("menu.new_recipe")}</button>
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={addTool}>{_L("menu.new_tool")}</button>
                <button className="block w-full px-3 py-2 text-left text-sm hover:bg-accent" onClick={addIngredient}>{_L("menu.new_ingredient")}</button>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto pr-1">
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
                          {row.kind === "food" && <Badge variant="outline">{foodSubBadge(d)}</Badge>}
                          {row.kind === "food" && d.drink_item_installed === false && (
                            <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("menu.drink_not_installed")}</Badge>
                          )}
                          {row.kind === "food" && d.bag_item_installed === false && (
                            <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("menu.bag_not_installed")}</Badge>
                          )}
                          {row.kind === "food" && !!d.duplicate_input && (
                            <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("menu.duplicate_input")}</Badge>
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
                      <Button size="sm" variant={isEditing ? "secondary" : "outline"} onClick={() => { setPicking(false); setEditKey(row.key); }}><Pencil className="h-4 w-4" /></Button>
                      {/* A deleted DEFAULT entry re-seeds on next restart (the embedded
                          default menu is recoverable); admin-added ones stay gone. */}
                      <Button size="sm" variant="destructive" onClick={() => {
                        close();
                        if (row.kind === "food") setFoodList((l) => l.filter((_, i) => i !== row.index));
                        else if (row.kind === "tool") setToolList((l) => l.filter((_, i) => i !== row.index));
                        else setIngList((l) => l.filter((_, i) => i !== row.index));
                      }}><Trash2 className="h-4 w-4" /></Button>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        ))}
      </div>

      {/* New Recipe: pick what kind of thing it is FIRST — each preset seeds the
          right step skeleton, so the editor opens already making sense. */}
      <Modal
        open={picking}
        onClose={close}
        title={_L("menu.new_recipe")}
        subtitle={_L("menu.preset_title")}
        icon={<UtensilsCrossed className="h-4 w-4" />}
        size="lg"
      >
        <div className="grid grid-cols-2 gap-2">
          {PRESETS.map((p) => (
            <button
              key={p.key}
              onClick={() => addFood(p)}
              className="rounded-lg border border-border bg-card p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/60"
            >
              <div className="text-sm font-semibold">{p.label}</div>
              <div className="mt-0.5 text-[11px] leading-snug text-muted-foreground">{p.desc}</div>
            </button>
          ))}
        </div>
      </Modal>

      {/* Create / edit an entry in a dialog (replaces the old inline editor). */}
      <Modal
        open={!!editing}
        onClose={close}
        title={editTitle}
        subtitle={editing ? _L(KIND_LABEL[editing.kind]) : ""}
        icon={editing ? KIND_ICON[editing.kind] : null}
        size={editing?.kind === "food" ? "xl" : "lg"}
        footer={<Button size="sm" onClick={close}>{_L("recipes.done")}</Button>}
      >
        {editing?.kind === "food" && (
          <FoodForm food={editing.data} onChange={(p) => updateFood(editing.index, p)} items={items} groups={groups} />
        )}
        {editing?.kind === "tool" && (
          <ToolForm
            tool={editing.data}
            cost={Number(costs[editing.data.item || ""] ?? 0)}
            onChange={(p) => updateTool(editing.index, p)}
            onChangeCost={(v) => setCost(editing.data.item, v)}
            items={items}
            groups={groups}
          />
        )}
        {editing?.kind === "ing" && (
          <IngredientForm
            ing={editing.data}
            cost={Number(costs[editing.data.item || ""] ?? 0)}
            onChange={(p) => updateIng(editing.index, p)}
            onChangeCost={(v) => setCost(editing.data.item, v)}
            items={items}
            groups={groups}
          />
        )}
      </Modal>
    </div>
  );
}
