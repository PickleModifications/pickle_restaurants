import { useEffect, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { _L } from "@/lib/locale";
import { Check, ChevronsUpDown, Search, TriangleAlert } from "lucide-react";

export type Item = { name: string; label: string; image?: string };

/**
 * Searchable item selector. Instead of typing a raw codename, the user picks
 * from the server's live item catalogue. If `value` is set to something that
 * isn't in the catalogue the control renders in an error state so it's obvious
 * what needs fixing.
 */
export default function ItemPicker({
  items,
  value,
  onChange,
  placeholder = _L("itempicker.select_placeholder"),
  className,
  allowEmpty = false,
}: {
  items: Item[];
  value: string;
  onChange: (name: string) => void;
  placeholder?: string;
  className?: string;
  allowEmpty?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const selected = useMemo(() => items.find((i) => i.name === value), [items, value]);
  const missing = !!value && !selected;

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const list = q
      ? items.filter((i) => i.label.toLowerCase().includes(q) || i.name.toLowerCase().includes(q))
      : items;
    return list.slice(0, 80);
  }, [items, query]);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("mousedown", onDown);
    inputRef.current?.focus();
    return () => window.removeEventListener("mousedown", onDown);
  }, [open]);

  return (
    <div ref={rootRef} className={cn("relative", className)}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={cn(
          "flex h-9 w-full items-center justify-between gap-2 rounded-md border bg-background/60 px-3 text-left text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring",
          missing ? "border-destructive text-destructive" : "border-input"
        )}
      >
        <span className="flex min-w-0 items-center gap-1.5 truncate">
          {missing && <TriangleAlert className="h-3.5 w-3.5 shrink-0" />}
          {selected ? (
            <span className="truncate">{selected.label}</span>
          ) : value ? (
            <span className="truncate font-mono text-xs">{value}</span>
          ) : (
            <span className="text-muted-foreground">{placeholder}</span>
          )}
        </span>
        <ChevronsUpDown className="h-3.5 w-3.5 shrink-0 opacity-50" />
      </button>

      {open && (
        <div className="absolute z-50 mt-1 w-full overflow-hidden rounded-md border border-border bg-card shadow-xl">
          <div className="flex items-center gap-2 border-b border-border px-2.5">
            <Search className="h-3.5 w-3.5 text-muted-foreground" />
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={_L("itempicker.search_placeholder")}
              className="h-9 w-full bg-transparent text-sm outline-none placeholder:text-muted-foreground"
            />
          </div>
          <div className="max-h-56 overflow-y-auto py-1">
            {allowEmpty && (
              <Option
                label={_L("itempicker.none")}
                sub=""
                active={!value}
                onClick={() => { onChange(""); setOpen(false); setQuery(""); }}
              />
            )}
            {filtered.length === 0 && (
              <div className="px-3 py-3 text-center text-xs text-muted-foreground">{_L("itempicker.no_match", query)}</div>
            )}
            {filtered.map((i) => (
              <Option
                key={i.name}
                label={i.label}
                sub={i.name}
                active={i.name === value}
                onClick={() => { onChange(i.name); setOpen(false); setQuery(""); }}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function Option({ label, sub, active, onClick }: { label: string; sub: string; active: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left text-sm hover:bg-accent",
        active && "bg-accent/60"
      )}
    >
      <span className="flex min-w-0 flex-col">
        <span className="truncate">{label}</span>
        {sub && <span className="truncate font-mono text-[10px] text-muted-foreground">{sub}</span>}
      </span>
      {active && <Check className="h-3.5 w-3.5 shrink-0 text-primary" />}
    </button>
  );
}
