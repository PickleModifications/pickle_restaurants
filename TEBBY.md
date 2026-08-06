# TEBBY.md - pickle_restaurants

## Overview

`pickle_restaurants` is a FiveM (FXServer, `fx_version 'cerulean'`, Lua 5.4) resource
implementing a fully in-game-configurable restaurant and cooking-job system. Server operators
and restaurant owners create and manage restaurants, props, recipes, menus, staff ranks,
and pricing entirely through an in-game admin panel backed by a MySQL database — there is
**intentionally no `config.lua`**. All gameplay configuration lives in the database
(`pickle_restaurant_settings` table); `core/shared.lua` holds only engine constants and
runtime-detected values. The NUI is a React + TypeScript + Vite + Tailwind app under
`web/`, built to `nui/` (the committed build output FiveM serves directly).

---

## Code design

### Architecture at a glance

```
fxmanifest.lua
  shared_scripts: core/shared.lua, bridge/**/shared.lua, locales/**
  client_scripts: bridge/**/client.lua, core/client.lua, modules/**/client.lua
  server_scripts: @oxmysql/lib/MySQL.lua, bridge/**/server.lua, core/server.lua, modules/**/server.lua
  ui_page: nui/index.html
```

**Database is the source of truth.** `core/server.lua` bootstraps on `MySQL.ready`,
creates all tables with `CREATE TABLE IF NOT EXISTS`, seeds default settings and recipes,
then populates module-global caches and sets `RestaurantsReady`. All mutators write
through to both cache and MySQL simultaneously.

**Server caches** (module-globals, top of `core/server.lua`):
`RestaurantCache`, `PropCache`, `RecipeCache`, `RecipeByInput`, `RecipeByOutput`,
`StockCache`, `TrayCache`, `SettingsCache`, `ItemImageCache`, `OrderCache`,
`NextTicket`, `OrdersDirty`, `PendingRefunds`, `TipCache`.

### Client-server sync flow

1. Client sends `pickle_restaurants:requestSync`.
2. Server replies with `pickle_restaurants:setupInventory` (item catalogue) and
   `pickle_restaurants:sync` (`BuildSyncPayload`). **Only valid configs are synced** —
   recipes referencing missing items are filtered out (but still shown flagged in the
   admin panel).
3. After any config change, server calls **`SyncWorldSoon()`** — a coalesced flusher that
   sends at most one full world payload per `SYNC_MIN_MS`, preventing per-keystroke
   broadcast storms from the auto-saving panel.

### Proximity-scoped world: the reconciler

A client holds **only the restaurants it is physically near** (`REST_IN`/`REST_OUT` ~250/320m
hysteresis). `modules/main/client.lua` runs ONE reconciler thread that **diffs** each prop
row against the row it was spawned from (`propRowSig`). An unchanged prop is left alone; a
moved or re-styled one is rebuilt; a deleted or out-of-range one is torn down. This is what
makes scoped network events safe: `world:getRestaurant(rid)` re-fetches everything when a
player walks into range, repairing any missed events.

### Network audience rules (no `-1` broadcasts)

Every world event resolves an audience first, using primitives in `core/server.lua`:
`PlayersNearPoint`, `PlayersNearProp(propId, radius)`, `PlayersNearRestaurant(rid, radius)`,
`SendTo`, `SendNear`, `SendNearProp`. `PlayersNearProp`/`PlayersNearRestaurant` **fail
CLOSED** — an unknown prop or an empty restaurant yields nobody; falling back to `-1` is
never the default. Exactly three `-1` sends remain (phone promo push, two qb-phone client
registrations); each is justified at the call site in `CLAUDE.md`.

### Module system

Each module is a self-contained feature loaded by the `modules/**/client.lua` and
`modules/**/server.lua` globs. Key modules:

