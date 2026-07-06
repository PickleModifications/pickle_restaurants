import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Field } from "@/components/form";
import Branding from "@/components/Branding";
import { money } from "@/lib/utils";
import {
  Plus, Trash2, MapPin, ChevronRight, ArrowLeft, Store, CupSoda, Flame, Sandwich, CookingPot, UserCog, Receipt, Armchair, Image as ImageIcon,
} from "lucide-react";

const STATIONS = [
  { key: "soda_machine", label: "Soda Machine", icon: CupSoda },
  { key: "fryer", label: "Fryer", icon: Flame },
  { key: "stovetop", label: "Stovetop", icon: CookingPot },
  { key: "kitchen_prep", label: "Kitchen Prep", icon: Sandwich },
];

type Props = { restaurants: any[]; players: any[]; refresh: () => void };

export default function Restaurants({ restaurants, players, refresh }: Props) {
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const selected = restaurants.find((r) => r.id === selectedId) || null;

  const act = async (event: string, payload: any) => { await fetchNui(event, payload); await refresh(); };

  if (selected) {
    return <Detail r={selected} players={players} act={act} onBack={() => setSelectedId(null)} />;
  }
  return <List restaurants={restaurants} act={act} onOpen={setSelectedId} />;
}

function List({ restaurants, act, onOpen }: { restaurants: any[]; act: (e: string, p: any) => void; onOpen: (id: number) => void }) {
  const [name, setName] = useState("");
  const [label, setLabel] = useState("");
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      <div className="flex shrink-0 items-end gap-2 rounded-lg border border-border p-3">
        <Field label="Internal name" className="flex-1"><Input value={name} onChange={(e) => setName(e.target.value)} placeholder="burgershot" /></Field>
        <Field label="Display label" className="flex-1"><Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Burger Shot" /></Field>
        <Button onClick={async () => { if (!name) return; await act("admin:create", { name, label: label || name }); setName(""); setLabel(""); }}>
          <Plus className="h-4 w-4" /> Create
        </Button>
      </div>

      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto pr-1">
        {restaurants.length === 0 && <div className="py-6 text-center text-sm text-muted-foreground">No restaurants yet. Create one above.</div>}
        {restaurants.map((r) => (
          <button
            key={r.id}
            onClick={() => onOpen(r.id)}
            className="flex w-full items-center justify-between gap-3 rounded-lg border border-border p-3 text-left transition-colors hover:border-primary/50 hover:bg-accent/50"
          >
            <div className="flex min-w-0 items-center gap-3">
              <div className="grid h-10 w-10 shrink-0 place-items-center rounded-lg bg-primary/15 text-primary"><Store className="h-5 w-5" /></div>
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="truncate font-semibold">{r.label}</span>
                  <Badge variant="secondary">#{r.id}</Badge>
                  {r.owner ? <Badge>owned</Badge> : <Badge variant="outline">server-owned</Badge>}
                </div>
                <div className="truncate text-xs text-muted-foreground">
                  {money(r.balance)} · {r.propCount} stations · {r.hasCounter ? "counter set" : "no counter"}
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

function Detail({ r, players, act, onBack }: { r: any; players: any[]; act: (e: string, p: any) => void; onBack: () => void }) {
  const props: any[] = r.props || [];
  const byType = (t: string) => props.filter((p) => p.prop_type === t);
  const [confirmDelete, setConfirmDelete] = useState(false);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-3">
      {/* header */}
      <div className="flex shrink-0 items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="icon" onClick={onBack}><ArrowLeft className="h-4 w-4" /></Button>
          <div>
            <div className="flex items-center gap-2">
              <h3 className="text-base font-semibold">{r.label}</h3>
              <Badge variant="secondary">#{r.id}</Badge>
              <span className="font-mono text-xs text-muted-foreground">{r.name}</span>
            </div>
            <p className="text-xs text-muted-foreground">Balance {money(r.balance)}</p>
          </div>
        </div>
        {confirmDelete ? (
          <div className="flex items-center gap-2">
            <span className="text-xs text-muted-foreground">Delete {r.label} and all its data?</span>
            <Button variant="ghost" size="sm" onClick={() => setConfirmDelete(false)}>Cancel</Button>
            <Button variant="destructive" size="sm" onClick={() => { act("admin:delete", { id: r.id }); onBack(); }}>
              <Trash2 className="h-4 w-4" /> Confirm
            </Button>
          </div>
        ) : (
          <Button variant="destructive" size="sm" onClick={() => setConfirmDelete(true)}>
            <Trash2 className="h-4 w-4" /> Delete
          </Button>
        )}
      </div>

      <div className="min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
        {/* ownership + counter */}
        <div className="grid grid-cols-2 gap-3">
          <div className="rounded-lg border border-border p-3">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold"><UserCog className="h-4 w-4 text-primary" /> Ownership</div>
            <div className="mb-2 text-xs text-muted-foreground">
              {r.owner ? <>Owned by <span className="font-mono">{r.owner}</span></> : "Currently server-owned."}
            </div>
            <select
              className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm"
              value=""
              onChange={(e) => {
                const v = e.target.value;
                if (v === "") return;
                act("admin:setOwner", { id: r.id, target: v === "__server__" ? false : Number(v) });
                e.target.value = "";
              }}
            >
              <option value="" disabled>Change owner…</option>
              <option value="__server__">Set server-owned</option>
              {players.map((p: any) => <option key={p.id} value={p.id}>{p.name} [{p.id}]</option>)}
            </select>
          </div>
          <div className="rounded-lg border border-border p-3">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold"><Receipt className="h-4 w-4 text-primary" /> Counter</div>
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted-foreground">{r.hasCounter ? "Counter is placed." : "No counter placed yet."}</span>
              <Button size="sm" variant="outline" onClick={() => fetchNui("admin:setCounter", { id: r.id })}>
                <MapPin className="h-3.5 w-3.5" /> {r.hasCounter ? "Reposition" : "Place"}
              </Button>
            </div>
          </div>
        </div>

        {/* stations */}
        <div className="rounded-lg border border-border p-3">
          <div className="mb-3 text-sm font-semibold">Stations</div>
          <div className="space-y-3">
            {STATIONS.map((s) => {
              const placed = byType(s.key);
              const Icon = s.icon;
              return (
                <div key={s.key}>
                  <div className="mb-1.5 flex items-center justify-between">
                    <div className="flex items-center gap-2 text-sm">
                      <Icon className="h-4 w-4 text-muted-foreground" />
                      {s.label}
                      <Badge variant="secondary">{placed.length}</Badge>
                    </div>
                    <Button size="sm" variant="outline" onClick={() => fetchNui("admin:placeProp", { id: r.id, prop_type: s.key })}>
                      <Plus className="h-3.5 w-3.5" /> Place
                    </Button>
                  </div>
                  {placed.length > 0 && (
                    <div className="flex flex-wrap gap-1.5">
                      {placed.map((p) => (
                        <Badge key={p.id} variant="outline" className="gap-1.5">
                          #{p.id}
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
            Placing a station closes this panel so you can position it in the world. Re-open with the admin command to continue.
          </p>
        </div>

        {/* seating — invisible sit anchors; players sit on existing furniture */}
        <div className="rounded-lg border border-border p-3">
          <div className="mb-1.5 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Armchair className="h-4 w-4 text-muted-foreground" /> Seating
              <Badge variant="secondary">{byType("seat").length}</Badge>
            </div>
            <Button size="sm" variant="outline" onClick={() => fetchNui("admin:placeSeat", { id: r.id })}>
              <Plus className="h-3.5 w-3.5" /> Place
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
              A seat is an invisible sit point — place it on one of this restaurant's chairs and players get a “Sit” prompt there.
            </p>
          )}
        </div>

        {/* branding — per-texture packaging photos, same editor as the boss panel */}
        <div className="rounded-lg border border-border p-3">
          <div className="mb-3 flex items-center gap-2 text-sm font-semibold">
            <ImageIcon className="h-4 w-4 text-primary" /> Branding
          </div>
          <Branding
            id={r.id}
            brand={r.brand_image || ""}
            brandImages={r.brand_images || {}}
            event="admin:setBrandImage"
          />
        </div>
      </div>
    </div>
  );
}
