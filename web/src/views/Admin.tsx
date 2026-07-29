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
  const foods = data?.foods || [];
  const tools = data?.tools || [];
  const menuIngredients = data?.ingredients || [];
  const settings = data?.settings || {};
  const players = data?.players || [];
  const items = data?.items || [];
  const groups = data?.groups || []; // every access-group name in use (suggestions)
  const focus = data?.focus; // { restaurant, section } — set after a placement reopen

  // The panel's OWN theme (skins /restaurants itself, distinct from any restaurant's
  // franchise theme). App applies data.theme on open; we keep it in state so the
  // Settings editor previews live AND a restaurant detail can restore it on close.
  const [appTheme, setAppTheme] = useState<ThemeConfig | null>(data?.theme ?? null);

  // The lb-phone companion app's ONE global theme (`phone_theme` setting). Unlike the
  // menu theme it doesn't skin THIS panel — it just previews on a contained swatch in
  // Settings → Appearance and saves through admin:setPhoneTheme.
  const [phoneTheme, setPhoneTheme] = useState<ThemeConfig | null>(data?.phoneTheme ?? null);

  // Whether a single restaurant's detail is open in the Restaurants tab. While it is,
  // hide the top-level admin tab strip — the detail is its own focused view (with a
  // back button), and stacking the admin tabs above it is what got confusing.
  const [restDetail, setRestDetail] = useState(false);

  const refresh = async () => {
    const fresh = await fetchNui<any>("admin:getData");
    if (fresh && fresh.ok) window.postMessage({ action: "setView", view: "admin", data: fresh }, "*");
  };

  return (
    <Panel title={_L("admin.title")} subtitle={_L("admin.subtitle")} onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue="restaurants" className="flex min-h-0 flex-1 flex-col">
        {!restDetail && (
        <TabsList className="shrink-0">
          <TabsTrigger value="restaurants">{_L("admin.tab_restaurants")}</TabsTrigger>
          <TabsTrigger value="food">{_L("admin.tab_food")}</TabsTrigger>
          <TabsTrigger value="ingredients">{_L("admin.tab_ingredients")}</TabsTrigger>
          <TabsTrigger value="settings">{_L("admin.tab_settings")}</TabsTrigger>
        </TabsList>
        )}

        <TabsContent value="restaurants" className="flex min-h-0 flex-1 flex-col">
          <Restaurants restaurants={restaurants} players={players} groups={groups} refresh={refresh} focus={focus} appTheme={appTheme} onDetailChange={setRestDetail} renderTargets={data?.renderTargets} />
        </TabsContent>

        {/* The unified menu is split across two tabs: FOODS (the sellable dishes &
            drinks) and the INGREDIENTS that build them (raw components + the tools
            that apply things — condiments, finishes). Both drive the same Menu
            component, scoped to which kinds it shows/creates. */}
        <TabsContent value="food" className="flex min-h-0 flex-1 flex-col">
          <Menu scope="food" foods={foods} tools={tools} ingredients={menuIngredients} defaults={data?.defaults} settings={settings} boxQuad={data?.boxQuad} items={items} groups={groups} ingredientCosts={data?.ingredientCosts} onSaved={refresh} />
        </TabsContent>

        <TabsContent value="ingredients" className="flex min-h-0 flex-1 flex-col">
          <Menu scope="ingredients" foods={foods} tools={tools} ingredients={menuIngredients} defaults={data?.defaults} settings={settings} boxQuad={data?.boxQuad} items={items} groups={groups} ingredientCosts={data?.ingredientCosts} onSaved={refresh} />
        </TabsContent>

        <TabsContent value="settings" className="flex min-h-0 flex-1 flex-col">
          <Settings settings={settings} items={items} groups={groups} dlcs={data?.dlcs} ingredients={menuIngredients} dlcCosts={data?.dlcCosts} onSaved={refresh} appTheme={appTheme} onAppTheme={setAppTheme} phoneTheme={phoneTheme} onPhoneTheme={setPhoneTheme} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}
