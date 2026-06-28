import { X } from "lucide-react";
import { Button } from "@/components/ui/button";

/**
 * Fixed-size shell for every management panel. The frame keeps a constant
 * height regardless of how much content a tab holds — content scrolls inside
 * the body, the window never grows or shrinks as you navigate.
 */
export default function Panel({
  title,
  subtitle,
  onClose,
  children,
  headerRight,
  width = "max-w-3xl",
}: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: React.ReactNode;
  headerRight?: React.ReactNode;
  width?: string;
}) {
  return (
    <div className="fixed inset-0 flex items-center justify-center">
      <div className={`animate-fade-in flex h-[86vh] max-h-[760px] min-h-[480px] w-full ${width} flex-col overflow-hidden rounded-xl border border-border bg-card shadow-2xl`}>
        <div className="flex shrink-0 items-center justify-between border-b border-border px-5 py-3">
          <div className="min-w-0">
            <h2 className="truncate text-lg font-semibold">{title}</h2>
            {subtitle && <p className="truncate text-xs text-muted-foreground">{subtitle}</p>}
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {headerRight}
            <Button variant="ghost" size="icon" onClick={onClose}>
              <X className="h-4 w-4" />
            </Button>
          </div>
        </div>
        {/* Flex column so tabbed views can claim flex-1 and scroll internally;
            overflow-y-auto so simpler views (order/register) still scroll. */}
        <div className="flex min-h-0 flex-1 flex-col overflow-y-auto p-5">{children}</div>
      </div>
    </div>
  );
}
