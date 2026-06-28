import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { money } from "@/lib/utils";
import { ShoppingCart } from "lucide-react";

export default function Order({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const menu: any[] = data?.menu || [];

  return (
    <Panel title={data?.label || "Order"} subtitle="Order from the menu" onClose={onClose} width="max-w-2xl">
      {menu.length === 0 && <p className="text-sm text-muted-foreground">Nothing on the menu yet.</p>}
      <div className="grid grid-cols-2 gap-3">
        {menu.map((m) => {
          const out = (m.stock ?? 0) < 1;
          return (
            <Card key={m.item}>
              <CardContent className="flex items-center justify-between pt-4">
                <div>
                  <div className="font-medium">{m.label}</div>
                  <div className="text-xs text-muted-foreground">
                    {money(m.price)} · {out ? <span className="text-destructive">out of stock</span> : `${m.stock} available`}
                  </div>
                </div>
                <Button size="sm" disabled={out} onClick={() => fetchNui("sales:buy", { id, item: m.item })}>
                  <ShoppingCart className="h-4 w-4" /> Buy
                </Button>
              </CardContent>
            </Card>
          );
        })}
      </div>
      <div className="mt-3 flex justify-end">
        <Badge variant="outline">Tip: staff cook & stock these from the kitchen</Badge>
      </div>
    </Panel>
  );
}
