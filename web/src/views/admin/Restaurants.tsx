import { useEffect, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Field } from "@/components/form";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import Branding, { ThemeEditor } from "@/components/Branding";
import { applyTheme, type ThemeConfig } from "@/lib/theme";
import { money } from "@/lib/utils";
import { _L } from "@/lib/locale";
import {
  Plus, Trash2, MapPin, ChevronRight, ArrowLeft, CupSoda, Flame, Sandwich, CookingPot, UserCog, Receipt, Armchair, Image as ImageIcon, Tags, X, Building2, Sparkles, Monitor, Users,
} from "lucide-react";

const STATIONS = [
  { key: "soda_machine", label: _L("admin.station_soda_machine"), icon: CupSoda },
  { key: "fryer", label: _L("admin.station_fryer"), icon: Flame },
  { key: "stovetop", label: _L("admin.station_stovetop"), icon: CookingPot },
  { key: "kitchen_prep", label: _L("admin.station_kitchen_prep"), icon: Sandwich },
  // Self-service order kiosk — a physical customer terminal, no virtual variant.
  { key: "kiosk", label: _L("admin.station_kiosk"), icon: Monitor, physicalOnly: true },
  // Free-standing floor kiosk (the _02 body) — same terminal, ground-placed.
  { key: "kiosk_ground", label: _L("admin.station_kiosk_ground"), icon: Monitor, physicalOnly: true },
];

type Focus = { restaurant?: number; section?: string };
type Props = { restaurants: any[]; players: any[]; groups: string[]; refresh: () => void; focus?: Focus; appTheme?: ThemeConfig | null; onDetailChange?: (open: boolean) => void };

export default function Restaurants({ restaurants, players, groups, refresh, focus, appTheme, onDetailChange }: Props) {
  // After a placement reopen, `focus.restaurant` drops us straight back into that
  // restaurant (and `focus.section` scrolls to its stations/seating).
  const [selectedId, setSelectedId] = useState<number | null>(focus?.restaurant ?? null);
  // Optimistic per-restaurant theme edits. The theme editor auto-saves to the DB,
  // but the open-payload `restaurants` array stays stale; we mirror the live seed
  // here so leaving and reopening a detail re-applies the CURRENT theme (not the
  // one the panel opened with). Survives detail unmount — this component stays up.
  const [themeEdits, setThemeEdits] = useState<Record<number, ThemeConfig>>({});
  const base = restaurants.find((r) => r.id === selectedId) || null;
  const selected = base && themeEdits[base.id] ? { ...base, theme: themeEdits[base.id] } : base;

  // Tell the shell whether a single restaurant's detail is open, so it can drop the
  // top-level admin tab strip (Restaurants / Recipes / Settings) while you're inside
  // one restaurant — the detail has its own back button + header, and the two levels
  // of tabs stacked together are what read as confusing.
  const isDetail = !!selected;
  useEffect(() => {
    onDetailChange?.(isDetail);
    return () => onDetailChange?.(false);
  }, [isDetail]);

  const act = async (event: string, payload: any) => { await fetchNui(event, payload); await refresh(); };

  if (selected) {
    return (
      <Detail
        r={selected}
        players={players}
        groups={groups}
        act={act}
        onBack={() => setSelectedId(null)}
        focusSection={selected.id === focus?.restaurant ? focus?.section : undefined}
        appTheme={appTheme}
        onThemeChange={(t) => setThemeEdits((m) => ({ ...m, [selected.id]: t }))}
      />
    );
  }
  return <List restaurants={restaurants} act={act} onOpen={setSelectedId} />;
}

