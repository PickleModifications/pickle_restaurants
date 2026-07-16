import { useEffect, useState } from "react";
import { useNuiEvent } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { money } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { ShoppingCart, ClipboardList } from "lucide-react";
import { OrderBuilder, arr, type Cat, type Combo, type Near, type Ticket } from "@/components/OrderBuilder";
import { Tickets } from "@/components/RegisterTickets";

export default function Register({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  // Catalog + nearby come from the initial open payload (they don't churn while
  // the panel is up).
  const catalog: Cat[] = arr<Cat>(data?.catalog);
  const combos: Combo[] = arr<Combo>(data?.combos);
  const nearby: Near[] = arr<Near>(data?.nearby);

  // The ticket list is LIVE: seeded from the open payload, then kept in sync by
  // the server's `orders` broadcast (fired on any create/cancel/complete, from
  // any cashier). This is the only thing that mutates while the panel is open, so
  // updating just this state — never the whole panel — is flicker-free and can't
  // race a full re-render. Re-seed if the panel is reopened with fresh `data`.
  const [tickets, setTickets] = useState<Ticket[]>(() => arr<Ticket>(data?.tickets));
  useEffect(() => { setTickets(arr<Ticket>(data?.tickets)); }, [data]);
  useNuiEvent("orders", (d) => setTickets(arr<Ticket>(d?.orders)));

  return (
    <Panel
      title={_L("register.title")}
      subtitle={_L("register.subtitle_pos", data?.label || "", money(data?.balance), data?.commission ?? 0)}
      onClose={onClose}
      width="max-w-4xl"
    >
      <Tabs defaultValue="new" className="flex min-h-0 flex-1 flex-col">
        <TabsList className="shrink-0">
          <TabsTrigger value="new"><ShoppingCart className="h-4 w-4" /> {_L("register.new_order")}</TabsTrigger>
          <TabsTrigger value="tickets"><ClipboardList className="h-4 w-4" /> {_L("register.tickets", tickets.length)}</TabsTrigger>
        </TabsList>

        <TabsContent value="new" className="min-h-0 flex-1">
          <OrderBuilder id={id} catalog={catalog} combos={combos} nearby={nearby} mode="register" />
        </TabsContent>

        {/* not overflow-scrolled here — Tickets owns its own scroll so the meal
            picker can overlay (and dim) just the ticket area, not the whole panel */}
        <TabsContent value="tickets" className="min-h-0 flex-1">
          <Tickets id={id} tickets={tickets} />
        </TabsContent>
      </Tabs>
    </Panel>
  );
}
