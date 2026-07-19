import { useEffect, useState } from "react";
import {
  Trophy,
  CalendarClock,
  ChevronRight,
  Award,
  Lock,
  DoorOpen,
  X,
  Medal,
  Briefcase,
} from "lucide-react";
import { fetchNui } from "../../lib/nui";
import { cn } from "../../lib/utils";
import { _L } from "../../lib/locale";
import { usePhone, money } from "../store";
import { Screen, TopBar, PunchCard, Empty, Spinner } from "../ui";

// ─── rewards hub ──────────────────────────────────────────────────────────────
export function Rewards() {
  const { home, go } = usePhone();
  const loyalty: any[] = home?.loyalty || [];
  const achievements: any[] = home?.achievements || [];
  const unlocked = achievements.filter((a) => a.unlocked).length;

  return (
    <Screen className="pb-20">
      <TopBar title={_L("phone.rewards.title")} />
      <div className="space-y-4 p-4">
        <div className="grid grid-cols-2 gap-2">
          <button
            onClick={() => go("reserve")}
            className="flex flex-col items-start gap-1 rounded-2xl border border-border bg-card p-3 text-left active:scale-[0.98]"
          >
            <CalendarClock className="h-5 w-5 text-primary" />
            <div className="font-semibold">{_L("phone.reserve.title")}</div>
            <div className="text-[0.7rem] text-muted-foreground">{_L("phone.rewards.reserve_hint")}</div>
          </button>
          <button
            onClick={() => go("leaderboard")}
            className="flex flex-col items-start gap-1 rounded-2xl border border-border bg-card p-3 text-left active:scale-[0.98]"
          >
            <Trophy className="h-5 w-5 text-warn" />
            <div className="font-semibold">{_L("phone.leaderboard.title")}</div>
            <div className="text-[0.7rem] text-muted-foreground">{_L("phone.rewards.leaderboard_hint")}</div>
          </button>
        </div>

        {/* punch cards */}
        <section>
          <h2 className="mb-2 font-display text-base font-bold">{_L("phone.rewards.punch_cards")}</h2>
          {loyalty.length === 0 ? (
            <Empty title={_L("phone.rewards.no_cards")} hint={_L("phone.rewards.no_cards_hint")} />
          ) : (
            <div className="space-y-3">
              {loyalty.map((l) => (
                <div key={l.id} className="rounded-2xl border border-border bg-card p-3">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="font-semibold">{l.label}</span>
                    <span className="text-[0.72rem] text-muted-foreground">
                      {l.punches % l.goal}/{l.goal}
                      {l.punches >= l.goal && (
                        <span className="ml-1 font-bold text-warn">{_L("phone.rewards.free_ready")}</span>
                      )}
                    </span>
                  </div>
                  <PunchCard punches={l.punches} goal={l.goal} />
                </div>
              ))}
            </div>
          )}
        </section>

        {/* achievements */}
        <section>
          <div className="mb-2 flex items-center justify-between">
            <h2 className="font-display text-base font-bold">{_L("phone.rewards.achievements")}</h2>
            <span className="text-[0.72rem] text-muted-foreground">
              {unlocked}/{achievements.length}
            </span>
          </div>
          <div className="space-y-2">
            {achievements.map((a) => (
              <div
                key={a.key}
                className={cn(
                  "flex items-center gap-3 rounded-2xl border p-3",
                  a.unlocked ? "border-brand/40 bg-brand/5" : "border-border bg-card"
                )}
              >
                <span
                  className={cn(
                    "grid h-10 w-10 place-items-center rounded-full",
                    a.unlocked ? "bg-brand text-brand-ink" : "bg-muted text-muted-foreground"
                  )}
                >
                  {a.unlocked ? <Award className="h-5 w-5" /> : <Lock className="h-4 w-4" />}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="font-semibold leading-tight">{a.label}</div>
                  <div className="text-[0.7rem] text-muted-foreground">{a.desc}</div>
                  <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-muted">
                    <div
                      className="h-full rounded-full bg-brand"
                      style={{ width: `${Math.min(100, (a.progress / a.goal) * 100)}%` }}
                    />
                  </div>
                </div>
                <span className="font-mono text-[0.72rem] text-muted-foreground">
                  {a.progress}/{a.goal}
                </span>
              </div>
            ))}
          </div>
        </section>
      </div>
    </Screen>
  );
}