| Module | Responsibility |
|---|---|
| `main` | Sync receive, prop spawning, blips, station/seat/counter interactions |
| `cooking` | Interactive cooking UX (drag ingredients, cook states, dual-sided patties, tray/box/bag assembly) |
| `stovetop` | Oven doors, fryer baskets, cook-pose scenario (safe `ClearPedTasks` escalation) |
| `management` | Employment, ranks, pay, tips, payroll, finances, per-restaurant menu |
| `sales` | POS register, kiosk orders, kitchen tickets, delivery flow |
| `seating` | Seat-anchor sit/stand, reservation gate, ask-to-sit exchange |
| `mirror` | Owner publishes prep/meal layout to nearby players as local props |
| `screens` | DUI menu/orders boards painted on placed screen props |
| `register` | In-world DUI POS counter painted on the counter model |
| `kiosk` | Self-service order DUI on kiosk prop |
| `npc_customers` | AI customers: walk up, queue, place POS ticket, wait, pay |
| `supply` | Optional supply-run feature (depot → hauling → larder credit) |
| `phone` | Phone app bridge: orders, delivery, bookings |
| `admin` | `/restaurants` command, admin panel NUI, restaurant/job/settings management |
| `placement` | In-world prop/seat/counter/shell/door placement gizmo |
| `consume` | Eating and drinking animations, vessel item use |
| `cookfx` | Kitchen fires: ignite after burn, extinguish, world-broadcast (exception to scope rule) |
| `camera` | Scripted cook's camera, hides local ped |
| `virtual` | Private kitchen-shell session for virtual station props |
| `rendertarget` | DUI brand textures on packaging (cup, tray, bag, pizza box) |
| `quad` | Food picture drawn as a textured quad inside an open takeout box |
| `locale` | Pushes the active locale table to the NUI |
| `dining` | Table-service dine-in flow |
| `doorstep` | Delivery door knock + hand-off |

### Framework & inventory bridge

`bridge/**` abstracts the framework so modules never call ESX/QB directly. Each bridge
file guards on `GetResourceState(...)` and returns early if its framework is not running,
so all variants are loaded together and only the active one defines globals.

**Auto-detection order:**
1. `bridge/esx/` — if `es_extended` is started.
2. `bridge/qb/` — if `qb-core` is started, or `qbx_core` with the QB compat export reachable.
3. `bridge/custom/` — standalone fallback (own MySQL money table, own job table `pickle_restaurant_job_players`).

**Inventory** (`bridge/inventory/`) is a separate driver layer — not part of the framework
bridge. The highest-priority driver whose resource is started wins. An ESX-native driver
gets a metadata overlay (`bridge/inventory/metadata/`) that keeps one DB row per
metadata-bearing item unit, reconciled against the inventory's live count. Drivers include:
`ox_inventory`, `qs-inventory`, `ps-inventory`, `qb-inventory`, `lj-inventory`,
`origen_inventory`, `codem-inventory`, `core_inventory`, `tgiann-inventory`,
`jaksam_inventory`, `esx` (with metadata overlay), `qb`, and `none` (floor driver).

**Society/banking** (`bridge/society/`) is probed by PROVIDER, not by framework:
Renewed-Banking → okokBanking → fd_banking → qb-management → qb-banking →
esx_addonaccount → own table. Priority matters because Renewed-Banking shims the others.

**Target system** is auto-detected in `core/shared.lua` (`Config.UseTarget`); no manual
toggle. Supported: `ox_target`, `qb-target`, `qtarget`.

**Phone bridge** (`bridge/phone/`) is probed by provider: `lb-phone`, `qb-phone`,
`gksphone`, `qs-smartphone`, `yseries`, `17mov_Phone`.

### NUI / theming

Two theme scopes: each restaurant has its own `metadata.theme` (skins its panels), and the
admin panel has a global `app_theme` setting. Both use `{ primary = "#rrggbb", mode =
"dark"|"paper", radius = "sharp"|"soft"|"round" }`. `applyTheme()` in
`web/src/lib/theme.ts` derives the full palette in OKLCH/OKLab and emits plain `"R G B"`
triplet CSS custom properties. **FiveM's CEF does not support `color-mix()` or CSS
relative color syntax** — never use them; consume tokens as `rgb(var(--x) / alpha)`.

