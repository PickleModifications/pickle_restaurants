import * as React from "react";
import { cn } from "@/lib/utils";
import { Input } from "@/components/ui/input";

/** Labelled field wrapper — keeps every control aligned and consistently spaced. */
export function Field({
  label,
  hint,
  className,
  children,
}: {
  label: string;
  hint?: string;
  className?: string;
  children: React.ReactNode;
}) {
  // Intentionally a div (not a <label>): some children are comboboxes built
  // from <button>s, and wrapping those in a <label> hijacks their clicks.
  return (
    <div className={cn("block", className)}>
      <span className="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-[11px] text-muted-foreground">{hint}</span>}
    </div>
  );
}

export function TextField({
  label, hint, value, onChange, placeholder, className,
}: {
  label: string; hint?: string; value: string; onChange: (v: string) => void; placeholder?: string; className?: string;
}) {
  return (
    <Field label={label} hint={hint} className={className}>
      <Input value={value ?? ""} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
    </Field>
  );
}

export function NumberField({
  label, hint, value, onChange, min, step, className,
}: {
  label: string; hint?: string; value: number; onChange: (v: number) => void; min?: number; step?: number; className?: string;
}) {
  return (
    <Field label={label} hint={hint} className={className}>
      <Input
        type="number"
        min={min}
        step={step}
        value={Number.isFinite(value) ? value : 0}
        onChange={(e) => onChange(Number(e.target.value))}
      />
    </Field>
  );
}

/** Small accessible toggle switch. */
export function Toggle({
  checked, onChange, label,
}: {
  checked: boolean; onChange: (v: boolean) => void; label?: string;
}) {
  return (
    <button
      type="button"
      onClick={() => onChange(!checked)}
      className="flex items-center gap-2 text-sm"
    >
      <span
        className={cn(
          "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors",
          checked ? "bg-primary" : "bg-muted"
        )}
      >
        <span
          className={cn(
            "inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform",
            checked ? "translate-x-4" : "translate-x-0.5"
          )}
        />
      </span>
      {label && <span>{label}</span>}
    </button>
  );
}

export function Select({
  label, hint, value, onChange, options, className,
}: {
  label: string; hint?: string; value: string; onChange: (v: string) => void;
  options: { value: string; label: string }[]; className?: string;
}) {
  return (
    <Field label={label} hint={hint} className={className}>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="h-9 w-full rounded-md border border-input bg-background px-2 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </select>
    </Field>
  );
}