// ─── reservations ─────────────────────────────────────────────────────────────
// The slot ID is what the server stores, so it must stay stable; only its DISPLAY
// is localized (the clock times read the same in any language).
const SLOTS = ["Now", "6:00 PM", "7:00 PM", "8:00 PM", "9:00 PM"];
const slotLabel = (s?: string) => (!s || s === "Now" ? _L("phone.reserve.slot_now") : s);

export function Reserve(_props: { params?: any }) {
  const { home, back, toast } = usePhone();
  const restaurants: any[] = home?.restaurants || [];
  const [rid, setRid] = useState<number | null>(restaurants[0]?.id ?? null);
  const [party, setParty] = useState(2);
  const [slot, setSlot] = useState(SLOTS[0]);
  const [mine, setMine] = useState<any[]>([]);
  const [avail, setAvail] = useState<any>(null);
  const [busy, setBusy] = useState(false);

  const load = () => fetchNui("phone:myReservations", {}).then((d) => d?.ok && setMine(d.reservations || []));
  const loadAvail = (r: number | null) => {
    setAvail(null);
    if (r != null) fetchNui("phone:reserveAvailability", { id: r }).then((d) => d?.ok && setAvail(d));
  };
  useEffect(() => {
    load();
  }, []);
  useEffect(() => {
    loadAvail(rid);
  }, [rid]);

  // Seats left in a slot, given capacity − already-booked parties.
  const capacity: number = avail?.capacity ?? 0;
  const remaining = (s: string) => capacity - (avail?.usage?.[s] || 0);
  const slotFull = (s: string) => avail != null && remaining(s) < party;
  const alreadyBooked = !!avail?.hasReservation;
  // A restaurant with no seat anchors placed can't take reservations at all.
  const noSeats = avail != null && capacity <= 0;

  const book = async () => {
    if (!rid) return;
    setBusy(true);
    const res = await fetchNui("phone:reserve", { id: rid, party, slot });
    setBusy(false);
    if (res?.ok) {
      toast(_L("phone.reserve.booked"));
      load();
      loadAvail(rid);
    } else toast(res?.error || _L("phone.reserve.book_failed"), "err");
  };

  const enter = async (r: any) => {
    const res = await fetchNui("phone:enterBooth", { id: r.id, rid: r.restaurant_id });
    if (!res?.ok) toast(res?.error || _L("phone.reserve.enter_failed"), "err");
  };
  const cancel = async (r: any) => {
    await fetchNui("phone:cancelReservation", { id: r.id });
    load();
    loadAvail(rid);
  };

  return (
    <Screen className="pb-8">
      <TopBar title={_L("phone.reserve.title")} onBack={back} />
      <div className="space-y-4 p-4">
        <div>
          <div className="tape mb-1.5 text-muted-foreground">{_L("phone.reserve.restaurant")}</div>
          <div className="pf-rail">
            {restaurants.map((r) => (
              <button
                key={r.id}
                onClick={() => setRid(r.id)}
                className={cn(
                  "rounded-full border px-3 py-1.5 text-sm font-semibold",
                  rid === r.id ? "border-brand bg-brand text-brand-ink" : "border-border bg-card"
                )}
              >
                {r.label}
              </button>
            ))}
          </div>
        </div>

        <div>
          <div className="tape mb-1.5 text-muted-foreground">{_L("phone.reserve.party_size")}</div>
          <div className="flex items-center gap-3">
            <button onClick={() => setParty((p) => Math.max(1, p - 1))} className="grid h-9 w-9 place-items-center rounded-full bg-muted">
              −
            </button>
            <span className="w-8 text-center font-mono text-lg font-bold">{party}</span>
            <button onClick={() => setParty((p) => Math.min(12, p + 1))} className="grid h-9 w-9 place-items-center rounded-full bg-muted">
              +
            </button>
          </div>
        </div>

        <div>
          <div className="mb-1.5 flex items-center justify-between">
            <span className="tape text-muted-foreground">{_L("phone.reserve.time")}</span>
            {avail && !noSeats && (
              <span className="text-[0.66rem] text-muted-foreground">
                {capacity === 1
                  ? _L("phone.reserve.seat_one", capacity)
                  : _L("phone.reserve.seat_many", capacity)}
              </span>
            )}
          </div>
          {noSeats ? (
            <p className="rounded-xl border border-border bg-card px-3 py-2 text-[0.74rem] text-muted-foreground">
              {_L("phone.reserve.no_seats")}
            </p>
          ) : (
          <div className="pf-rail">
            {SLOTS.map((s) => {
              const full = slotFull(s);
              return (
                <button
                  key={s}
                  disabled={full}
                  onClick={() => setSlot(s)}
                  className={cn(
                    "flex flex-col items-center rounded-2xl border px-3 py-1.5 text-sm font-semibold",
                    slot === s ? "border-brand bg-brand text-brand-ink" : "border-border bg-card",
                    full && "opacity-40"
                  )}
                >
                  {slotLabel(s)}
                  {avail && (
                    <span className={cn("text-[0.6rem] font-medium", slot === s ? "text-brand-ink/80" : "text-muted-foreground")}>
                      {full ? _L("phone.reserve.full") : _L("phone.reserve.left", remaining(s))}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
          )}
        </div>

        {alreadyBooked && (
          <p className="rounded-xl border border-border bg-card px-3 py-2 text-[0.74rem] text-muted-foreground">
            {_L("phone.reserve.already_booked_note")}
          </p>
        )}

        <button
          disabled={busy || !rid || alreadyBooked || noSeats || slotFull(slot)}
          onClick={book}
          className="w-full rounded-full bg-brand px-4 py-3 font-bold text-brand-ink disabled:opacity-60"
        >
          {busy
            ? _L("phone.reserve.booking")
            : noSeats
            ? _L("phone.reserve.btn_no_seats")
            : alreadyBooked
            ? _L("phone.reserve.btn_booked")
            : slotFull(slot)
            ? _L("phone.reserve.btn_full")
            : _L("phone.reserve.btn_book")}
        </button>

        {mine.length > 0 && (
          <section>
            <h2 className="mb-2 font-display text-base font-bold">{_L("phone.reserve.mine")}</h2>
            <div className="space-y-2">
              {mine.map((r) => (
                <div key={r.id} className="flex items-center gap-3 rounded-2xl border border-border bg-card p-3">
                  <div className="min-w-0 flex-1">
                    <div className="font-semibold">{r.restaurant}</div>
                    <div className="text-[0.72rem] text-muted-foreground">
                      {_L("phone.reserve.party_of", r.party)} · {slotLabel(r.slot)}
                    </div>
                  </div>
                  <button onClick={() => enter(r)} className="flex items-center gap-1 rounded-full bg-brand px-3 py-1.5 text-sm font-bold text-brand-ink">
                    <DoorOpen className="h-4 w-4" /> {_L("phone.reserve.enter")}
                  </button>
                  <button onClick={() => cancel(r)} className="grid h-8 w-8 place-items-center rounded-full bg-muted">
                    <X className="h-4 w-4" />
                  </button>
                </div>
              ))}
            </div>
            <p className="mt-2 text-[0.68rem] text-muted-foreground">
              {_L("phone.reserve.booth_hint")}
            </p>
          </section>
        )}
      </div>
    </Screen>
  );
}

// ─── leaderboard ──────────────────────────────────────────────────────────────
export function Leaderboard({ params }: { params?: any }) {
  const { home, back, currency } = usePhone();
  const employment: any[] = home?.employment || [];
  const [scope, setScope] = useState<number | null>(params?.rid ?? null);
  const [rows, setRows] = useState<any[] | null>(null);

  useEffect(() => {
    setRows(null);
    fetchNui("phone:leaderboard", { id: scope }).then((d) => setRows(d?.leaderboard || []));
  }, [scope]);

  return (
    <Screen className="pb-8">
      <TopBar title={_L("phone.leaderboard.title")} onBack={back} />
      <div className="flex gap-2 px-4 pb-2">
        <button
          onClick={() => setScope(null)}
          className={cn("rounded-full px-3 py-1.5 text-sm font-semibold", scope == null ? "bg-brand text-brand-ink" : "bg-muted text-muted-foreground")}
        >
          {_L("phone.leaderboard.server_wide")}
        </button>
        {employment.map((e) => (
          <button
            key={e.id}
            onClick={() => setScope(e.id)}
            className={cn("rounded-full px-3 py-1.5 text-sm font-semibold", scope === e.id ? "bg-brand text-brand-ink" : "bg-muted text-muted-foreground")}
          >
            {e.label}
          </button>
        ))}
      </div>

      {rows == null ? (
        <Spinner />
      ) : rows.length === 0 ? (
        <Empty
          icon={<Medal className="h-8 w-8" />}
          title={_L("phone.leaderboard.empty")}
          hint={_L("phone.leaderboard.empty_hint")}
        />
      ) : (
        <div className="space-y-1.5 px-4">
          {rows.map((r, i) => (
            <div
              key={i}
              className={cn(
                "flex items-center gap-3 rounded-2xl border p-3",
                r.me ? "border-brand bg-brand/10" : "border-border bg-card"
              )}
            >
              <span
                className={cn(
                  "grid h-8 w-8 place-items-center rounded-full font-mono font-bold",
                  i === 0 ? "bg-warn text-black" : i === 1 ? "bg-muted-foreground/30" : i === 2 ? "bg-brand/40" : "bg-muted text-muted-foreground"
                )}
              >
                {i + 1}
              </span>
              <div className="min-w-0 flex-1">
                <div className="truncate font-semibold">
                  {r.name}{" "}
                  {r.me && <span className="text-[0.68rem] text-primary">{_L("phone.leaderboard.you")}</span>}
                </div>
                <div className="text-[0.72rem] text-muted-foreground">
                  {_L("phone.leaderboard.earned", money(currency, r.revenue))}
                </div>
              </div>
              <div className="text-right">
                <div className="font-mono font-bold">{r.cooked}</div>
                <div className="text-[0.62rem] text-muted-foreground">{_L("phone.leaderboard.cooked")}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Screen>
  );
}

// ─── profile ──────────────────────────────────────────────────────────────────
export function Profile() {
  const { home, go } = usePhone();
  const employment: any[] = home?.employment || [];
  const orders: any[] = home?.orders || [];
  const achievements: any[] = home?.achievements || [];
  const totalPunches = (home?.loyalty || []).reduce((n: number, l: any) => n + (l.punches || 0), 0);

  return (
    <Screen className="pb-20">
      <TopBar title={_L("phone.profile.title")} />
      <div className="space-y-4 p-4">
        <div className="flex items-center gap-3 rounded-2xl border border-border bg-card p-4">
          <span className="grid h-14 w-14 place-items-center rounded-full bg-brand font-display text-xl font-extrabold text-brand-ink">
            {(home?.name || "?").charAt(0)}
          </span>
          <div>
            <div className="font-display text-lg font-extrabold">{home?.name || _L("phone.guest")}</div>
            <div className="text-[0.72rem] text-muted-foreground">{_L("phone.profile.member")}</div>
          </div>
        </div>

        <div className="grid grid-cols-3 gap-2 text-center">
          <Stat label={_L("phone.profile.stat_orders")} value={orders.length} />
          <Stat label={_L("phone.profile.stat_punches")} value={totalPunches} />
          <Stat
            label={_L("phone.profile.stat_badges")}
            value={achievements.filter((a) => a.unlocked).length}
          />
        </div>

        {employment.length > 0 && (
          <section>
            <h2 className="mb-2 font-display text-base font-bold">{_L("phone.profile.where_you_work")}</h2>
            <div className="space-y-2">
              {employment.map((e) => (
                <button
                  key={e.id}
                  onClick={() => go("staff", { rid: e.id })}
                  className="flex w-full items-center gap-3 rounded-2xl border border-border bg-card p-3 text-left active:scale-[0.99]"
                >
                  <Briefcase className="h-5 w-5 text-primary" />
                  <div className="flex-1">
                    <div className="font-semibold">{e.label}</div>
                    <div className="text-[0.7rem] text-muted-foreground">
                      {e.isOwner ? _L("phone.profile.owner") : _L("phone.profile.staff")}
                      {e.clockedIn && <span className="ml-1 text-ok">{_L("phone.profile.on_shift")}</span>}
                    </div>
                  </div>
                  <ChevronRight className="h-5 w-5 text-muted-foreground" />
                </button>
              ))}
            </div>
          </section>
        )}
      </div>
    </Screen>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-2xl border border-border bg-card p-3">
      <div className="font-mono text-xl font-bold">{value}</div>
      <div className="text-[0.66rem] uppercase tracking-wide text-muted-foreground">{label}</div>
    </div>
  );
}
