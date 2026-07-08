// NUI localization — the client-side mirror of Lua's `locales/locale.lua` `_L`.
//
// User-facing strings across the whole front-end (admin, cooking, management,
// ordering, register, settings, …) are routed through `_L(key, …)` rather than
// hardcoded inline, so copy lives in one place, reads consistently, and can be
// translated without touching component code. Placeholders use `string.format`
// style (`%s`, `%d`) so keys line up with the Lua side.
//
// The string table is data (`strings.en.json`) so it can be regenerated/merged
// mechanically. Add a language by shipping another JSON table and registering
// it in `languages` below.

import en from "./strings.en.json";

type Strings = Record<string, string>;

const languages: Record<string, Strings> = { en: en as Strings };

// Matches Config.Language on the Lua side; only `en` ships today.
let active = "en";

export function setLanguage(lang: string) {
  if (languages[lang]) active = lang;
}

/** Localize `key`, filling `string.format`-style `%s`/`%d` placeholders in order. */
export function _L(key: string, ...args: (string | number)[]): string {
  const table = languages[active] || (en as Strings);
  const template = table[key] ?? (en as Strings)[key] ?? key;
  let i = 0;
  return template.replace(/%[sd]/g, () => {
    const v = args[i++];
    return v === undefined ? "" : String(v);
  });
}
