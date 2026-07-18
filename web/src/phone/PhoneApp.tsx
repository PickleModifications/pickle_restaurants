import { useEffect } from "react";
import { Home as HomeIcon, ClipboardList, Award, ChefHat, User, ShoppingBag } from "lucide-react";
import { cn } from "../lib/utils";
import { PhoneProvider, usePhone, money, Tab } from "./store";
import { Spinner, Toast, AskModal } from "./ui";
import { fetchNui, useNuiEvent } from "../lib/nui";

import Home from "./screens/Home";
import { Restaurant, Checkout } from "./screens/Restaurant";
import { Orders, OrderTrack } from "./screens/Orders";
import { Rewards, Reserve, Leaderboard, Profile } from "./screens/Rewards";
import { Kitchen, Manage, Staff } from "./screens/Work";

function Router() {
  const { stack } = usePhone();
  const top = stack[stack.length - 1];
  switch (top.name) {
    case "home":
      return <Home />;
    case "restaurant":
      return <Restaurant params={top.params} />;
    case "checkout":
      return <Checkout params={top.params} />;
    case "orders":
      return <Orders />;
    case "order":
      return <OrderTrack params={top.params} />;
    case "rewards":
      return <Rewards />;
    case "reserve":
      return <Reserve params={top.params} />;
    case "leaderboard":
      return <Leaderboard params={top.params} />;
    case "profile":
      return <Profile />;
    case "kitchen":
      return <Kitchen params={top.params} />;
    case "manage":
      return <Manage params={top.params} />;
    case "staff":
      return <Staff params={top.params} />;
    default:
      return <Home />;
  }
}

function CartBar() {
  const { cart, cartCount, cartSubtotal, currency, go, stack } = usePhone();
  const top = stack[stack.length - 1].name;
  // Only show the floating cart on the storefront/menu screen.
  if (!cart || cartCount === 0 || (top !== "restaurant" && top !== "home")) return null;
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-0 z-30 p-3">
      <button
        onClick={() => go("checkout", { rid: cart.rid })}
        className="pf-elev-lg pointer-events-auto flex w-full items-center justify-between gap-2 rounded-2xl bg-brand px-4 py-3.5 text-brand-ink transition-transform active:scale-[0.98]"
      >
        <span className="flex items-center gap-2.5 font-bold">
          <span className="grid h-6 min-w-6 place-items-center rounded-full bg-brand-ink/20 px-1.5 font-mono text-sm tabular-nums">
            {cartCount}
          </span>
          View cart
        </span>
        <span className="font-mono font-bold tabular-nums">{money(currency, cartSubtotal)}</span>
      </button>
    </div>
  );
}

function TabBar() {
  const { tab, setTab, home } = usePhone();
  const employed = (home?.employment?.length || 0) > 0;
  const tabs: { id: Tab; label: string; icon: any }[] = [
    { id: "home", label: "Order", icon: HomeIcon },
    { id: "orders", label: "Orders", icon: ClipboardList },
    { id: "rewards", label: "Rewards", icon: Award },
    ...(employed ? [{ id: "work" as Tab, label: "Work", icon: ChefHat }] : []),
    { id: "profile", label: "Profile", icon: User },
  ];
  return (
    <div className="pf-tabs">
      {tabs.map((t) => {
        const Icon = t.icon;
        const on = tab === t.id;
        return (
          <button key={t.id} className={cn("pf-tab", on && "on")} onClick={() => setTab(t.id)}>
            <span className="pf-tab-ico">
              <Icon className="h-[1.2rem] w-[1.2rem]" strokeWidth={on ? 2.6 : 2} />
            </span>
            {t.label}
          </button>
        );
      })}
    </div>
  );
}

// Live server → app pushes (order feed, promos, delivery). Individual screens also
// subscribe; this top-level one just surfaces promo toasts + refreshes badges.
function LiveBridge() {
  const { toast, refreshHome } = usePhone();
  useNuiEvent("promo", (d) => {
    if (d?.title) toast(`${d.title}`);
  });
  useNuiEvent("backup", () => toast("Kitchen is backing up — tickets piling up", "err"));
  useEffect(() => {
    const t = setInterval(refreshHome, 30000);
    return () => clearInterval(t);
  }, [refreshHome]);
  return null;
}

function Shell() {
  const { ready } = usePhone();
  return (
    <div className="pf-root font-sans">
      <Toast />
      <LiveBridge />
      {!ready ? (
        <Spinner label="Loading Pickle Food…" />
      ) : (
        <>
          <div className="pf-statusbar" />
          <div className="pf-scroll">
            <Router />
          </div>
          <CartBar />
          <TabBar />
          <AskModal />
        </>
      )}
    </div>
  );
}

export default function PhoneApp() {
  // Best-effort: tell lb-phone we're a host-aware page (skips the dev handshake).
  useEffect(() => {
    (window as any).__lbHostPresent = true;
    // Signal readiness so the driver-blip cleanup can be requested on unmount.
    return () => {
      fetchNui("phone:endDeliveryBlip", {}).catch(() => {});
    };
  }, []);
  return (
    <PhoneProvider>
      <Shell />
    </PhoneProvider>
  );
}
