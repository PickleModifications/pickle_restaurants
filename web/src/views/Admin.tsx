import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import Restaurants from "@/views/admin/Restaurants";
import Recipes from "@/views/admin/Recipes";
import Settings from "@/views/admin/Settings";

export default function Admin({ data, onClose }: { data: any; onClose: () => void }) {
  const restaurants = data?.restaurants || [];
  const recipes = data?.recipes || [];
  const settings = data?.settings || {};
  const players = data?.players || [];
  const items = data?.items || [];

  const refresh = async () => {
    const fresh = await fetchNui<any>("admin:getData");
    if (fresh && fresh.ok) window.postMessage({ action: "setView", view: "admin", data: fresh }, "*");
  };

  return (
    <Panel title="Restaurant Administration" subtitle="Server-wide management" onClose={onClose} width="max-w-4xl">
      <Tabs defaultValue="restaurants" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          <TabsTrigger value="restaurants">Restaurants</TabsTrigger>
          <TabsTrigger value="recipes">Recipes</TabsTrigger>
          <TabsTrigger value="settings">Settings</TabsTrigger>
        </TabsList>

        <TabsContent value="restaurants" className="flex min-h-0 flex-1 flex-col">
          <Restaurants restaurants={restaurants} players={players} refresh={refresh} />
        </TabsContent>

        <TabsContent value="recipes" className="flex min-h-0 flex-1 flex-col">
          <Recipes recipes={recipes} items={items} onSaved={refresh} />
        </TabsContent>

        <TabsContent value="settings" className="flex min-h-0 flex-1 flex-col">
          <Settings settings={settings} items={items} onSaved={refresh} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}