The signature receipt paper (`.receipt`) is for printed slips only (finished tickets,
PayConfirm). The build cart is a normal themed surface. `backdrop-filter` must never be
used (CEF renders it as an opaque black rectangle on transparent NUI pages).

Fonts: Bricolage Grotesque (display), Figtree (body), Spline Sans Mono
(money/counts/timers — the "receipt voice").

### Localization

All player-facing strings live in `locales/translations/en.lua` (and additional locale
files). The NUI pulls the full locale table at boot via `modules/locale`. The `_L(key, ...)`
helper returns `"ERR_TRANSLATE_<key>_404"` for a missing key — never a Lua error.

### No migrations policy

Every column a module needs is declared in its table's single `CREATE TABLE IF NOT EXISTS`
in `CreateTables()`. There are no `ALTER TABLE` guards. Default settings and recipes are
seeded idempotently on boot (missing keys only — never clobbering admin customisations).

---

## Important files

| Path | Why it matters |
|---|---|
| `fxmanifest.lua` | Resource manifest: load order, escrow_ignore list, dependencies |
| `core/shared.lua` | `Config` table (engine constants only), `_L`, seat styles, render-target registry, shared utilities |
| `core/server.lua` | Database bootstrap, all server caches, `CreateTables()`, `SyncToClient`, `SyncWorldSoon`, `PlayersNearProp`, `PlayersNearRestaurant`, `GetRestaurant`, `HasPerm`, `ResolvePerms`, `AddStock`, `AdjustBalance`, `SetSetting` and all core server API |
| `core/client.lua` | `CreateInteraction`, `DeleteInteraction`, `CreateBlip`, `ForcePauseMenuClosed`, `ScriptEntities` cleanup, `PlayAnim`, interaction tick loop |
| `modules/main/client.lua` | World reconciler (`RWorld`), `SpawnProp`, `DespawnProp`, `GetClientProps`, `GetClientPropEntity`, proximity blip/interaction management |
| `modules/main/server.lua` | `workPerms` callback, `playerJoining` sync trigger |
| `modules/cooking/client.lua` | Heavy interactive cooking UX, `DragGate`, `PrepStacks`, `EnsureModel`, `modelHeight`, `HeldStackOffsets`, tray/box/bag assembly |
| `modules/management/server.lua` | Employment (hire-offer pattern), ranks, payroll, tip pool, menu pricing, `SetRestaurantTheme`, `SanitizeTheme`, `BuildPricedCatalog` |
| `modules/sales/server.lua` | POS orders, `GetOpenOrders`, `SyncOrders` (three disjoint audiences), `startTransaction`/`endTransaction` events |
| `modules/stovetop/client.lua` | Oven door tween, fryer baskets, cook pose (scenario with escalated stop) |
| `modules/mirror/client.lua` | Owner-published prep/meal layout to nearby players |
| `modules/seating/server.lua` | Seat gate, ask-to-sit exchange, reservation hold |
| `modules/npc_customers/server.lua` | AI customer loop: spawn, queue, POS ticket, patience, tip |
| `modules/supply/server.lua` | Supply run feature: depots, zones, box hauling |
| `bridge/esx/server.lua` | ESX framework bridge: money, jobs, admin check (ACE + ESX group column) |
| `bridge/qb/server.lua` | QB/QBox bridge: same API as ESX bridge |
| `bridge/custom/server.lua` | Standalone bridge: own money table, own job table, `JobPlayerCache` |
| `bridge/inventory/server.lua` | Inventory driver resolver, `Inventory` global |
| `bridge/inventory/metadata/server.lua` | Metadata overlay for ESX-native (no-slot) inventories |
| `bridge/society/server.lua` | Society/banking provider probe |
| `bridge/target/ox_target/client.lua` | ox_target interaction shim |
| `locales/locale.lua` | `_L()` helper, `LocaleTable()` for NUI |
| `locales/translations/en.lua` | All English player-facing strings (single source of truth) |
| `nui/index.html` | Built NUI entry point (do not edit — generated by Vite) |
| `nui/assets/` | Committed build artefacts (JS/CSS bundles, fonts) |
| `web/` | NUI source (React + TypeScript + Vite + Tailwind); edit here, then build |
| `__INSTALL/` | Operator paperwork: SQL item definitions, icon images (not runtime code) |

