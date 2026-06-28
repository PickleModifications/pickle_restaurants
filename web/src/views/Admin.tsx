import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Card, CardContent } from "@/components/ui/card";
import { money } from "@/lib/utils";
import { Plus, Trash2, MapPin, UserCog, Boxes } from "lucide-react";

const STATIONS = ["soda_machine", "fryer", "stovetop", "kitchen_prep"];

export default function Admin({ data, onClose }: { data: any; onClose: () => void }) {
  const [name, setName] = useState("");
  const [label, setLabel] = useState("");
  const restaurants = data?.restaurants || [];
  const recipes = data?.recipes || [];
  const settings = data?.settings || {};
  const players = data?.players || [];

  const refresh = async () => {
    const fresh = await fetchNui<any>("admin:getData");
    if (fresh && fresh.ok) window.postMessage({ action: "setView", view: "admin", data: fresh }, "*");
  };

  const act = async (event: string, payload: any) => {
    await fetchNui(event, payload);
    await refresh();
  };

  return (
    <Panel title="Restaurant Administration" subtitle="Server-wide management" onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue="restaurants">
        <TabsList>
          <TabsTrigger value="restaurants">Restaurants</TabsTrigger>
          <TabsTrigger value="recipes">Recipes</TabsTrigger>
          <TabsTrigger value="settings">Settings</TabsTrigger>
        </TabsList>

        {/* RESTAURANTS */}
        <TabsContent value="restaurants" className="space-y-3">
          <Card>
            <CardContent className="flex items-end gap-2 pt-4">
              <div className="flex-1">
                <label className="mb-1 block text-xs text-muted-foreground">Internal name</label>
                <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="burgershot" />
              </div>
              <div className="flex-1">
                <label className="mb-1 block text-xs text-muted-foreground">Display label</label>
                <Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="Burger Shot" />
              </div>
              <Button
                onClick={async () => {
                  if (!name) return;
                  await act("admin:create", { name, label: label || name });
                  setName("");
                  setLabel("");
                }}
              >
                <Plus className="h-4 w-4" /> Create
              </Button>
            </CardContent>
          </Card>

          {restaurants.map((r: any) => (
            <Card key={r.id}>
              <CardContent className="pt-4">
                <div className="flex items-center justify-between">
                  <div>
                    <div className="flex items-center gap-2 font-semibold">
                      {r.label}
                      <Badge variant="secondary">#{r.id}</Badge>
                      {r.owner ? <Badge>owned</Badge> : <Badge variant="outline">server-owned</Badge>}
                    </div>
                    <div className="text-xs text-muted-foreground">
                      Balance {money(r.balance)} · {r.propCount} stations · {r.hasCounter ? "counter set" : "no counter"}
                    </div>
                  </div>
                  <Button variant="destructive" size="sm" onClick={() => act("admin:delete", { id: r.id })}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>

                <div className="mt-3 flex flex-wrap items-center gap-2">
                  {STATIONS.map((s) => (
                    <Button key={s} variant="outline" size="sm" onClick={() => fetchNui("admin:placeProp", { id: r.id, prop_type: s })}>
                      <MapPin className="h-3.5 w-3.5" /> {s.replace("_", " ")}
                    </Button>
                  ))}
                  <Button variant="outline" size="sm" onClick={() => fetchNui("admin:setCounter", { id: r.id })}>
                    <MapPin className="h-3.5 w-3.5" /> counter
                  </Button>

                  <select
                    className="h-8 rounded-md border border-input bg-background px-2 text-xs"
                    defaultValue=""
                    onChange={(e) => {
                      const v = e.target.value;
                      act("admin:setOwner", { id: r.id, target: v === "" ? false : Number(v) });
                    }}
                  >
                    <option value="">Set owner…</option>
                    <option value="">(server-owned)</option>
                    {players.map((p: any) => (
                      <option key={p.id} value={p.id}>
                        {p.name} [{p.id}]
                      </option>
                    ))}
                  </select>
                </div>
              </CardContent>
            </Card>
          ))}
        </TabsContent>

        {/* RECIPES */}
        <TabsContent value="recipes">
          <RecipeEditor recipes={recipes} onSaved={refresh} />
        </TabsContent>

        {/* SETTINGS */}
        <TabsContent value="settings">
          <SettingsEditor settings={settings} onSaved={refresh} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}

function RecipeEditor({ recipes, onSaved }: { recipes: any[]; onSaved: () => void }) {
  const blank = {
    input_item: "", station: "fryer", raw_model: "", cooked_model: "", burnt_model: "",
    output_cooked_item: "", output_burnt_item: "", cook_ms: 15000, burn_ms: 15000,
  };
  const [form, setForm] = useState<any>(blank);
  const set = (k: string, v: any) => setForm((f: any) => ({ ...f, [k]: v }));

  return (
    <div className="space-y-3">
      <Card>
        <CardContent className="grid grid-cols-3 gap-2 pt-4">
          {[
            ["input_item", "Input item"],
            ["station", "Station (fryer/stovetop)"],
            ["raw_model", "Raw model (_01)"],
            ["cooked_model", "Cooked model (_02)"],
            ["burnt_model", "Burnt model (_03)"],
            ["output_cooked_item", "Output cooked item"],
            ["output_burnt_item", "Output burnt item"],
            ["cook_ms", "Cook ms"],
            ["burn_ms", "Burn ms"],
          ].map(([k, lbl]) => (
            <div key={k}>
              <label className="mb-1 block text-[11px] text-muted-foreground">{lbl}</label>
              <Input value={form[k]} onChange={(e) => set(k, e.target.value)} />
            </div>
          ))}
          <div className="col-span-3 flex justify-end">
            <Button
              onClick={async () => {
                await fetchNui("admin:saveRecipe", form);
                setForm(blank);
                onSaved();
              }}
            >
              <Plus className="h-4 w-4" /> Save recipe
            </Button>
          </div>
        </CardContent>
      </Card>

      {recipes.map((r) => (
        <Card key={r.input_item}>
          <CardContent className="flex items-center justify-between pt-4 text-sm">
            <div>
              <span className="font-medium">{r.input_item}</span>{" "}
              <Badge variant="secondary">{r.station}</Badge>{" "}
              <span className="text-muted-foreground">
                → {r.output_cooked_item} / {r.output_burnt_item} ({r.cook_ms}/{r.burn_ms}ms)
              </span>
            </div>
            <div className="flex gap-2">
              <Button size="sm" variant="outline" onClick={() => setForm(r)}>Edit</Button>
              <Button size="sm" variant="destructive" onClick={async () => { await fetchNui("admin:deleteRecipe", { input_item: r.input_item }); onSaved(); }}>
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

function SettingsEditor({ settings, onSaved }: { settings: Record<string, any>; onSaved: () => void }) {
  return (
    <div className="space-y-3">
      <p className="flex items-center gap-2 text-xs text-muted-foreground">
        <Boxes className="h-3.5 w-3.5" /> Edit JSON values then save. Affects NPC pacing, drinks, assembly, blips, etc.
      </p>
      {Object.keys(settings).map((key) => (
        <SettingRow key={key} k={key} value={settings[key]} onSaved={onSaved} />
      ))}
    </div>
  );
}

function SettingRow({ k, value, onSaved }: { k: string; value: any; onSaved: () => void }) {
  const [text, setText] = useState(JSON.stringify(value, null, 2));
  const [err, setErr] = useState<string | null>(null);
  return (
    <Card>
      <CardContent className="pt-4">
        <div className="mb-1 flex items-center justify-between">
          <span className="font-mono text-xs font-semibold">{k}</span>
          <Button
            size="sm"
            onClick={async () => {
              try {
                const parsed = JSON.parse(text);
                setErr(null);
                await fetchNui("admin:saveSetting", { key: k, value: parsed });
                onSaved();
              } catch (e: any) {
                setErr("Invalid JSON");
              }
            }}
          >
            Save
          </Button>
        </div>
        <textarea
          className="h-28 w-full rounded-md border border-input bg-background/60 p-2 font-mono text-xs"
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        {err && <p className="mt-1 text-xs text-destructive">{err}</p>}
      </CardContent>
    </Card>
  );
}
