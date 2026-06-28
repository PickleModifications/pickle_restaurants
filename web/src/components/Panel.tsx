import { X } from "lucide-react";
import { Button } from "@/components/ui/button";

export default function Panel({
  title,
  subtitle,
  onClose,
  children,
  width = "max-w-3xl",
}: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: React.ReactNode;
  width?: string;
}) {
  return (
    <div className="fixed inset-0 flex items-center justify-center">
      <div className={`animate-fade-in flex max-h-[86vh] w-full ${width} flex-col overflow-hidden rounded-xl border border-border bg-card shadow-2xl`}>
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <div>
            <h2 className="text-lg font-semibold">{title}</h2>
            {subtitle && <p className="text-xs text-muted-foreground">{subtitle}</p>}
          </div>
          <Button variant="ghost" size="icon" onClick={onClose}>
            <X className="h-4 w-4" />
          </Button>
        </div>
        <div className="flex-1 overflow-y-auto p-5">{children}</div>
      </div>
    </div>
  );
}