---

## Intended behaviors

### Deliberately no `config.lua`

This resource has **no `config.lua` by design**. The `core/shared.lua` `Config` table holds
only engine constants and auto-detected values (framework, target, inventory). All
gameplay-tunable values (`profit_margin`, `ingredient_costs`, `blip`, `consume_anims`,
`bake_slots`, `stack_tweaks`, `kitchen_fires`, `supply_runs`, etc.) live in the
`pickle_restaurant_settings` database table and are edited from the in-game admin panel.
A fix that adds gameplay config to `core/shared.lua` instead of `DEFAULT_SETTINGS` in
`core/server.lua` is wrong.

### `SyncWorldSoon()` — never `SyncToClient(-1)` directly

Direct `-1` sends are expensive (one message per connected player). Config changes must
always call `SyncWorldSoon()`, which coalesces many edits into one send per
`SYNC_MIN_MS`. Any new code calling `TriggerClientEvent(ev, -1, …)` for world state is a
bug unless it meets the existing exceptions (phone promo push, qb-phone registrations).

### `PlayersNearProp`/`PlayersNearRestaurant` fail CLOSED

Returning nobody for an unknown prop or empty restaurant is deliberate. The helpers must
never fall back to `-1`. A new event that scopes by prop or restaurant must use these
helpers — and must point at the hydration edge that repairs a missed event for a late
arrival.

### Hire as offer, not direct assignment

`management:hire` never immediately sets the target's job. It raises an offer
(`HireOffers` table, 30s TTL) that the target answers. The job is only set on accept, and
every hire condition is re-validated at that point. This prevents a `manage_employees`
holder from overwriting a passer-by's police/EMS job without consent. Removing the
offer pattern is a deliberate design, not an oversight.

### ESX admin check: ACE principals + ESX group column

`IsPlayerAdmin` in `bridge/esx/server.lua` checks **both** `IsPlayerAceAllowed` (for
`group.admin` / `command` principals set in `server.cfg`) and the ESX `users.group`
column. Checking only one is intentionally wrong — the two systems are independent, and
a server owner who granted themselves admin via ACE would otherwise be refused.

### `escrow_ignore` in `fxmanifest.lua`

`__INSTALL/**`, `bridge/**`, and `locales/**` are intentionally excluded from Cfx
escrow. These are the files a buyer must be able to read and edit (install items, adapt
bridges to their server, translate strings). The gameplay logic in `modules/` is not
excluded.

### `ForcePauseMenuClosed` — no `ActivateFrontendMenu`

The pause-menu suppressor in `core/client.lua` calls **only** `SetPauseMenuActive(false)`.
Any re-introduction of `ActivateFrontendMenu(...)` is the "I had to reboot" bug:
it opens an empty paused frontend with no way to dismiss it. The function is documented
at the call site.

### Standalone bridge `JobPlayerCache`

On a frameworkless server, `bridge/custom/server.lua` is the job system. It keeps jobs in
`pickle_restaurant_job_players` and `JobPlayerCache`. `JobsAvailable()` returns `false`
(meaning "no framework job system" — not "no jobs") so the admin panel shows the job
editor rather than a read-only framework list.

### Metadata overlay for ESX inventories

`bridge/inventory/metadata/server.lua` keeps one row per metadata-bearing item unit in
`pickle_restaurant_item_meta`. This is not a bug — ESX stores items as name + count with
no slots, so the overlay is the only way to store build-stack variation (a burger differs
from a chicken sandwich even though both are `restaurant_item`). Virtual slot 0 is always
the "plain units" remainder and deleting against it removes no metadata row.

### `SyncOrders` — three disjoint audiences