function List({ restaurants, act, onOpen }: { restaurants: any[]; act: (e: string, p: any) => void; onOpen: (id: number) => void }) {
  const [name, setName] = useState("");
  const [label, setLabel] = useState("");
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      <div className="flex shrink-0 items-end gap-2 rounded-lg border border-border p-3">
        <Field label={_L("admin.internal_name")} className="flex-1"><Input value={name} onChange={(e) => setName(e.target.value)} placeholder="burgershot" /></Field>
        <Field label={_L("admin.display_label")} className="flex-1"><Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Burger Shot" /></Field>
        <Button onClick={async () => { if (!name) return; await act("admin:create", { name, label: label || name }); setName(""); setLabel(""); }}>
          <Plus className="h-4 w-4" /> {_L("admin.create")}
        </Button>
      </div>

      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {restaurants.length === 0 && <div className="py-6 text-center text-sm text-muted-foreground">{_L("admin.no_restaurants")}</div>}
        {restaurants.map((r) => (
          <button
            key={r.id}
            onClick={() => onOpen(r.id)}
            className="flex w-full items-center justify-between gap-3 rounded-lg border border-border/80 bg-card p-3 text-left transition-colors hover:border-primary/50 hover:bg-accent/60"
          >
            <div className="flex min-w-0 items-center gap-3">
              {/* franchise monogram, tinted by ITS theme seed (not the panel's) */}
              <div
                className="grid h-10 w-10 shrink-0 place-items-center rounded-md font-display text-lg font-bold"
                style={{
                  // "#rrggbb29" = the seed at ~16% alpha (no color-mix in CEF)
                  backgroundColor: r.theme?.primary ? r.theme.primary + "29" : "rgb(var(--brand) / 0.16)",
                  color: r.theme?.primary || "rgb(var(--brand))",
                }}
              >
                {(r.label?.trim()[0] || "•").toUpperCase()}
              </div>
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="truncate font-semibold">{r.label}</span>
                  <Badge variant="secondary">#{r.id}</Badge>
                  {r.owner ? <Badge>{_L("admin.owned")}</Badge> : <Badge variant="outline">{_L("admin.server_owned")}</Badge>}
                </div>
                <div className="truncate text-xs text-muted-foreground">
                  {_L("admin.restaurant_summary", money(r.balance), r.propCount, r.hasCounter ? _L("admin.counter_set") : _L("admin.no_counter"))}
                </div>
              </div>
            </div>
            <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground" />
          </button>
        ))}
      </div>
    </div>
  );
}

