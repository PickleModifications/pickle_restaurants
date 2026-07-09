import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import { _L } from "@/lib/locale";
import { type ThemeConfig } from "@/lib/theme";
import Panel from "@/components/Panel";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import Restaurants from "@/views/admin/Restaurants";
import Menu from "@/views/admin/Menu";
import Settings from "@/views/admin/Settings";

export default function Admin({ data, onClose }: { data: any; onClose: () => void }) {
  const restaurants = data?.restaurants || [];
  const recipes = data?.recipes || [];
  const assembly = data?.assembly || [];
  const drinks = data?.drinks || [];
  const finishes = data?.finishes || [];
  const settings = data?.settings || {};
  const players = data?.players || [];
  const items = data?.items || [];
  const groups = data?.groups || []; // every access-group name in use (suggestions)
  const focus = data?.focus; // { restaurant, section } — set after a placement reopen

  // The panel's OWN theme (skins /restaurants itself, distinct from any restaurant's
  // franchise theme). App applies data.theme on open; we keep it in state so the
  // Settings editor previews live AND a restaurant detail can restore it on close.
  const [appTheme, setAppTheme] = useState<ThemeConfig | null>(data?.theme ?? null);

  const refresh = async () => {
    const fresh = await fetchNui<any>("admin:getData");
    if (fresh && fresh.ok) window.postMessage({ action: "setView", view: "admin", data: fresh }, "*");
  };

  return (
    <Panel title={_L("admin.title")} subtitle={_L("admin.subtitle")} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue="restaurants" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          <TabsTrigger value="restaurants">{_L("admin.tab_restaurants")}</TabsTrigger>
          <TabsTrigger value="recipes">{_L("admin.tab_recipes")}</TabsTrigger>
          <TabsTrigger value="settings">{_L("admin.tab_settings")}</TabsTrigger>
        </TabsList>

        <TabsContent value="restaurants" className="flex min-h-0 flex-1 flex-col">
          <Restaurants restaurants={restaurants} players={players} groups={groups} refresh={refresh} focus={focus} appTheme={appTheme} />
        </TabsContent>

        <TabsContent value="recipes" className="flex min-h-0 flex-1 flex-col">
          <Menu recipes={recipes} assembly={assembly} drinks={drinks} finishes={finishes} settings={settings} items={items} groups={groups} onSaved={refresh} />
        </TabsContent>

        <TabsContent value="settings" className="flex min-h-0 flex-1 flex-col">
          <Settings settings={settings} items={items} groups={groups} onSaved={refresh} appTheme={appTheme} onAppTheme={setAppTheme} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}
