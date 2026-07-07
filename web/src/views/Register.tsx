import { useState } from "react";
import { fetchNui } from "@/lib/nui";
import Panel from "@/components/Panel";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { money } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { BellRing, PackagePlus } from "lucide-react";

export default function Register({ data, onClose }: { data: any; onClose: () => void }) {
  const id = data?.restaurantId;
  const orders: any[] = data?.orders || [];
  const stock: any[] = data?.stock || [];
  const inventory: any[] = data?.inventory || [];

  return (
    <Panel
      title={_L("register.title")}
      subtitle={_L("register.subtitle", money(data?.balance), data?.commission ?? 0)}
      onClose={onClose}
      width="max-w-4xl"
    >
      <div className="grid grid-cols-2 gap-4">
        <div>
          <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold"><BellRing className="h-4 w-4 text-primary" /> {_L("register.customer_orders")}</h3>
          {orders.length === 0 && <div className="text-xs text-muted-foreground">{_L("register.no_customers")}</div>}
          <div className="space-y-2">
            {orders.map((o) => (
              <Card key={o.orderId}>
                <CardContent className="flex items-center justify-between pt-4 text-sm">
                  <div>
                    <div className="font-medium">{_L("register.wants", o.name, o.label)}</div>
                    <div className="text-xs text-muted-foreground">{money(o.price)}</div>
                  </div>
                  <Button size="sm" onClick={() => fetchNui("sales:serve", { id, orderId: o.orderId })}>{_L("register.serve")}</Button>
                </CardContent>
              </Card>
            ))}
          </div>

          <h3 className="mb-2 mt-4 text-sm font-semibold">{_L("register.counter_stock")}</h3>
          <div className="rounded-lg border border-border p-2">
            {stock.length === 0 && <div className="text-xs text-muted-foreground">{_L("register.stock_empty")}</div>}
            {stock.map((s) => (
              <div key={s.item} className="flex items-center justify-between py-1 text-sm">
                <span>{s.label}</span>
                <Badge variant="secondary">{s.count}</Badge>
              </div>
            ))}
          </div>
        </div>

        <div>
          <h3 className="mb-2 flex items-center gap-2 text-sm font-semibold"><PackagePlus className="h-4 w-4 text-primary" /> {_L("register.stock_from_inventory")}</h3>
          <div className="space-y-2">
            {inventory.length === 0 && <div className="text-xs text-muted-foreground">{_L("register.inventory_empty")}</div>}
            {inventory.map((it) => (
              <StockRow key={it.name} id={id} item={it} />
            ))}
          </div>
        </div>
      </div>
    </Panel>
  );
}

function StockRow({ id, item }: { id: number; item: any }) {
  const [qty, setQty] = useState(1);
  return (
    <Card>
      <CardContent className="flex items-center justify-between gap-2 pt-4 text-sm">
        <div>
          <span className="font-medium">{item.label || item.name}</span>{" "}
          <Badge variant="secondary">{item.count}</Badge>
        </div>
        <div className="flex items-center gap-2">
          <Input type="number" min={1} max={item.count} value={qty} onChange={(e) => setQty(Number(e.target.value))} className="h-8 w-16" />
          <Button size="sm" onClick={() => fetchNui("sales:stock", { id, item: item.name, count: qty })}>{_L("register.stock")}</Button>
        </div>
      </CardContent>
    </Card>
  );
}
