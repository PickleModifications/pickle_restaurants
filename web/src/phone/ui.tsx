import { ReactNode, useEffect, useState } from "react";
import { ChevronLeft, Star, ImageOff, Loader2 } from "lucide-react";
import { cn } from "../lib/utils";
import { usePhone } from "./store";

// ─── screen chrome ───────────────────────────────────────────────────────────
export function TopBar({
  title,
  subtitle,
  onBack,
  right,
  transparent,
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  onBack?: () => void;
  right?: ReactNode;
  transparent?: boolean;
}) {
  return (
    <div
      className={cn(
        "sticky top-0 z-20 flex items-center gap-2 px-4 py-2.5",
        !transparent && "pf-elev border-b border-border bg-card/95"
      )}
    >
      {onBack && (
        <button
          onClick={onBack}
          className="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-muted text-foreground transition-transform active:scale-90"
        >
          <ChevronLeft className="h-5 w-5" />
        </button>
      )}
      <div className="min-w-0 flex-1">
        {title && (
          <div className="truncate font-display text-[1.05rem] font-extrabold leading-tight">
            {title}
          </div>
        )}
        {subtitle && (
          <div className="truncate text-[0.72rem] text-muted-foreground">{subtitle}</div>
        )}
      </div>
      {right}
    </div>
  );
}

export function Screen({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("pf-screen", className)}>{children}</div>;
}

export function Spinner({ label }: { label?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-16 text-muted-foreground">
      <Loader2 className="h-6 w-6 animate-spin" />
      {label && <div className="text-xs">{label}</div>}
    </div>
  );
}

export function Empty({ icon, title, hint }: { icon?: ReactNode; title: string; hint?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-8 py-14 text-center">
      {icon && <div className="mb-1 text-muted-foreground/70">{icon}</div>}
      <div className="font-display text-base font-bold">{title}</div>
      {hint && <div className="text-[0.78rem] text-muted-foreground">{hint}</div>}
    </div>
  );
}

// ─── bits ────────────────────────────────────────────────────────────────────
export function ItemImg({
  src,
  alt,
  className,
}: {
  src?: string;
  alt?: string;
  className?: string;
}) {
  if (!src)
    return (
      <div className={cn("grid place-items-center bg-muted text-muted-foreground/50", className)}>
        <ImageOff className="h-5 w-5" />
      </div>
    );
  return (
    <img
      src={src}
      alt={alt}
      className={cn("object-cover", className)}
      onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
    />
  );
}

export function Stars({
  value,
  size = 14,
  onPick,
}: {
  value: number;
  size?: number;
  onPick?: (n: number) => void;
}) {
  return (
    <div className="flex items-center gap-0.5">
      {[1, 2, 3, 4, 5].map((n) => {
        const filled = value >= n - 0.25;
        return (
          <Star
            key={n}
            onClick={onPick ? () => onPick(n) : undefined}
            className={cn(onPick && "pf-star", filled ? "text-warn" : "text-muted-foreground/40")}
            style={{ width: size, height: size }}
            fill={filled ? "currentColor" : "none"}
          />
        );
      })}
    </div>
  );
}

export function Rating({ value, count }: { value: number; count?: number }) {
  return (
    <span className="inline-flex items-center gap-1 text-[0.74rem] font-semibold">
      <Star className="h-3 w-3 text-warn" fill="currentColor" />
      {value > 0 ? value.toFixed(1) : "New"}
      {count != null && count > 0 && (
        <span className="text-muted-foreground">({count})</span>
      )}
    </span>
  );
}

export function PromoTag({ label }: { label: string }) {
  return (
    <span className="tape rounded-full bg-brand px-2 py-0.5 text-[0.6rem] text-brand-ink">
      {label}
    </span>
  );
}