`modules/sales/server.lua` sends the full ticket list to STAFF only; a customer/driver
party gets only their own tickets; bystanders get `publicOrders` (ticket #, lines, total,
ready-state — identity stripped). This is a deliberate disclosure boundary; the projection
that hides personal data runs server-side. Never move it to the client.

### `STACK_MIN_GAP` and `stack_tweaks` / `bake_slots`

The stacking-height minimum and the per-model manual corrections (`StackTweaks`,
`stack_tweaks` setting, e.g. the pizza-cheese sink values) are calibrated against shipped
prop geometry. These values look like magic numbers but match specific model measurements.
Do not remove them.

### Cook-pose scenario escalated stop (`stovetop`)

`StopStovetopPose` asks politely once (via `ClearPedTasks`), then force-clears if the
ped is still in the scenario. The escalation loop is bounded and only ever clears — it
never re-tasks. The object-sweep after the scenario is intentionally narrowed to things
attached to the ped or matching `POSE.models` within `POSE.radius`, so map-placed props
and food props the resource owns are never accidentally deleted.

### Menu is fetched, not synced

A restaurant's priced menu (full item catalog with images) is NOT in the sync payload. It
is fetched on demand via `screens:getMenu`, cached per restaurant, and dropped by
`RefreshScreens()` on a price edit. Putting it back in `BuildClientRestaurant` would
restore a worst-case scaling problem.

### `none` inventory driver

`bridge/inventory/none/server.lua` is the floor driver for a server with no supported
inventory resource. It reports honestly that it holds nothing; `giveVessel` then falls
back to the kitchen tray instead of destroying a meal. This is deliberate.

---

## Common issues & fixes

### Resource name must be exact

The resource folder must be named **`pickle_restaurants`** (with an `s`). A folder named
`pickle_restaurant` (without `s`) causes locale strings to fail to load (NUI shows
`ERR_TRANSLATE_*_404` everywhere) because ox_lib and other resources key on the exact
resource name. See the Knowledge Base "Common Issues" page.

### Start order

`pickle_restaurants` must start **after** `ox_lib` and `oxmysql`. Both are declared as
`dependencies` in `fxmanifest.lua`, so FiveM will refuse to start the resource if they
are missing, but they must also be started before it in `server.cfg` order on some server
setups.

### Framework not detected → standalone bridge loads

If neither `es_extended` nor `qb-core` is detected, `bridge/custom/server.lua` loads. On
a QBox server with the QB compat bridge disabled (`qbx:enablebridge false`), this is
expected. On a server that intends ESX or QB, check that the framework resource is listed
**before** `pickle_restaurants` in `server.cfg` and is fully started.

### Inventory bridge picks wrong driver

All inventory bridge files are loaded together; the first started resource wins. If
`Inventory` is nil or wrong, check `GetResourceState(...)` for each supported inventory
resource. The priority order is listed in `bridge/inventory/server.lua`.

### Society account "bank refused" error

`mgmt_bank_refused` means the society provider found no account for the restaurant's job
name. The job must exist as an account in the banking resource (Renewed-Banking,
okokBanking, qb-management, etc.). Creating the job in the framework is not enough if
the banking resource manages account creation separately.

### Missing item images in NUI

`InventoryImageBase()` in `core/shared.lua` probes for supported inventory resources.
An unknown inventory returns `nil` and items show a placeholder. Add a row to
`INVENTORY_IMAGE_BASES` in `core/shared.lua` to support an unlisted inventory.

### Custom item images for tray-only products

Burger, burnt patties, cooked pizza, etc. are not real inventory items and have no
catalogue image. Use the admin panel's item thumbnail editor (Food & Drinks /
Ingredients tabs) to upload a custom image — stored in the `item_images` setting,
consulted first by `GetItemImage`. Editing `nui/assets/` directly is pointless
(generated bundles).

### NUI changes require a build step

After editing anything in `web/src/`, run `npm run build` in the `web/` directory.
The output goes to `nui/` (committed). Editing `nui/assets/*.js` / `*.css` directly
is pointless; they are overwritten on the next build.

### `Config.BoxQuad` aspect drift

