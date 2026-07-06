// NUI localization — the client-side mirror of Lua's `locales/locale.lua` `_L`.
//
// User-facing strings in the admin/creation panels used to be hardcoded inline,
// often lower-cased ("owned", "no counter", …). Route them through `_L(key, …)`
// instead so copy lives in one place, reads consistently, and can be translated
// without touching component code. Placeholders use `string.format` style
// (`%s`, `%d`) so keys line up with the Lua side.

type Strings = Record<string, string>;

const en: Strings = {
  // ── Admin panel shell ───────────────────────────────────────────────────
  "admin.title": "Restaurant Administration",
  "admin.subtitle": "Server-wide management",
  "admin.tab_restaurants": "Restaurants",
  "admin.tab_recipes": "Recipes",

  // ── Restaurant list / creation ──────────────────────────────────────────
  "admin.internal_name": "Internal name",
  "admin.display_label": "Display label",
  "admin.create": "Create",
  "admin.no_restaurants": "No restaurants yet. Create one above.",
  "admin.owned": "Owned",
  "admin.server_owned": "Server-owned",
  "admin.counter_set": "Counter set",
  "admin.no_counter": "No counter",
  "admin.restaurant_summary": "%s · %s stations · %s",

  // ── Restaurant detail ───────────────────────────────────────────────────
  "admin.balance": "Balance %s",
  "admin.tab_overview": "Overview",
  "admin.tab_settings": "Settings",
  "admin.delete": "Delete",
  "admin.delete_confirm": "Delete %s and all its data?",
  "admin.cancel": "Cancel",
  "admin.confirm": "Confirm",

  // Ownership
  "admin.ownership": "Ownership",
  "admin.owned_by": "Owned by %s",
  "admin.currently_server_owned": "Currently server-owned.",
  "admin.change_owner": "Change owner…",
  "admin.set_server_owned": "Set server-owned",

  // Counter
  "admin.counter": "Counter",
  "admin.counter_placed": "Counter is placed.",
  "admin.no_counter_placed": "No counter placed yet.",
  "admin.reposition": "Reposition",
  "admin.place": "Place",

  // Stations
  "admin.stations": "Stations",
  "admin.station_soda_machine": "Soda Machine",
  "admin.station_fryer": "Fryer",
  "admin.station_stovetop": "Stovetop",
  "admin.station_kitchen_prep": "Kitchen Prep",
  "admin.stations_hint":
    "Placing a station closes this panel so you can position it in the world. Re-open with the admin command to continue.",

  // Seating
  "admin.seating": "Seating",
  "admin.seating_hint":
    "A seat is an invisible sit point — place it on one of this restaurant's chairs and players get a “Sit” prompt there.",

  // Branding
  "admin.branding": "Branding",
};

const languages: Record<string, Strings> = { en };

// Matches Config.Language on the Lua side; only `en` ships today.
let active = "en";

export function setLanguage(lang: string) {
  if (languages[lang]) active = lang;
}

/** Localize `key`, filling `string.format`-style `%s`/`%d` placeholders in order. */
export function _L(key: string, ...args: (string | number)[]): string {
  const table = languages[active] || en;
  const template = table[key] ?? en[key] ?? key;
  let i = 0;
  return template.replace(/%[sd]/g, () => {
    const v = args[i++];
    return v === undefined ? "" : String(v);
  });
}
