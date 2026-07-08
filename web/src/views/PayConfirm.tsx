import { useEffect, useRef, useState } from "react";
import { fetchNui } from "@/lib/nui";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { money } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Receipt, Check, X } from "lucide-react";

type LineMod = { label: string; added?: boolean; removed?: boolean };
type Line = { label: string; qty: number; price: number; mods?: LineMod[] };

// The customer-facing charge prompt. The server awaits our answer; a 30s
// countdown auto-declines so the cashier's register can never hang. Answering
// once is enough — `answered` guards the double-fire when the countdown and a
// button race.
export default function PayConfirm({ data }: { data: any }) {
  const total: number = data?.total ?? 0;
  const lines: Line[] = data?.lines || [];
  const [left, setLeft] = useState(30);
  const answered = useRef(false);

  const answer = (accept: boolean) => {
    if (answered.current) return;
    answered.current = true;
    fetchNui("sales:payChoice", { accept });
  };

  useEffect(() => {
    const t = window.setInterval(() => {
      setLeft((s) => {
        if (s <= 1) { answer(false); return 0; }
        return s - 1;
      });
    }, 1000);
    return () => window.clearInterval(t);
  }, []);

  return (
    <div className="fixed inset-0 flex items-center justify-center">
      <div className="animate-fade-in w-full max-w-sm overflow-hidden rounded-xl border border-border bg-card shadow-2xl">
        <div className="flex items-center gap-2 border-b border-border px-4 py-3">
          <Receipt className="h-4 w-4 text-primary" />
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold">{_L("payconfirm.title", data?.restaurant || "")}</h2>
            {data?.cashier && <p className="truncate text-xs text-muted-foreground">{_L("payconfirm.from", data.cashier)}</p>}
          </div>
        </div>

        <div className="space-y-1.5 px-4 py-3">
          {lines.map((l, i) => (
            <div key={i} className="flex items-start justify-between text-sm">
              <span className="min-w-0 text-muted-foreground">
                {l.qty}× {l.label}
                {l.mods && l.mods.length > 0 && (
                  <span className="ml-1 text-xs text-muted-foreground/70">
                    ({l.mods.map((m) => (m.removed ? "no " + m.label : "+" + m.label)).join(", ")})
                  </span>
                )}
              </span>
              <span className="shrink-0">{money(l.price * l.qty)}</span>
            </div>
          ))}
          <div className="mt-2 flex items-center justify-between border-t border-border pt-2 text-sm font-semibold">
            <span>{_L("payconfirm.total")}</span>
            <span>{money(total)}</span>
          </div>
        </div>

        <div className="flex items-center gap-2 border-t border-border px-4 py-3">
          <Badge variant="outline" className="tabular-nums">{_L("payconfirm.expires", left)}</Badge>
          <div className="ml-auto flex gap-2">
            <Button size="sm" variant="ghost" onClick={() => answer(false)}><X className="h-4 w-4" /> {_L("payconfirm.decline")}</Button>
            <Button size="sm" onClick={() => answer(true)}><Check className="h-4 w-4" /> {_L("payconfirm.accept", money(total))}</Button>
          </div>
        </div>
      </div>
    </div>
  );
}