function Detail({ r, players, groups, act, onBack, focusSection, appTheme, onThemeChange }: { r: any; players: any[]; groups: string[]; act: (e: string, p: any) => void; onBack: () => void; focusSection?: string; appTheme?: ThemeConfig | null; onThemeChange?: (t: ThemeConfig) => void }) {
  const props: any[] = r.props || [];
  const byType = (t: string) => props.filter((p) => p.prop_type === t);
  const [confirmDelete, setConfirmDelete] = useState(false);
  // Per-station placement mode: physical world prop vs. virtual point (opens the
  // station inside the kitchen shell). Toggled per row, drives the Place button.
  const [modes, setModes] = useState<Record<string, "physical" | "virtual">>({});
  const setMode = (k: string, m: "physical" | "virtual") => setModes((prev) => ({ ...prev, [k]: m }));
  const stationsRef = useRef<HTMLDivElement>(null);
  const seatingRef = useRef<HTMLDivElement>(null);

  // Scroll the just-used section into view when reopened from a placement flow.
  // Virtual placement lives in the stations card now, so "virtual" lands there.
  useEffect(() => {
    if (!focusSection) return;
    const el = focusSection === "seating" ? seatingRef.current : stationsRef.current;
    const t = setTimeout(() => el?.scrollIntoView({ behavior: "smooth", block: "start" }), 60);
    return () => clearTimeout(t);
  }, [focusSection]);

  // Preview this restaurant's franchise theme while its detail is open; back to
  // the panel's OWN theme on the way out (the theme editor also applies live). A
  // ref keeps the cleanup reading the CURRENT app theme, not the one at mount.
  const appThemeRef = useRef(appTheme);
  appThemeRef.current = appTheme;
  useEffect(() => {
    applyTheme(r.theme);
    return () => applyTheme(appThemeRef.current);
  }, [r.id]);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      {/* header */}
      <div className="flex shrink-0 items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="icon" onClick={onBack}><ArrowLeft className="h-4 w-4" /></Button>
          <div>
            <div className="flex items-center gap-2">
              <h3 className="font-display text-base font-bold tracking-tight">{r.label}</h3>
              <Badge variant="secondary">#{r.id}</Badge>
              <span className="font-mono text-xs text-muted-foreground">{r.name}</span>
            </div>
            <p className="text-xs text-muted-foreground">{_L("admin.balance", money(r.balance))}</p>
          </div>
        </div>
        {confirmDelete ? (
          <div className="flex items-center gap-2">
            <span className="text-xs text-muted-foreground">{_L("admin.delete_confirm", r.label)}</span>
            <Button variant="ghost" size="sm" onClick={() => setConfirmDelete(false)}>{_L("admin.cancel")}</Button>
            <Button variant="destructive" size="sm" onClick={() => { act("admin:delete", { id: r.id }); onBack(); }}>
              <Trash2 className="h-4 w-4" /> {_L("admin.confirm")}
            </Button>
          </div>
        ) : (
          <Button variant="destructive" size="sm" onClick={() => setConfirmDelete(true)}>
            <Trash2 className="h-4 w-4" /> {_L("admin.delete")}
          </Button>
        )}
      </div>

      <Tabs defaultValue="overview" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          <TabsTrigger value="overview">{_L("admin.tab_overview")}</TabsTrigger>
          <TabsTrigger value="settings">{_L("admin.tab_settings")}</TabsTrigger>
        </TabsList>

        <TabsContent value="overview" className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
        {/* ownership + counter */}
        <div className="grid grid-cols-2 gap-3">
          <div className="rounded-lg border border-border p-3">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold"><UserCog className="h-4 w-4 text-primary" /> {_L("admin.ownership")}</div>
            <div className="mb-2 text-xs text-muted-foreground">
              {r.owner ? <>{_L("admin.owned_by", "")}<span className="font-mono">{r.owner}</span></> : _L("admin.currently_server_owned")}
            </div>
            <select
              className="h-9 w-full rounded-md border border-input bg-muted/50 px-2 text-sm transition-colors focus-visible:border-primary/60 focus-visible:outline-none"
              value=""
              onChange={(e) => {
                const v = e.target.value;
                if (v === "") return;
                act("admin:setOwner", { id: r.id, target: v === "__server__" ? false : Number(v) });
                e.target.value = "";
              }}
            >
              <option value="" disabled>{_L("admin.change_owner")}</option>
              <option value="__server__">{_L("admin.set_server_owned")}</option>
              {players.map((p: any) => <option key={p.id} value={p.id}>{p.name} [{p.id}]</option>)}
            </select>
          </div>
          <div className="rounded-lg border border-border p-3">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold"><Receipt className="h-4 w-4 text-primary" /> {_L("admin.counter")}</div>
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted-foreground">{r.hasCounter ? _L("admin.counter_placed") : _L("admin.no_counter_placed")}</span>
              <Button size="sm" variant="outline" onClick={() => fetchNui("admin:setCounter", { id: r.id })}>
                <MapPin className="h-3.5 w-3.5" /> {r.hasCounter ? _L("admin.reposition") : _L("admin.place")}
              </Button>
            </div>
          </div>
          {/* NPC customer spawn point — where AI customers appear before walking up to
              queue. Without it they spawn a fixed distance back and can get stuck. */}
          <div className="rounded-lg border border-border p-3">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold"><Users className="h-4 w-4 text-primary" /> {_L("admin.npc_spawn")}</div>
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs text-muted-foreground">{r.hasNpcSpawn ? _L("admin.npc_spawn_placed") : _L("admin.no_npc_spawn")}</span>
              <Button size="sm" variant="outline" onClick={() => fetchNui("admin:placeNpcSpawn", { id: r.id })}>
                <MapPin className="h-3.5 w-3.5" /> {r.hasNpcSpawn ? _L("admin.reposition") : _L("admin.place")}
              </Button>
            </div>
          </div>
        </div>

        {/* stations — each type places EITHER a physical world prop or a virtual
            point (an invisible anchor that opens the station inside the kitchen
            shell). The per-row toggle picks the mode; the shell control up top is
            the prerequisite for virtual points (one shell per restaurant). */}
        <div ref={stationsRef} className="rounded-lg border border-border p-3">
          <div className="mb-2 flex items-center justify-between gap-2">
            <div className="text-sm font-semibold">{_L("admin.stations")}</div>
            <Button size="sm" variant="outline" disabled={!r.hasCounter} onClick={() => fetchNui("admin:placeShell", { id: r.id })}>
              <Building2 className="h-3.5 w-3.5" /> {r.hasShell ? _L("admin.adjust_shell") : _L("admin.place_shell")}
            </Button>
          </div>
          <p className="mb-3 text-[11px] text-muted-foreground">
            {!r.hasCounter ? _L("admin.shell_needs_counter") : r.hasShell ? _L("admin.shell_placed") : _L("admin.no_shell")}
          </p>
          <div className="space-y-3">
            {STATIONS.map((s) => {
              const physical = byType(s.key);
              const virtual = props.filter((p) => p.prop_type === "virtual_point" && p.target === s.key);
              const isVirtual = !s.physicalOnly && (modes[s.key] || "physical") === "virtual";
              const Icon = s.icon;
              return (
                <div key={s.key}>
                  <div className="mb-1.5 flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 text-sm">
                      <Icon className="h-4 w-4 text-muted-foreground" />
                      {s.label}
                      <Badge variant="secondary">{physical.length + virtual.length}</Badge>
                    </div>
                    <div className="flex items-center gap-1.5">
                      {/* physical | virtual placement toggle */}
                      {!s.physicalOnly && (
                      <div className="flex rounded-md border border-border p-0.5 text-[11px]">
                        <button
                          className={`rounded px-2 py-0.5 transition-colors ${!isVirtual ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"}`}
                          onClick={() => setMode(s.key, "physical")}
                        >{_L("admin.mode_physical")}</button>
                        <button
                          className={`rounded px-2 py-0.5 transition-colors ${isVirtual ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:text-foreground"}`}
                          onClick={() => setMode(s.key, "virtual")}
                        >{_L("admin.mode_virtual")}</button>
                      </div>
                      )}
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={isVirtual && !r.hasShell}
                        onClick={() => isVirtual
                          ? fetchNui("admin:placeVirtualPoint", { id: r.id, target: s.key })
                          : fetchNui("admin:placeProp", { id: r.id, prop_type: s.key })}
                      >
                        {isVirtual ? <Sparkles className="h-3.5 w-3.5" /> : <Plus className="h-3.5 w-3.5" />} {_L("admin.place")}
                      </Button>
                    </div>
                  </div>
                  {isVirtual && !r.hasShell && (
                    <p className="mb-1 text-[11px] text-muted-foreground">{_L("admin.virtual_needs_shell")}</p>
                  )}
                  {(physical.length > 0 || virtual.length > 0) && (
                    <div className="flex flex-wrap gap-1.5">
                      {physical.map((p) => (
                        <Badge key={p.id} variant="outline" className="gap-1.5">
                          #{p.id}
                          <button onClick={() => act("admin:removeProp", { propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                        </Badge>
                      ))}
                      {virtual.map((p) => (
                        <Badge key={p.id} variant="outline" className="gap-1.5" title={_L("admin.mode_virtual")}>
                          <Sparkles className="h-3 w-3 text-primary" /> #{p.id}
                          <button onClick={() => act("admin:removeProp", { propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                        </Badge>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
          <p className="mt-3 text-[11px] text-muted-foreground">
            {_L("admin.stations_hint")}
          </p>
        </div>

        {/* seating — invisible sit anchors; players sit on existing furniture */}
        <div ref={seatingRef} className="rounded-lg border border-border p-3">
          <div className="mb-1.5 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Armchair className="h-4 w-4 text-muted-foreground" /> {_L("admin.seating")}
              <Badge variant="secondary">{byType("seat").length}</Badge>
            </div>
            <Button size="sm" variant="outline" onClick={() => fetchNui("admin:placeSeat", { id: r.id })}>
              <Plus className="h-3.5 w-3.5" /> {_L("admin.place")}
            </Button>
          </div>
          {byType("seat").length > 0 ? (
            <div className="flex flex-wrap gap-1.5">
              {byType("seat").map((p) => (
                <Badge key={p.id} variant="outline" className="gap-1.5">
                  #{p.id}
                  <button onClick={() => act("admin:removeProp", { propId: p.id })}><Trash2 className="h-3 w-3" /></button>
                </Badge>
              ))}
            </div>
          ) : (
            <p className="text-[11px] text-muted-foreground">
              {_L("admin.seating_hint")}
            </p>
          )}
        </div>

        </TabsContent>

        {/* per-restaurant settings — branding (per-texture packaging photos, same
            editor as the boss panel). Server-wide settings live in the top-level
            Settings tab; this is scoped to THIS restaurant. */}
        <TabsContent value="settings" className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
          <ThemeEditor id={r.id} theme={r.theme} event="admin:setTheme" onChange={onThemeChange} />

          {/* recipe access groups — what this restaurant may cook & sell */}
          <div className="rounded-lg border border-border p-3">
            <div className="mb-1 flex items-center gap-2 text-sm font-semibold">
              <Tags className="h-4 w-4 text-primary" /> {_L("admin.groups_title")}
            </div>
            <p className="mb-3 text-[11px] text-muted-foreground">{_L("admin.groups_hint")}</p>
            <GroupsEditor r={r} groups={groups} act={act} />
          </div>

          <div className="rounded-lg border border-border p-3">
            <div className="mb-3 flex items-center gap-2 text-sm font-semibold">
              <ImageIcon className="h-4 w-4 text-primary" /> {_L("admin.branding")}
            </div>
            <Branding
              id={r.id}
              brand={r.brand_image || ""}
              brandImages={r.brand_images || {}}
              event="admin:setBrandImage"
            />
          </div>
        </TabsContent>
      </Tabs>
    </div>
  );
}

/**
 * The restaurant's access-group chips: remove with the chip's ×, add via the
 * creatable input (suggestions = every group already in use). Each add/remove
 * saves immediately — a chip edit is a discrete action, no debounce needed.
 */
function GroupsEditor({ r, groups, act }: { r: any; groups: string[]; act: (e: string, p: any) => void }) {
  const [draft, setDraft] = useState("");
  const current: string[] = r.groups || [];
  const save = (next: string[]) => act("admin:setGroups", { id: r.id, groups: next });
  const add = () => {
    const g = draft.trim();
    if (!g || current.includes(g)) { setDraft(""); return; }
    save([...current, g]);
    setDraft("");
  };
  const suggestions = groups.filter((g) => !current.includes(g));
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-1.5">
        {current.length === 0 && <span className="text-xs text-muted-foreground">{_L("admin.groups_none")}</span>}
        {current.map((g) => (
          <Badge key={g} variant="secondary" className="gap-1.5">
            {g}
            <button onClick={() => save(current.filter((x) => x !== g))}><X className="h-3 w-3" /></button>
          </Badge>
        ))}
      </div>
      <div className="flex items-center gap-2">
        <Input
          className="h-8 max-w-56"
          list={`groups-${r.id}`}
          placeholder={_L("admin.groups_placeholder")}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") add(); }}
        />
        <datalist id={`groups-${r.id}`}>
          {suggestions.map((g) => <option key={g} value={g} />)}
        </datalist>
        <Button size="sm" variant="outline" onClick={add} disabled={!draft.trim()}>
          <Plus className="h-3.5 w-3.5" /> {_L("admin.groups_add")}
        </Button>
      </div>
    </div>
  );
}
