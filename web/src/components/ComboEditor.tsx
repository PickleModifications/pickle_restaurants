import { useMemo, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { useAutoSave } from "@/lib/autosave";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Field, Toggle } from "@/components/form";
import ItemPicker, { type Item } from "@/components/ItemPicker";
import { ItemImage } from "@/components/editors";
import { PhotoField, type PhotoEntry, type PhotoAspect } from "@/components/Branding";
import { cn, money } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Plus, Trash2, Pencil, Check, Loader2, TriangleAlert, UtensilsCrossed, ChevronRight, Layers } from "lucide-react";

// A combo meal = a numbered, priced bundle of existing sellables. Each SLOT is a
// list of allowed picks: a pick is either a fixed sellable-catalog KEY, or a whole
// ACCESS GROUP (key `group:<Name>` — resolves to any item in that group at order
// time, e.g. "Any Drink"). One pick = a fixed slot, several = a "choose one" slot.
// Per-item toppings are the chosen item's own modifiers, resolved live at order
// time — so a slot only stores keys.

export type ComboGroup = { group: string; count: number };
export type ComboOption = { key: string; label?: string; image?: string; valid?: boolean; group?: string; count?: number };
export type ComboSlot = { label: string; options: ComboOption[]; stale?: boolean };
export type Combo = {
  id?: number; number: number; label: string; price: number; enabled: boolean;
  photo?: PhotoEntry | null; slots: ComboSlot[]; stale?: boolean;
};

// The combo card photo aspect (landscape food shot, like a menu-board hero image).
// LAZY getter (memoized): `_L()` resolves at render, not at module import — a
// module-scope `_L()` runs before loadLocale() and would freeze to the raw key.
let _comboPhoto: PhotoAspect | null = null;
const COMBO_PHOTO = (): PhotoAspect => (_comboPhoto ??= { label: _L("combo.tex_label"), w: 1200, h: 800, hint: _L("combo.photo_hint") });

// A group pick is a normal option key with a reserved `group:` prefix (mirrors the
// server's ComboOptionGroup). Kept as one key so storage/sanitize stay unchanged.
const GROUP_PREFIX = "group:";
const groupKey = (name: string) => GROUP_PREFIX + name;
const isGroupKey = (k?: string) => !!k && k.startsWith(GROUP_PREFIX);
const groupOf = (k: string) => k.slice(GROUP_PREFIX.length);

// A new combo opens with one empty slot so the picker is immediately visible.
const blankCombo = (nextNumber: number): Combo => ({
  number: nextNumber, label: "", price: 0, enabled: true, photo: null,
  slots: [{ label: "", options: [{ key: "" }] }],
});

// One local row: a stable client key + its editable draft.
type Row = { cid: number; combo: Combo };

export default function Combos({ id, combos, sellables, groups }: {
  id: number; combos: Combo[]; sellables: Item[]; groups?: ComboGroup[];
}) {
  const cidRef = useRef(1);
  const [rows, setRows] = useState<Row[]>(() => (combos || []).map((c) => ({ cid: cidRef.current++, combo: c })));
  const [openCid, setOpenCid] = useState<number | null>(null);

  const nextNumber = useMemo(
    () => rows.reduce((m, r) => Math.max(m, r.combo.number || 0), 0) + 1,
    [rows],
  );
  // numbers used by OTHER combos, for the duplicate-number warning per card
  const numbersByCid = useMemo(() => rows.map((r) => ({ cid: r.cid, number: r.combo.number })), [rows]);

  // Picker options: every access group ("Any Bakery") first, then each sellable.
  const groupList = groups || [];
  const pickerItems = useMemo<Item[]>(() => [
    ...groupList.map((g) => ({ name: groupKey(g.group), label: _L("combo.any_group", g.group), image: undefined })),
    ...sellables,
  ], [groupList, sellables]);
  const groupCount = useMemo(() => Object.fromEntries(groupList.map((g) => [g.group, g.count])), [groupList]);

  const patch = (cid: number, combo: Combo) =>
    setRows((rs) => rs.map((r) => (r.cid === cid ? { ...r, combo } : r)));
  const setServerId = (cid: number, serverId: number) =>
    setRows((rs) => rs.map((r) => (r.cid === cid ? { ...r, combo: { ...r.combo, id: serverId } } : r)));

  const addCombo = () => {
    const cid = cidRef.current++;
    setRows((rs) => [...rs, { cid, combo: blankCombo(nextNumber) }]);
    setOpenCid(cid);
  };
  const removeCombo = async (row: Row) => {
    if (row.combo.id) await fetchNui("management:deleteCombo", { id, comboId: row.combo.id });
    setRows((rs) => rs.filter((r) => r.cid !== row.cid));
    if (openCid === row.cid) setOpenCid(null);
  };

  return (
    <div className="space-y-3">
      <div className="flex items-start justify-between gap-2">
        <p className="text-[11px] text-muted-foreground">{_L("combo.intro")}</p>
        <Button size="sm" className="shrink-0" onClick={addCombo}><Plus className="h-4 w-4" /> {_L("combo.new")}</Button>
      </div>

      {rows.length === 0 && (
        <div className="py-6 text-center text-sm text-muted-foreground">{_L("combo.none_yet")}</div>
      )}

      {rows.map((row) => (
        <ComboCard
          key={row.cid}
          id={id}
          combo={row.combo}
          sellables={sellables}
          pickerItems={pickerItems}
          groupCount={groupCount}
          open={openCid === row.cid}
          duplicateNumber={numbersByCid.some((n) => n.cid !== row.cid && n.number === row.combo.number)}
          onToggle={() => setOpenCid((c) => (c === row.cid ? null : row.cid))}
          onChange={(c) => patch(row.cid, c)}
          onSaved={(serverId) => setServerId(row.cid, serverId)}
          onDelete={() => removeCombo(row)}
        />
      ))}
    </div>
  );
}

