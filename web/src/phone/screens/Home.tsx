import { useMemo, useState } from "react";
import { Search, MapPin, Clock, Repeat, ChevronRight, Store } from "lucide-react";
import { usePhone } from "../store";
import { Screen, ItemImg, Rating, PromoTag, Empty, Pill } from "../ui";
import { cn } from "../../lib/utils";

// A rough ETA so the feed reads like a delivery app, derived from distance.
function eta(dist?: number) {
  if (dist == null) return "—";
  const mins = Math.max(5, Math.round(dist / 60) + 8);
  return `${mins}–${mins + 10} min`;
}

function RestaurantCard({ r, onOpen }: { r: any; onOpen: () => void }) {
  return (
    <button
      onClick={r.open ? onOpen : undefined}
      className={cn(
        "block w-full overflow-hidden rounded-2xl border border-border bg-card text-left active:scale-[0.99]",
        !r.open && "opacity-60"
      )}
    >
      <div className="relative h-32 w-full bg-muted">
        <ItemImg src={r.brand} alt={r.label} className="h-full w-full" />
        <div className="absolute inset-x-0 bottom-0 h-16 bg-gradient-to-t from-black/60 to-transparent" />
        {r.promo && (
          <div className="absolute left-2 top-2">
            <PromoTag label={`${r.promo.percent}% off`} />
          </div>
        )}
        {!r.open && (
          <div className="absolute right-2 top-2 rounded-full bg-black/70 px-2 py-0.5 text-[0.62rem] font-bold text-white">
            Closed
          </div>
        )}
        <div className="absolute bottom-2 left-3 right-3 flex items-end justify-between text-white">
          <span className="font-display text-lg font-extrabold drop-shadow">{r.label}</span>
        </div>
      </div>
      <div className="flex items-center gap-3 px-3 py-2 text-muted-foreground">
        <Rating value={r.rating} count={r.reviews} />
        <span className="inline-flex items-center gap-1 text-[0.72rem]">
          <Clock className="h-3 w-3" /> {eta(r.dist)}
        </span>
        {r.dist != null && (
          <span className="inline-flex items-center gap-1 text-[0.72rem]">
            <MapPin className="h-3 w-3" /> {r.dist < 1000 ? `${r.dist}m` : `${(r.dist / 1000).toFixed(1)}km`}
          </span>
        )}
      </div>
    </button>
  );
}

export default function Home() {
  const { home, go, currency } = usePhone();
  const [q, setQ] = useState("");
  const [onlyOpen, setOnlyOpen] = useState(false);
  const [onlyPromo, setOnlyPromo] = useState(false);

  const restaurants: any[] = home?.restaurants || [];
  const favorites: any[] = home?.favorites || [];

  const filtered = useMemo(() => {
    return restaurants.filter((r) => {
      if (q && !(r.label || "").toLowerCase().includes(q.toLowerCase())) return false;
      if (onlyOpen && !r.open) return false;
      if (onlyPromo && !r.promo) return false;
      return true;
    });
  }, [restaurants, q, onlyOpen, onlyPromo]);

  return (
    <Screen className="pb-24">
      {/* header */}
      <div className="bg-card px-4 pb-3 pt-4">
        <div className="text-[0.72rem] uppercase tracking-wide text-muted-foreground">
          Deliver to · your location
        </div>
        <h1 className="font-display text-2xl font-extrabold leading-tight">
          Hey {home?.name?.split(" ")[0] || "there"} — hungry?
        </h1>
        <div className="mt-3 flex items-center gap-2 rounded-full border border-border bg-background px-3 py-2">
          <Search className="h-4 w-4 text-muted-foreground" />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search restaurants"
            className="w-full bg-transparent text-sm outline-none placeholder:text-muted-foreground"
          />
        </div>
        <div className="mt-2 flex gap-2">
          <Pill active={onlyOpen} onClick={() => setOnlyOpen((v) => !v)}>
            Open now
          </Pill>
          <Pill active={onlyPromo} onClick={() => setOnlyPromo((v) => !v)}>
            Deals
          </Pill>
        </div>
      </div>

      {/* order again */}
      {favorites.length > 0 && (
        <section className="mt-4">
          <div className="mb-2 flex items-center justify-between px-4">
            <h2 className="font-display text-base font-bold">Order again</h2>
            <Repeat className="h-4 w-4 text-muted-foreground" />
          </div>
          <div className="pf-rail px-4">
            {favorites.map((f) => (
              <button
                key={f.id}
                onClick={() => go("restaurant", { rid: f.restaurant_id, reorder: f })}
                className="w-40 shrink-0 rounded-2xl border border-border bg-card p-3 text-left active:scale-95"
              >
                <div className="font-semibold leading-tight">{f.label}</div>
                <div className="mt-0.5 truncate text-[0.72rem] text-muted-foreground">
                  {f.restaurant}
                </div>
                <div className="mt-2 inline-flex items-center gap-1 text-[0.72rem] font-semibold text-primary">
                  Reorder <ChevronRight className="h-3 w-3" />
                </div>
              </button>
            ))}
          </div>
        </section>
      )}

      {/* feed */}
      <section className="mt-4 space-y-3 px-4">
        <h2 className="font-display text-base font-bold">
          {q ? "Results" : "Restaurants near you"}
        </h2>
        {filtered.length === 0 ? (
          <Empty
            icon={<Store className="h-8 w-8" />}
            title="Nothing here yet"
            hint="No restaurants match — try clearing filters."
          />
        ) : (
          filtered.map((r) => (
            <RestaurantCard key={r.id} r={r} onOpen={() => go("restaurant", { rid: r.id })} />
          ))
        )}
      </section>
    </Screen>
  );
}