The food picture inside a takeout box is governed by `Config.BoxQuad` in
`core/shared.lua`. If the picture appears distorted, tune `w`, `h`, and `dz` in-game.
This is an embedded constant tied to the shipped box model geometry — it is not in the
database settings.

### `stack_tweaks` / `bake_slots` not taking effect in game

Both settings are synced to clients on `SyncWorldSoon()`. Changes made directly in the DB
without going through `SetSetting()` will not flush the cache or trigger a sync. Use the
admin panel.

### Supply runs: `supply_no_zone` / `supply_zone_busy`

Both are runtime states, not config errors. `supply_no_zone` means the loading-bay row
was deleted after the run was claimed; `supply_zone_busy` means another player holds the
claim. The `claim_ttl` (default 900s) will release a stale claim automatically.

### Pause-menu lock ("I had to reboot")

If players get stuck in a paused game with a blank frontend: a code path is calling
`ActivateFrontendMenu(...)` in a loop. This is the documented "reboot" bug; see the
comment block around `ForcePauseMenuClosed` in `core/client.lua`. Remove any
`ActivateFrontendMenu` call from the view's closing path.

### Font Awesome icon not visible in target menu

`STATION_ICONS` and `STATION_LABELS` in `modules/main/client.lua` use Font Awesome 6
**Free Solid** icons only. Pro-only icon names render as empty targets. Verify any new
icon name exists in the free set before using it.

---

## Conventions

### Naming

- Lua globals use `PascalCase` for caches and module-global tables (`RestaurantCache`,
  `PropCache`, `DragGate`); `camelCase` for local variables and functions (`spawnedProps`,
  `targetCoords`).
- Module-level locals that cross function boundaries but are not globals use `camelCase`.
- DB table names are prefixed `pickle_restaurant*`.
- Setting keys in `pickle_restaurant_settings` use `snake_case` strings.
- Locale keys use `snake_case` strings (e.g. `"main_use_station"`).

### File structure

- Every module lives under `modules/<name>/client.lua` and/or `modules/<name>/server.lua`.
- Bridge adapters live under `bridge/<layer>/<provider>/client.lua` (or `server.lua`),
  with a `shared.lua` for the registry and a top-level `server.lua` / `client.lua` for
  the resolver and public API.
- No gameplay logic belongs in `bridge/`; no framework calls belong in `modules/`.

### Settings

- New admin-tunable values go into `DEFAULT_SETTINGS` in `core/server.lua`, not into
  `core/shared.lua`. The `SetSetting`/`GetSetting` API writes through to both cache and DB.
- Engine constants or values auto-detected at startup (framework, target, inventory) go
  into `core/shared.lua`'s `Config` table.

### Network events

- World events must resolve an audience with `PlayersNearProp`, `PlayersNearRestaurant`,
  or `SendNear` before sending.
- `-1` sends require a written justification at the call site.
- `SyncWorldSoon()` for any change that modifies the sync payload; never
  `TriggerClientEvent(ev, -1, …)` directly for config state.

### Error handling

- Bridge export probes go through the layer's own `pcall` helper
  (`PhoneCallExport` / `InvExport` / `SocietyExport`) — never index an export directly
  as an argument to `pcall`.
- `PlayersNearProp` / `PlayersNearRestaurant` must never fall back to `-1` on failure.

### Lua version

Lua 5.4 (`lua54 'yes'` in the manifest). Use `//` for integer division where needed.
The file `modules/cooking/client.lua` is at Lua's 200-local ceiling; do not add new
top-level locals there — use the existing global or closure patterns documented in that
file's comments.

### UI

- Style with Tailwind theme tokens (`bg-card`, `text-primary`, etc.), never hardcoded colors.
- Never use `color-mix()`, CSS relative color syntax, or `backdrop-filter` in any
  stylesheet or inline style — FiveM's CEF does not support them.
- Receipt paper (`.receipt`, `.receipt-rule`, `.tear-t`, `.tear-b`, `.tape`) is for
  printed slips only; the build cart is a normal themed surface.
- After editing `web/src/`, commit the rebuilt `nui/` output.