// The signature loyalty punch-card.
export function PunchCard({ punches, goal }: { punches: number; goal: number }) {
  const done = punches % goal;
  const free = punches >= goal;
  return (
    <div className="pf-punch">
      {Array.from({ length: goal }).map((_, i) => {
        const on = i < (free ? goal : done);
        const isFreeSlot = i === goal - 1;
        return (
          <div
            key={i}
            className={cn("pf-hole", on && "on", isFreeSlot && free && "free")}
            title={isFreeSlot ? "Free item" : `Punch ${i + 1}`}
          >
            {isFreeSlot ? "★" : on ? "" : i + 1}
          </div>
        );
      })}
    </div>
  );
}

// A tappable pill.
export function Pill({
  active,
  children,
  onClick,
}: {
  active?: boolean;
  children: ReactNode;
  onClick?: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "whitespace-nowrap rounded-full border px-3 py-1.5 text-[0.76rem] font-semibold transition-colors active:scale-95",
        active
          ? "border-brand bg-brand text-brand-ink"
          : "border-border bg-card text-foreground"
      )}
    >
      {children}
    </button>
  );
}

export function money2(n: number) {
  return Math.round(n || 0).toLocaleString();
}

// A CEF-safe input modal (bottom sheet), driven by the store's `ask()`. Mounted once
// by the shell; renders only while a prompt is pending. Replaces window.prompt(), which
// FiveM's CEF silently suppresses.
export function AskModal() {
  const { askState, closeAsk } = usePhone();
  const [val, setVal] = useState("");
  useEffect(() => {
    setVal(askState?.initial != null ? String(askState.initial) : "");
  }, [askState]);
  if (!askState) return null;
  const numeric = askState.kind !== "text";
  const submit = () => closeAsk(val.trim() === "" ? null : val.trim());
  return (
    <>
      <div className="pf-scrim" onClick={() => closeAsk(null)} />
      <div className="pf-sheet">
        <div className="pf-grab" />
        <div className="px-4 pt-2" style={{ paddingBottom: "calc(1rem + var(--pf-bottom))" }}>
          <div className="font-display text-lg font-extrabold leading-tight">{askState.title}</div>
          {askState.label && (
            <div className="mb-3 mt-0.5 text-[0.76rem] text-muted-foreground">{askState.label}</div>
          )}
          <div className={cn("mt-3 flex items-center gap-2 rounded-2xl border border-border bg-background px-3", askState.label && "mt-0")}>
            {askState.prefix && (
              <span className="font-mono text-lg font-bold text-muted-foreground">{askState.prefix}</span>
            )}
            <input
              autoFocus
              type={numeric ? "number" : "text"}
              inputMode={numeric ? "numeric" : undefined}
              value={val}
              onChange={(e) => setVal(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") submit();
                if (e.key === "Escape") closeAsk(null);
              }}
              placeholder={askState.placeholder}
              className="w-full bg-transparent py-3 font-mono text-lg font-bold outline-none"
            />
          </div>
          <div className="mt-3 flex gap-2">
            <button
              onClick={() => closeAsk(null)}
              className="flex-1 rounded-full bg-muted py-2.5 text-sm font-bold text-muted-foreground active:scale-[0.99]"
            >
              Cancel
            </button>
            <button
              onClick={submit}
              className="flex-1 rounded-full bg-brand py-2.5 text-sm font-bold text-brand-ink active:scale-[0.99]"
            >
              {askState.confirm || "Confirm"}
            </button>
          </div>
        </div>
      </div>
    </>
  );
}

// A themed toast, mounted once by the shell.
export function Toast() {
  const { toastMsg } = usePhone();
  if (!toastMsg) return null;
  return (
    <div className="pointer-events-none absolute inset-x-0 top-[calc(var(--pf-top)+0.5rem)] z-50 flex justify-center px-4">
      <div
        className={cn(
          "pf-screen rounded-full px-4 py-2 text-[0.8rem] font-semibold shadow-lg",
          toastMsg.tone === "err"
            ? "bg-destructive text-destructive-foreground"
            : "bg-foreground text-background"
        )}
      >
        {toastMsg.msg}
      </div>
    </div>
  );
}