// A readable label for one option key (item OR group), for the collapsed summary.
function optionLabel(key: string, byKey: Record<string, Item>): string {
  if (isGroupKey(key)) return _L("combo.any_group", groupOf(key));
  return byKey[key]?.label || key || "?";
}

function ComboCard({
  id, combo, sellables, pickerItems, groupCount, open, duplicateNumber, onToggle, onChange, onSaved, onDelete,
}: {
  id: number; combo: Combo; sellables: Item[]; pickerItems: Item[]; groupCount: Record<string, number>;
  open: boolean; duplicateNumber: boolean;
  onToggle: () => void; onChange: (c: Combo) => void; onSaved: (serverId: number) => void; onDelete: () => void;
}) {
  // server id is kept in a ref so capturing it after the first insert doesn't
  // retrigger the autosave (the id isn't part of the change signature)
  const idRef = useRef<number | undefined>(combo.id);
  idRef.current = combo.id;

  const byKey = useMemo(() => Object.fromEntries(sellables.map((s) => [s.name, s])), [sellables]);
  const set = (p: Partial<Combo>) => onChange({ ...combo, ...p });

  // A combo only publishes once it has a name AND at least one real pick in a slot —
  // an empty draft is skipped (the server would reject it) and flagged inline below.
  const hasPick = combo.slots.some((s) => s.options.some((o) => (o.key || "").trim() !== ""));
  const incomplete = !combo.label.trim() || !hasPick;

  // change signature drives the debounced save (id excluded — see above)
  const sig = JSON.stringify({
    number: combo.number, label: combo.label, price: combo.price, enabled: combo.enabled,
    photo: combo.photo, slots: combo.slots,
  });
  const status = useAutoSave(async () => {
    if (incomplete) return; // server rejects; don't churn
    const res: any = await fetchNui("management:saveCombo", {
      id, comboId: idRef.current,
      number: combo.number, label: combo.label, price: combo.price, enabled: combo.enabled,
      photo: combo.photo?.url ? { url: combo.photo.url, crop: combo.photo.crop || undefined } : undefined,
      // drop blank picks before saving; keep item + group keys verbatim
      slots: combo.slots.map((s) => ({
        label: s.label,
        options: s.options.filter((o) => (o.key || "").trim() !== "").map((o) => ({ key: o.key })),
      })).filter((s) => s.options.length > 0),
    });
    if (res && res.ok && res.comboId) { idRef.current = res.comboId; onSaved(res.comboId); }
  }, [sig]);

  // slot mutation helpers
  const setSlots = (slots: ComboSlot[]) => set({ slots });
  const updateSlot = (si: number, p: Partial<ComboSlot>) => setSlots(combo.slots.map((s, i) => (i === si ? { ...s, ...p } : s)));
  const addSlot = () => setSlots([...combo.slots, { label: "", options: [{ key: "" }] }]);
  const removeSlot = (si: number) => setSlots(combo.slots.filter((_, i) => i !== si));
  const addOption = (si: number) => updateSlot(si, { options: [...combo.slots[si].options, { key: "" }] });
  const setOption = (si: number, oi: number, key: string) =>
    updateSlot(si, { options: combo.slots[si].options.map((o, i) => (i === oi ? { key } : o)) });
  const removeOption = (si: number, oi: number) =>
    updateSlot(si, { options: combo.slots[si].options.filter((_, i) => i !== oi) });

  const invalid = combo.stale;

  return (
    <div className={cn("rounded-lg border p-3", invalid ? "border-destructive/50 bg-destructive/5" : "border-border")}>
      <div className="flex items-center justify-between gap-2">
        <button className="flex min-w-0 items-center gap-3 text-left" onClick={onToggle}>
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-primary/15 font-mono text-sm font-bold text-primary tabular-nums">
            {combo.number}
          </span>
          <span className="min-w-0">
            <span className="flex flex-wrap items-center gap-2">
              <span className="truncate font-medium">{combo.label || _L("combo.name_placeholder")}</span>
              <Badge variant="secondary" className="gap-1"><UtensilsCrossed className="h-3 w-3" /> {money(combo.price)}</Badge>
              {!combo.enabled && <Badge variant="outline">{_L("combo.disabled_badge")}</Badge>}
              {incomplete && !invalid && <Badge variant="outline" className="gap-1 text-muted-foreground">{_L("combo.draft")}</Badge>}
              {invalid && <Badge variant="destructive" className="gap-1"><TriangleAlert className="h-3 w-3" /> {_L("combo.invalid_option")}</Badge>}
            </span>
            <span className="mt-0.5 block truncate text-[11px] text-muted-foreground">
              {combo.slots
                .filter((s) => s.options.some((o) => o.key))
                .map((s) => (s.options.filter((o) => o.key).length > 1 ? (s.label || _L("combo.choose_one")) : optionLabel(s.options.find((o) => o.key)?.key || "", byKey)))
                .join(" · ") || _L("combo.slots")}
            </span>
          </span>
        </button>
        <div className="flex shrink-0 items-center gap-2">
          {status === "saving" && <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground" />}
          {status === "saved" && <Check className="h-3.5 w-3.5 text-primary" />}
          <Button size="sm" variant={open ? "secondary" : "outline"} onClick={onToggle}><Pencil className="h-4 w-4" /></Button>
          <Button size="sm" variant="destructive" onClick={onDelete}><Trash2 className="h-4 w-4" /></Button>
        </div>
      </div>

      {open && (
        <div className="mt-3 space-y-3 border-t border-border pt-3">
          {invalid && <div className="rounded-md bg-destructive/10 px-2.5 py-1.5 text-[11px] text-destructive">{_L("combo.stale")}</div>}

          <div className="grid grid-cols-[5rem_1fr_7rem] gap-3">
            <Field label={_L("combo.number")}>
              <Input type="number" min={0} value={combo.number}
                onChange={(e) => set({ number: Math.max(0, Math.floor(Number(e.target.value) || 0)) })} />
              {duplicateNumber && <span className="mt-1 block text-[10px] text-amber-500">{_L("combo.duplicate_number", combo.number)}</span>}
            </Field>
            <Field label={_L("combo.name")}>
              <Input value={combo.label} placeholder={_L("combo.name_placeholder")} onChange={(e) => set({ label: e.target.value })} />
            </Field>
            <Field label={_L("combo.price")}>
              <Input type="number" min={0} value={combo.price}
                onChange={(e) => set({ price: Math.max(0, Math.floor(Number(e.target.value) || 0)) })} />
            </Field>
          </div>

          <div className="grid grid-cols-[1fr_auto] items-start gap-3">
            <Field label={_L("combo.slots")}>
              <div className="space-y-2">
                {combo.slots.map((slot, si) => (
                  <SlotRow
                    key={si}
                    index={si}
                    slot={slot}
                    sellables={sellables}
                    pickerItems={pickerItems}
                    byKey={byKey}
                    groupCount={groupCount}
                    onLabel={(v) => updateSlot(si, { label: v })}
                    onSetOption={(oi, key) => setOption(si, oi, key)}
                    onAddOption={() => addOption(si)}
                    onRemoveOption={(oi) => removeOption(si, oi)}
                    onRemove={() => removeSlot(si)}
                  />
                ))}
                <Button size="sm" variant="outline" onClick={addSlot}><Plus className="h-4 w-4" /> {_L("combo.add_slot")}</Button>
              </div>
            </Field>
            <div className="w-44">
              <span className="tape mb-1 block">{_L("combo.photo")}</span>
              <PhotoField aspect={COMBO_PHOTO()} entry={combo.photo} onChange={(e) => set({ photo: e })}
                empty={_L("combo.photo_hint")} />
            </div>
          </div>

          {incomplete && (
            <div className="rounded-md bg-muted/60 px-2.5 py-1.5 text-[11px] text-muted-foreground">{_L("combo.incomplete_hint")}</div>
          )}

          <div className="flex items-center justify-between">
            <Toggle checked={combo.enabled} onChange={(v) => set({ enabled: v })} label={_L("combo.enabled")} />
            <Button size="sm" variant="outline" onClick={onToggle}>{_L("combo.done")}</Button>
          </div>
        </div>
      )}
    </div>
  );
}

// The thumbnail for one pick: a group icon for an "any <group>" pick, the item's
// image for a fixed item, or a neutral dashed placeholder for an empty pick.
function OptionThumb({ opt, sellables, className }: { opt: ComboOption; sellables: Item[]; className?: string }) {
  if (isGroupKey(opt.key)) {
    return (
      <div className={cn("flex items-center justify-center rounded bg-primary/15 text-primary", className)}>
        <Layers className="h-1/2 w-1/2" />
      </div>
    );
  }
  if (!opt.key) {
    return (
      <div className={cn("flex items-center justify-center rounded border border-dashed border-border/70 text-muted-foreground/60", className)}>
        <UtensilsCrossed className="h-1/2 w-1/2" />
      </div>
    );
  }
  return <ItemImage items={sellables} name={opt.key} className={className} />;
}

function SlotRow({
  index, slot, sellables, pickerItems, byKey, groupCount, onLabel, onSetOption, onAddOption, onRemoveOption, onRemove,
}: {
  index: number; slot: ComboSlot; sellables: Item[]; pickerItems: Item[]; byKey: Record<string, Item>;
  groupCount: Record<string, number>;
  onLabel: (v: string) => void; onSetOption: (oi: number, key: string) => void;
  onAddOption: () => void; onRemoveOption: (oi: number) => void; onRemove: () => void;
}) {
  const filled = slot.options.filter((o) => o.key);
  const isChoice = filled.length > 1;
  return (
    <div className={cn("rounded-md border p-2", slot.stale ? "border-destructive/50 bg-destructive/5" : "border-border/60")}>
      <div className="mb-2 flex items-center gap-2">
        <ChevronRight className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
        <Input value={slot.label} placeholder={_L("combo.slot_label_placeholder", index + 1)} className="h-8 flex-1"
          onChange={(e) => onLabel(e.target.value)} />
        {isChoice && <Badge variant="secondary" className="shrink-0">{_L("combo.choose_one")}</Badge>}
        <Button size="icon" variant="ghost" className="shrink-0" onClick={onRemove}><Trash2 className="h-4 w-4" /></Button>
      </div>
      <div className="space-y-1.5 pl-5">
        {slot.options.map((o, oi) => {
          const isGroup = isGroupKey(o.key);
          // a fixed item is "known" if in the catalog; a group is known if it still has members
          const known = isGroup ? (groupCount[groupOf(o.key)] || 0) > 0 : (!!o.key && (byKey[o.key] || o.valid));
          return (
            <div key={oi} className="flex items-center gap-2">
              <OptionThumb opt={o} sellables={sellables} className="h-8 w-8 shrink-0" />
              <div className="min-w-0 flex-1">
                <ItemPicker items={pickerItems} value={o.key} placeholder={_L("combo.pick_item")}
                  onChange={(v) => onSetOption(oi, v)} />
                {isGroup && known && (
                  <span className="mt-0.5 block pl-0.5 text-[10px] text-muted-foreground">
                    {_L("combo.group_members", groupCount[groupOf(o.key)] || 0)}
                  </span>
                )}
              </div>
              {o.key && !known && (
                <span title={_L("combo.invalid_option")} className="shrink-0 text-destructive"><TriangleAlert className="h-4 w-4" /></span>
              )}
              <Button size="icon" variant="ghost" className="shrink-0" onClick={() => onRemoveOption(oi)}><Trash2 className="h-4 w-4" /></Button>
            </div>
          );
        })}
        <div className="flex items-center gap-2">
          <Button size="sm" variant="ghost" onClick={onAddOption}><Plus className="h-3.5 w-3.5" /> {_L("combo.add_option")}</Button>
          <span className="text-[10px] text-muted-foreground">{isChoice ? _L("combo.choose_hint") : _L("combo.choice_hint_single")}</span>
        </div>
      </div>
    </div>
  );
}
