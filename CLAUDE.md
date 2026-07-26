# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`pickle_restaurants` is a FiveM (FXServer, `fx_version 'cerulean'`, Lua 5.4) resource
implementing a fully in-game-configurable restaurant/cooking job. Servers create and
configure restaurants, props, recipes, menus, and employees entirely from an in-game
admin panel — **there is intentionally no `config.lua`**. All gameplay configuration
lives in the database; `core/shared.lua`'s `Config` table holds only engine constants
and runtime-detected values (framework / target / inventory). Admin-tunable values live
in the `pickle_restaurant_settings` DB table, edited via the NUI.

## Building the UI

The NUI is a React + TypeScript + Vite + Tailwind app under `web/`, built to `nui/`
(the committed build output that FiveM serves).

```bash
cd web
npm install
npm run dev     # vite dev server (browser, mocked NUI)
npm run build   # outputs to ../nui (emptyOutDir) — commit the result
```

There is no linter or test suite. `vite.config.ts` sets `base: "./"` and `outDir: "../nui"`.
After changing anything in `web/src`, you must `npm run build` for the change to appear in
game — editing `nui/assets/*` directly is pointless (they're generated bundles).

There is no build step for the Lua; FiveM loads it directly per `fxmanifest.lua`.

### NUI design system & per-restaurant theming

The whole UI derives from ONE seed. A restaurant's `metadata.theme` holds
`{ primary = "#rrggbb", mode = "dark"|"paper", radius = "sharp"|"soft"|"round" }`
(sanitized by `SetRestaurantTheme` in `modules/management/server.lua`; edited live
in the Brand tab of both boss + admin panels via `ThemeEditor` in
`web/src/components/Branding.tsx`; auto-saved like all settings). Every
restaurant-scoped view payload (management, register, cooking, payconfirm — and
`BuildClientRestaurant` for the client sync) carries `theme`; `App.tsx` applies it
via `applyTheme()` (`web/src/lib/theme.ts`) which only plants `--brand` /
`--brand-ink` + `data-mode` / `data-radius` on `<html>`.

There are TWO theme scopes. A **restaurant's** `metadata.theme` skins its own
scoped panels (register, cooking, management, payconfirm). The **admin panel**
(`/restaurants`) has its own franchise-independent seed, the `app_theme` SETTING
(`SanitizeTheme` in `modules/management/server.lua`, default in `DEFAULT_SETTINGS`),
edited in Settings → Appearance and carried as `theme` at the top of `buildAdminData`.
`Admin.tsx` holds it in state so the editor previews live and a restaurant detail
restores it on close (not `null`); per-restaurant edits inside the admin panel are
mirrored optimistically in `Restaurants` (`themeEdits`) so leaving and reopening a
detail re-applies the CURRENT seed, not the stale open-payload one. `ThemeEditor`'s
`onChange` is what keeps those parent caches live.

The signature receipt paper (`.receipt`, always light) is reserved for things that
represent a PRINTED slip — finished tickets and the customer PayConfirm. The
new-order BUILD cart is a normal themed working surface (`bg-card`, follows the
mode); `OptChip`/`OptRow` take a `paper` flag (default true) so the shared chip
reads correctly on either surface.

Everything else is DERIVED by `applyTheme()` itself: surfaces take the seed's
hue in OKLCH, washes/status/hover colors are OKLab blends — all computed in JS
and emitted as plain `"R G B"` triplet custom properties (`--bg`, `--card`,
`--line`, `--brand-hover`, …; static defaults in `index.css`). CRITICAL: FiveM's
CEF predates `color-mix()` and CSS relative color syntax — never use them (or
any modern color function) in CSS/classes; consume tokens as
`rgb(var(--x) / alpha)`, which is exactly what the Tailwind color map does, so
`/opacity` modifiers work. Style with tokens (`bg-card`, `text-primary`, …),
never hardcoded colors, and any new UI themes for free. Fonts: Bricolage
Grotesque (display), Figtree (body), Spline Sans Mono (money/counts/timers — the
"receipt voice"). Signature components: `.receipt` / `.receipt-rule` / `.tear-t` /
`.tear-b` (thermal-receipt paper — POS tickets and PayConfirm; NOT the build cart)
and `.tape` (mono uppercase eyebrow labels). NEVER use `backdrop-filter` — CEF
composites it as an opaque black rectangle on transparent NUI pages.

## Runtime architecture

**Database is the source of truth.** `core/server.lua` is the spine: on `MySQL.ready` it
runs `CreateTables()` (all `CREATE TABLE IF NOT EXISTS` + in-place `ALTER`/backfill
migrations), seeds default settings and recipes, then loads everything into module-global
caches and sets `RestaurantsReady`. Tables are prefixed `pickle_restaurant*`.

**Caches (server, module-global, defined at the top of `core/server.lua`):**
`RestaurantCache`, `PropCache`, `RecipeCache`/`RecipeByInput`, `EmployeeCache`,
`StockCache`, `TrayCache`, `SettingsCache`. Mutators (`AddStock`, `AddTray`,
`AdjustBalance`, `SetSetting`, …) write-through to both the cache and MySQL. Read the
cache; never re-query for data already cached.

**Client sync:** the client sends `pickle_restaurants:requestSync`; the server refreshes
the inventory catalogue and replies with `pickle_restaurants:setupInventory` (item list)
+ `pickle_restaurants:sync` (`BuildSyncPayload`). **Only valid configs are synced to the
world** — a recipe/drink/assembly referencing an item missing from the inventory
catalogue is filtered out of the payload (but still shown, flagged, in the admin panel so
it can be fixed). After any config change, server code calls `SyncToClient(-1)`.

**Migrations pattern:** schema changes are additive `SHOW COLUMNS` / `ALTER TABLE` guards
in `CreateTables()`, plus one-time data backfills gated behind a `pickle_restaurant_settings`
flag (e.g. `dual_sided_seeded`, `method_seeded`, `pizza_pepperoni_optional`). Default
settings/recipes are merged in idempotently on boot (missing keys only — never clobbering
admin customisations). Follow this pattern for new columns/defaults.

### Framework & inventory bridge

`bridge/**` abstracts the framework so modules never call ESX/QB directly. Each bridge
file guards on `GetResourceState(...)` and returns early if its framework isn't running,
so all variants can be loaded together (`bridge/**/server.lua` glob) and only the active
one defines the globals. Bridges provide a common API: `GetIdentifier`, `IsPlayerAdmin`,
`ShowNotification`, `AddMoney`/`RemoveMoney`, `GetPlayerCharacterName`, and an `Inventory`
table (`AddItem`, `RemoveItem`, `Items`, `ItemExists`, `RefreshItems`, …). Variants:
`esx`, `qb`, `custom`, plus `xp` and a `target/` layer (`ox_target`/`qb-target`/`qtarget`).
Target usage is auto-detected in `core/shared.lua` (`Config.UseTarget`); no manual toggle.

`Inventory.Items` (name → `{ label, image }`) is the catalogue the NUI uses so configs are
built by **picking real items** rather than typing codenames. `InventoryImageBase()` /
`InvImageUrl()` in `core/shared.lua` resolve `nui://` image paths across ~9 supported
inventories.

### Modules (`modules/<name>/{client,server}.lua`)

Each module is a self-contained feature loaded by the `modules/**` glob. Key ones:
- `main` — receives the sync, spawns placed station props, blips, and the interactions
  that open cooking/ordering/management.
- `cooking` — the heavy interactive station UX (drag ingredients into the 3D world, props
  cook `01→02→03`, dual-sided patties, cheese melt states, oven/fryer/grill methods).
- `placement` / `gizmo` — placing & positioning station props (`PLACEABLE_MODELS` maps
  `prop_type` → model). Also places **seats**: `prop_type = "seat"` rows in the same
  `pickle_restaurant_props` table, but INVISIBLE — no model/runtime prop, only a
  point + heading (placed with a ghost-ped gizmo preview, `saveSeat`).
- `seating` — players sit on the placed seat anchors. `main`'s `SpawnProp` gives a
  `seat` prop a "Sit" interaction (no world prop) → `SitOnSeat` plays a seated
  scenario at the anchor; `E` stands up (`EnableInteraction` is toggled off while
  seated). Server tracks per-anchor occupancy so two players can't share one seat.
  Player-only for now; NPCs sitting to be served would be a larger phase-2. Tunables:
  `SIT_SCENARIO` / `SIT_OFFSET_Z` in `modules/seating/client.lua` (TUNE IN-GAME).
- `management` / `admin` — the boss/owner and admin panels (employees, roles, finances,
  settings, recipes).
- `sales` / `npc_customers` — selling to players and NPC customers.
**Render-target registry (ONE source of truth).** Every DUI-painted texture — food
packaging brands, the kiosk brand/order screen, the menu/orders boards, and the register
POS — is ONE entry in `Config.RenderTargets` (`core/shared.lua`): `{ key, group, txd,
txn, w, h, rot, flipx, flipy, … }`. **`w`/`h` are the UPRIGHT display aspect** — the
size/shape as you see it on the prop and crop it in the panel, so the config value always
matches the UI. The DUI/texture SURFACE aspect is DERIVED (`RenderTargetSurface(t)` —
w/h swapped for a 90/270 `rot`); the page rotates the content back upright. The modules
that paint them are filtered VIEWS of the registry
(`RenderTargetsByGroup("packaging","kiosk")` in `rendertarget`,
`RenderTargetsByGroup("screen")` in `screens`, `RenderTargetByKey("register")`/`("kiosk")`
in `register`/`kiosk`), and they size their DUIs with `RenderTargetSurface`. The NUI crop
UI reads the SAME numbers: `BrandRenderTargets()` (the config w/h directly; `configKey`
borrowers skipped) is synced into the admin + management payloads as `renderTargets` and
consumed by `Branding.tsx` — NO more hardcoded `BRAND_TEXTURES`. The `/pickle_*_res|orient`
debug commands mutate these entries live (orient rebuilds the DUI, since a 90/270 turn
changes the surface); bake the tuned numbers back into `Config.RenderTargets`.

- `rendertarget` — runtime **brand-texture replacement** via a DUI (`html/brand.html`);
  `AddReplaceTexture` is global per txd+txn, so only the nearest branded restaurant is
  active at once. A target may list `altTxds` (extra models embedding the same texture
  at the SAME orientation) — `applyReplacement` swaps them all to one runtime texture.
  When two models share a texture but their UVs run it at DIFFERENT rotations, they
  can't share one painted surface: give each its OWN target and a shared `configKey` so
  they read one brand config (the wall `kiosk` + floor `kiosk_ground` targets both read
  the `"kiosk"` image but paint at their own `rot`). `GetBrandKeyForModel(model)` returns
  the target key whose primary model is `model`; `GetBrandTargetOrient(key)` its rot/flip;
  `SuspendBrandTarget`/`ResumeBrandTarget(key)` let another module borrow a target's
  texture (the kiosk order screen).
- `kiosk` — the self-service kiosk as an **interactive in-world DUI**, not a fullscreen
  NUI. Idle, the kiosk shows the restaurant brand (rendertarget). On interact
  (`OpenKioskScreen`) it resolves the brand target for the exact model
  (`GetBrandKeyForModel` — wall `kiosk` vs floor `kiosk_ground`, which paint at different
  rotations), suspends THAT target, borrows its orientation (`GetBrandTargetOrient`, so
  the order page lands upright exactly like the brand image), takes over
  `kiosk_large_brand` on that model with a DUI running the built React app in `#kiosk`
  mode (`web/src/views/KioskDui.tsx`, selected in `main.tsx` by the URL hash), frames a
  scripted camera on the screen, and **hides the player ped** (`SetEntityVisible`, like
  entering an interactive entity) for the duration. A VIRTUAL CURSOR (mouse-look deltas →
  `SendDuiMouseMove` at the surface pixel) drives the page; CEF renders its OWN cursor
  onto the surface (never a world-drawn sprite — that lives in a different projection and
  clicks would miss it). The order still becomes a normal ticket (`sales:kioskOrder`).
  Camera framing / cursor speed / DUI aspect are `KIOSK` tunables (TUNE IN-GAME:
  `/pickle_kiosk_cam`, `/pickle_kiosk_res`).
- `register` — the STAFF POS register painted on the counter's `register_brand`
  screen. It is an **ALWAYS-ON board** (like the `screens` menu/orders boards): an idle
  driver picks the nearest counter's restaurant, keeps the `register_brand` texture
  bound, and paints the register UI (catalog + live ticket queue) persistently — seeded
  from a PUBLIC callback (`register:getPublic`, the same display-safe data the menu/
  orders boards show, `idle = true` so the page hides balance/close). On INTERACT
  (physical counter) `OpenRegisterScreen(prop, ent)` overlays the interactive layer —
  frames a scripted camera, hides the ped, swaps in the perm-gated `getRegister` payload
  (nearby customers + balance), and drives the same virtual-cursor loop as the kiosk;
  stepping away hands the screen back to the idle board (never blanks). The built React
  app runs in `#register` mode (`web/src/views/RegisterDui.tsx`, SQUARE aspect). It
  REPLACES the old customer-facing till display (the removed `screens` `register`
  board). Orders ring up through the unchanged `sales:createOrder`/`completeOrder`/
  `cancelOrder`; the live open-ticket list is forwarded into the DUI (`SendDuiMessage`,
  action `registerOrders`) off the `sales:orders` broadcast, for both the idle board and
  an open session. `ReassertRegister()` (from main's counter spawn) + `RefreshRegister()`
  (from `ApplySync`) keep it bound/current. Camera/cursor tunables (TUNE IN-GAME:
  `/pickle_register_cam`, `/pickle_register_sens`); `/pickle_register_res|orient` tune
  the shared registry copy (see the render-target registry note below).
  A VIRTUAL register (`prop_type = "virtual_register"`) is an invisible anchor with no
  screen to paint — placed like a seat (`StartVirtualRegisterPlacement` → ghost-ball
  gizmo → `saveVirtualRegister`), it keeps the ordinary fullscreen NUI register
  (`OpenRegister`, `web/src/views/Register.tsx`). Both kinds share the `OrderBuilder`
  (its `big` prop selects the in-world layout) and the `Tickets` panel
  (`web/src/components/RegisterTickets.tsx`). Management stays a fullscreen NUI on both.
- `screens` — the customer-facing DUI boards (`html/screens.html`), same replacement
  trick as `rendertarget` but the page is DYNAMIC and fed live data each tick. One
  `SCREENS` entry per board (`txd`/`txn`/`w`/`h`/`rot`/`flip*`, TUNE IN-GAME:
  `/pickle_screen_res`, `/pickle_screen_orient`, `/pickle_screen_debug`,
  `/pickle_screen_state`):
  **menu** (`pickle_screen_menu_01`/`s_m_brand`, the priced menu as a paged slideshow)
  and **orders** (`pickle_screen_orders_01`/`s_o_brand`, open tickets newest-first, live
  off the `sales:orders` broadcast). Each is driven from the NEAREST restaurant with that
  screen's prop placed (`AddReplaceTexture` is global per txd+txn). Both boards seed once
  via a one-shot callback and then stay live off a broadcast — a seed reply that a
  broadcast overtook is dropped (`dataEpoch`), since "no data" and "not asked yet" are
  indistinguishable and a stale write would never be corrected.
  (The counter's `register_brand` screen used to be a THIRD board here — the till's
  customer cart display — but it's now the cashier's interactive POS DUI, `modules/register`.)
  The counter still spawns a real model: `prop_type = "counter"` rows are no longer
  invisible anchors — `modules/main` spawns `COUNTER_MODEL` (`pickle_register_01`,
  exported as `CounterModel()` so the placement gizmo previews the real thing) at the
  point, and the counter's `model` column stays empty (it predates having one).

  A replaced texture is **albedo, never emissive** — it's drawn through the model's lit
  shader, so a screen is only ever as bright as the room it's in. Do NOT try to
  compensate by over-exposing the DUI page (a `filter: brightness()` gain, a white lift
  sheet): that was tried and removed — it washes the design out and still can't make a
  lit surface glow. A screen that reads as dim wants an **emissive shader on the model's
  screen material**, which is an asset-side fix.
- `itemgen` — `/restaurants_items` admin command exports ready-to-install item
  definitions (ox_inventory / ESX SQL / QBCore) into `generated_items/` from the **live**
  in-game config.

### Client interaction & NUI conventions

`core/client.lua` is a generic interaction engine (`CreateInteraction`/`DeleteInteraction`,
distance + target-zone based, with `ShowInteractText` and `onResourceStop` cleanup of all
spawned entities). This file is shared with sibling `pickle_*` resources and still contains
some `dealerships_`-prefixed context ids.

Server↔NUI: Lua uses `ox_lib` callbacks (`lib.callback.register("pickle_restaurants:...")`)
and `TriggerClientEvent` → `SendNUIMessage({ type/action = ..., ... })`. On the React side,
`web/src/lib/nui.ts` provides `fetchNui(event, data)` (POST to `https://<resource>/<event>`)
and `useNuiEvent(name, handler)` (matches on `action` **or** `type`). `App.tsx` switches a
single `setView` message between views: `cooking`, `admin`, `management`, `order`,
`register`, plus the always-on `InteractText` overlay.

### Permissions

Server-side authority only. `ResolvePerms(restaurantId, source)` returns
`(permsTable, isOwnerOrAdmin, employeeRow)`; admins and the owner get `ALL_PERMS`, otherwise
the employee's role (`r.roles` or the `default_roles` setting, keyed by grade) supplies the
permission set. Gate every mutating callback with `HasPerm(...)` / `IsPlayerAdmin(...)` —
the NUI is untrusted.

### The register: DUI (physical) vs NUI (virtual)

A PHYSICAL counter's register is an interactive in-world DUI painted on the counter's
`register_brand` screen (`modules/register`, cloned from `modules/kiosk`); a VIRTUAL
register (`prop_type = "virtual_register"`) has no screen to paint, so it keeps the
ordinary fullscreen NUI (`OpenRegister` → `web/src/views/Register.tsx`). Both use the
same `OrderBuilder` (the `big` prop selects the large in-world layout, with a click
customer-picker in place of the NUI's native `<select>`, since the virtual cursor can't
drive a native dropdown) and the same `Tickets` fulfilment panel (extracted to
`web/src/components/RegisterTickets.tsx`). Management stays a fullscreen NUI on both.

The live open-ticket list reaches the DUI the same way the NUI got it — off the
`sales:orders` broadcast — but forwarded as a `SendDuiMessage` (`registerOrders`), since
a DUI never receives `SendNUIMessage`. Order actions (`sales:createOrder` /
`completeOrder` / `cancelOrder`) `fetchNui` straight through unchanged (a DUI POSTs to
the resource just like the NUI); the focus re-assert in `modules/sales`'s relay is a
no-op for a DUI (`NUIView` is `none`), so it can't fight the in-world cursor.

NOTE: the old customer-facing "live cart preview" — the POS streaming its in-progress
cart to a separate customer till screen (`sales:cartPreview` → `sales:cart` broadcast →
the removed `screens` `register` board) — was REMOVED with this change. The register
screen IS the cashier's POS now, so there is no separate customer display to mirror to.

## Money & the cooked-items tray (subtle bits)

- All money crossing a boundary goes through `RoundMoney()` (whole dollars) so commissions
  never leave fractional cents.
- The **cooked-items tray** (`pickle_restaurant_cooked_items`, `TrayCache`) is a per-player,
  per-restaurant holding area between the grill and prep station. Its `cheese` column is
  `TINYINT UNSIGNED` (not `TINYINT(1)`) on purpose: oxmysql boolean-casts `TINYINT(1)`,
  which would destroy the third cheese state (`0=none, 1=applied, 2=melted`). Use
  `CheeseVal()` and the `item.."|"..cheese` tray key. Per-instance build stacks are stored
  in the row's `metadata` JSON so an assembled product can be taken back apart faithfully.
- **Build variations are addressed by signature.** `TraySig(meta)` canonicalises one
  instance's build stack ("" = plain); `GetTrayCount`/`TrayTopMeta`/`RemoveTray` take an
  optional trailing `sig` to target exactly that variation (nil = legacy any-instance),
  and `GetTray` splits display entries per sig. Every NUI drag/consume of a tray item
  threads the entry's `sig` through, so a pepperoni pizza and a plain one are separate
  tray entries and the right instance is consumed — never blind LIFO across variations.
  Variations survive the INVENTORY round-trip too: `buildInvMeta` writes the stack to
  the slot metadata, and the bridge's `Inventory.GetItemSlots`/`RemoveItemSlot`
  (ox_inventory/qb; absent on bare ESX → base-recipe fallback) let the cooking module's
  `invVariations`/`removeInvVariation` list, cook, and build with the exact slot.
  **Stacks nest one meta layer deep:** a product used as a layer inside another product
  (a pizza in a burger) keeps its own build stack on the layer's `stack` field —
  `makeStack` captures it off the consumed instance, `TraySig` recurses into it, and
  `prepDecompose` refunds/reserves that exact nested variation (rendered as its full
  layer tower via `compSpec`).
- **Serving tray & meals (kitchen prep).** The prep bar's "Serving Tray" card (kitchen
  equipment, never gated on an inventory item — the `meal_item` setting's item, default
  `meal`, is what gets *generated*, itemgen exports it; only `trayToInventory` requires
  it installed) places `pickle_tray_01` + `pickle_tray_paper_01` on the table. Food dropped over the tray anchors where it lands on the paper (clamped
  inside the rim); a pile on a tray is a normal client `PrepStacks` entry carrying
  `tid` + its `(dx, dy)` offset. `prepMakeMeal` consumes the arranged parts (the same
  `consumeLayers` path recipe makes use) and stores ONE meal whose metadata layers
  each carry `dx`/`dy` — `TraySig` appends `@x,y` (quantized to 1cm at make time), so
  the layout is part of the variation signature. Dragging a meal (tray- or
  inventory-held; `source` rides the decompose callbacks) un-makes it back into an
  editable tray build rendered 1:1. Trays auto-make into meals on station exit, and a
  pile made into a product while sitting on a tray is re-reserved and re-seated in
  place (`prepMakeStack` returns `sig` + a render `spec` for this).
- **Pizza box.** The serving tray's sibling (`kind = "pizzabox"`; equipment, never an
  item — both equipment cards ship in the getIngredients payload but the NUI files
  them under the COOKED ITEMS tab, leading the strip): the same tray machinery keyed by
  `kind = "box"` — `pickle_pizza_box_01` (base) + `pickle_pizza_box_02` (lid, the
  `pizza_box` brand target) spawned as a pair, placed closed. The lid is HINGED: a
  click on the box toggles it (NUI click-vs-drag threshold → `cooking:boxToggle`),
  swinging smoothly open/closed. The lid model's ORIGIN is authored on its hinge
  edge: `boxLidSeat` positions it ONCE per placement (a fixed `lid_fwd` step along
  the BASE's yaw-only forward — never the lid's own forward vector, which tips
  with its pitch mid-swing), and the open/close anim is `boxLidSwing`, ROTATION
  only (heading + opening pitch); `BOXP` tunables in `modules/cooking/client.lua`
  (TUNE IN-GAME).
  Only a pizza goes in: lid open, box empty, and the carried pile's BOTTOM layer a
  pizza crust at any cook state (client matches `BOXP.dough_models` by model; the
  server re-validates in `pizzaBaseLayer` by item / stack base / base recipe) — a
  qualifying drop seats CENTRED; anything else outlines red and is refused on
  release. A closed lid seals the contents (`stackSealed`: no hover/grab/stack).
  A pile INSIDE a box belongs to the BOX: hovering it hovers the box (click =
  lid, drag = the whole box — the part-grab is suppressed in the hover loop);
  the pizza leaves via the tooltip's Take Out (`cooking:boxTakeOut`, animated
  slide onto the table beside the box). Boxing it up CLOSES first: lid swings
  shut + 1s settle, then the meal is made (instant if already closed; `t.boxing`
  locks toggle/grab mid-close) — both the tooltip button and the drag-to-bar path.
  Boxing it up makes the SAME meal item with `box = true` on the first meta layer
  (`TraySig` appends `^box`), so a boxed pizza is its own variation and sets back
  down as its box, lid open (`prepDecompose`/`Peek` return `box`; `getTray` flags
  `boxed`).
- **Containered bakes.** A recipe's nullable `container_model` column (cake tin
  `pickle_cake_container_01`, future cookie trays) renders the food inside a container
  prop EVERYWHERE — oven slot, drag preview, prep table — by prepending it to the
  existing build-stack machinery (`it.stack`/`stackBase` in `place`; `withContainer`
  in `getTray`); only the `stackBase` layer swaps models as it cooks. The container is
  visual-only, never an item. NOTE: `pickle_cake_01..04` are the four flavored WHOLE
  cakes (strawberry/chocolate/vanilla/pickle), NOT cook states — the batter sheet
  bakes as `pickle_cake_mix_pour_02/03/04` (raw/cooked/burnt; best-guess mapping,
  correctable in the recipe editor; a one-time `cake_models_seeded` backfill repoints
  old DB rows that still hold the wrong defaults).
- **Soda machine (drinks).** The fountain has SEVEN taps: the middle one dispenses
  ice, the other six map to the first six `drinks` settings entries by RAW config
  position (tap N = entry N — STABLE even when some flavors are invalid; a missing
  CUP item leaves its tap dark. Only `drinks[].input` must be an installed item:
  `output` is a flavor KEY, not an item — every poured drink collects as the ONE
  `drink_item` setting's item ("Restaurant Drink", default `drink`, mirroring
  `meal_item`) with the flavor riding as build-stack metadata
  (`{ { item = <output key> } }`, TraySig'd so each flavor is its own variation);
  `drinkFlavor`/`drinkRender` resolve the label + capped cup+lid render everywhere
  (getTray both paths, compSpec for drink layers in meals). itemgen exports the
  generic item and grace-retains the legacy flavor items one release. BuildSyncPayload stamps each synced drink with its
  `tap` index so the client mirrors the server's `flavorForSlot` exactly; the model's
  printed flavor strip matches the default order, and a one-time
  `soda_tap_order_seeded` backfill reorders legacy DBs to it). Cups are slot items
  (`method = "soda"`, like fryer baskets): drag the cup item (`drinks[].input`) under
  a tap — the preview always LOCKS to the nearest free tap (`nearestOpenSlot`'s
  `anyDistance`), never trailing the cursor — click the tap to pour
  (`cooking:sodaTap`; empty → filling → filled), move a cup between taps with the
  normal reslot drag (ice first, then a flavor). A fountain holds ONE cup at a
  time (client offers no seat + server rejects a second). A poured cup ALWAYS
  needs the lid dragged onto it before it collects as `drinks[].output` — the
  lid is kitchen EQUIPMENT like the prep serving tray (no inventory item, never
  consumed; cups come with lids; only `drink_lid_model` configures it); the
  capped cup renders cup+lid as a normal slot build stack. Ice is a flag on the cup, rendered client-side as a
  cluster of the VANILLA loose-cube props (`prop_ice_cube_01..03`, the `ICE` table)
  sunk into the cup's measured rim — hidden again once the lid goes on, and NOT
  recorded on the collected item. Dispensing ANIMATES (never teleports): the
  progress payload's `fillKind` tells clients what a running tap is pouring — ice
  cubes spawn at the nozzle and free-fall (0.5·g·t², staggered; `dropSodaIce`,
  landing exactly in the `SodaIce` cluster seats so the ice-complete sync is a
  no-op), a drink pours a colored liquid STREAM — a column of sphere `DrawMarker`
  droplets recycling down the nozzle→cup gap with fake gravity (`startSodaPour`/
  `POUR`), tinted by the drink's `drinks[].color` (synced; a `POUR_COLORS` fallback
  by output covers pre-`color` configs; one-time `soda_colors_seeded` backfill) —
  markers not ptfx, so the color is ours and it never fizzles early. There is NO
  on-screen tap label: the fountain model prints each flavor, and a click on the
  printed nozzle is resolved world-side by `hoveredTapSlot` in `cooking:worldClick`
  (no NUI pill). Tap/cup/ICE/POUR tables live in `modules/cooking/client.lua`
  (TUNE IN-GAME). Tap X positions are COMPUTED, not hard-listed: `SODA.ice_gap`
  (centre → innermost drink tap = the ice area's half-width) + `SODA.gap` (spacing
  between adjacent drink taps) drive `sodaSlotX(slot)` — 3 taps step out to each
  side of the middle ice nozzle.
- **Finish tools (frosting) — the `finishes` setting.** A reusable "rub a tool over a
  product" system at kitchen prep: config is a list of `{ tool, tool_model, rub_dist,
  targets = { { item, output, mode = "replace"|"overlay", flavors = {{id,label,model}} } } }`
  (defaults: `frosting` → cooked_cake ⇒ `decorated_cake` replace-mode with the four
  whole-cake models; cooked_doughnut ⇒ `frosted_doughnut` overlay-mode with
  `pickle_doughnut_topping_01..05` incl. glazed). The NUI card (`kind = "finish"`) has
  flavor chips; the client drags the tube prop, accrues coverage from cursor travel
  over a valid reserved part, and fades the result prop in via `SetEntityAlpha`; at
  full coverage `cooking:applyFinish` re-validates everything, consumes the target
  layer + 1 tool item, and trays the output with ONE meta layer
  `{ item, flavor, flavorLabel, stack }` — `TraySig` appends `#flavor`, so flavors are
  separate variations end-to-end (replace-mode deletes the container+sheet props;
  finished items are deliberately NOT decomposable). Sync ships only `ItemExists`-valid
  entries (`BuildSyncPayload` → client `Finishes` global); itemgen collects finish
  tools/targets/outputs + `prep_models` keys. A sprinkles tool is one more config row —
  no code. Finishes now HAVE a full admin-panel editor (admin Menu tab → New Finish;
  `FinishFields` in `web/src/components/editors.tsx` edits tool/tool_model/rub_dist/
  group/cost + a nested targets→flavors editor incl. per-flavor hex colour). Fed by
  `AnnotateFinishes()` in the admin payload; saved whole via `admin:saveSettings`.

- **Condiments (ketchup / mustard / mayo) — the `condiments` setting.** A squeeze-bottle
  applicator that lays a sauce LAYER on a build stack. Config is a list of
  `{ item, container_model, applied_model }` (each flavor's `container_01` holds the sauce,
  `applied_01` is what's left on the food — no separate sauce item). Sibling to the finish
  tools in wiring (synced as the client `Condiments` global via `BuildSyncPayload`; a
  `kind = "condiment"` applicator card in `getIngredients`; itemgen exports the bottle
  item; `ingredient_costs` prices it) but DIFFERENT in effect: a finish consumes a FINISHED
  tray product and re-trays a decorated one, whereas a condiment adds a LAYER to an
  in-progress prep BUILD exactly like a pepperoni/pickle component — reserved via `prepAdd`
  (source nil, pool item), consumed at Make, riding along as a build-stack variation
  (`TraySig`). `itemModel(condiment)` returns the `applied_model`, so the layer renders as
  its sauce everywhere (prep table, tray, meal, decompose) — structurally identical to the
  existing `pickle` applied component. The gesture (`cooking:beginCondiment` in
  `modules/cooking/client.lua`): the bottle follows the cursor upright, FLIPS 180° (a pitch
  about its centre-bottom origin) when held over a valid stack, then SQUEEZES down-and-up
  once (`CONDIMENT` tunables — `flip_ms`/`squeeze_ms`/`dip`/`hover_gap`, TUNE IN-GAME); the
  sauce fades in and commits at the squeeze's end. A condiment can NEVER be a stack's first
  layer (nothing under it to sauce) — enforced client-side (the applicator only engages over
  a stack with ≥1 existing part). Condiments now HAVE an admin-panel editor (admin Menu tab →
  New Condiment; `CondimentFields` edits item/container_model/applied_model + ingredient cost),
  fed by `AnnotateCondiments()` and saved whole via `admin:saveSettings`, like finishes.

## Eat-in vs takeaway (the two vessels + eating)

Food leaves the kitchen two ways, and BOTH are multi-item vessels whose contents
ride as build-stack metadata:

- **Serving tray → `meal_item` (EAT-IN).** Unchanged in the kitchen. It can only be
  eaten while SEATED on a placed seat anchor: using it opens `modules/dining`, an
  interactive in-world view (the kiosk/register pattern) that lays the real tray out
  on the table in front of the diner, frames a scripted camera, hovers/outlines each
  pile with a tooltip, and eats the pile you click. The ped keeps its sit loop
  throughout. The layout is rendered by the KITCHEN's own machinery —
  `SpawnMealRender`/`DeleteMealRender`/`MealRenderPileAnchor`/`MealRenderPileIndices`/
  `OutlineMealPile` at the bottom of `modules/cooking/client.lua`, which run the prep
  renderer against an external anchor (`extAnchor`) instead of a station — so a meal
  on a diner's table is identical to the one the cook built. TUNE IN-GAME: `DINE` in
  `modules/dining/client.lua`.
- **Restaurant Bag → `bag_item` (TAKEAWAY).** The tray's sibling at prep: drop
  finished foods/drinks in, "Bag It Up", and `prepMakeBag` records one meta layer per
  pile. Usable anywhere: `modules/consume` opens an **ox_lib context menu** of the
  contents, eating one removes that layer, and the bag itself disappears when the last
  one goes.

**A bag SUPPLIES an order exactly like a meal.** Both are "packed vessels" in the POS:
`VesselItem`/`VesselItems` in `modules/sales/server.lua` name the pair, `PlanFulfillment
(rid, order, sig, vesselItem)` lets one of them cover required units (`mealCovers`, exact
variation match) with the rest coming from the pool as singles, and `AnnotateOrders`
offers meals AND bags in one `mealOptions` list — each option carrying `item` (which one
to consume) and `bag`. The wire field is still `mealSig`, now paired with `mealItem`;
`VesselItem` rejects anything that isn't the meal or bag item, so a forged payload can
never hand over an arbitrary item.
- **Takeout box → `box_item` (`pickle_takeout_box_01` + `_02`).** Where every
  `kind = "bag"` FOOD (soup, salad — the non-stack miscellaneous foods) is now
  created; the bag used to be that vessel. Mechanically the pizza box's twin (`TAKEP`
  ≡ `BOXP`: `LidCfg(kind)` returns either, and the seat/swing/close-before-make maths
  are shared) but it accepts loose food like a tray. `prepMakeBox` matches the
  contents against the food catalogue (`bestCraftForLayers`) and trays ONE `box_item`
  with the food id on its first meta layer — the SAME `craft` flag, so `TraySig`'s
  `~id` grammar and the POS `c:` variant key are byte-stable across the rename.
  A one-time `takeout_box_migrated` backfill re-keys held bag instances; a legacy
  `restaurant_bag` carrying a `craft` flag still READS as a box everywhere
  (`boxFoodId`), since player inventory slots can't be migrated.

A made takeout box renders as base + open lid + the food's **image on a textured
quad** (`modules/quad`): a DUI (`html/quad.html`) per distinct image + shape, pooled
and ref-counted, drawn with `DrawSpritePoly` from the entity matrix so it follows the
box everywhere. That's how a food with no prop of its own (a soup) is visible at all.

The quad HONOURS THE CROP: `FoodBoxImageUrl` returns url + the admin's normalised
source rect, which rides through `spec.imageCrop` → `part.quadCrop` → `QuadAttach`'s
`crop` → the DUI's query string, and `html/quad.html` draws exactly that rect across
the surface (with a `cover` fallback when there is none) — the same contract
`html/brand.html` honours. A page that merely CSS-`contain`s the image ignores the
crop and letterboxes anything whose natural shape differs; that was the bug. The
texture pool key is `url|aspect|crop`, since all three change what's painted.
(NUI thumbnails still render `object-cover` on purpose — the crop matters where the
image is drawn at the crop's own ratio: brand textures, the boards, the box quad.)

**The quad's rectangle is `Config.BoxQuad`** (`{ w, h, dz }` in metres of the box's
local space, in `core/shared.lua`) — EMBEDDED config, deliberately not a settings row:
it's a property of the shipped box mesh, tuned once, not a per-install knob. It sits in
`shared` rather than the cooking client so all three readers get the same numbers: the
drawn quad, the DUI **surface aspect** (built at `w:h` by `surfaceSize`, so the art maps
1:1 instead of being squashed onto a square texture — the pool key is `url|aspect|crop`
for the same reason), and the admin panel's "Inside the box" cropper, which the server
feeds READ-ONLY as `boxQuad` in `buildAdminData` (`BOX_PHOTO(quad)`) so a crop lands in
the box exactly as it was dragged. Nothing in the panel writes it back. Do not
re-introduce a second copy of these numbers in `TAKEP` or as a setting.
TUNE IN-GAME: `DRAW_DIST`/`MAX_TEXTURES` in `modules/quad/client.lua`.

**A food authors its own identity and effect — it never borrows an inventory item's.**
Two fields on every authored food (both optional, edited in the Menu tab):
- `image` = `{ url, crop }`, the food's OWN picture AS AN ITEM — the kitchen bar card,
  the POS, a bag's contents menu, the inventory slot, the admin row thumbnail.
  `FoodImageUrl(food, item)` resolves it, falling back to the LEGACY `display_item`'s
  art (the field the bag-food editor used to offer; still read, no longer written) and
  then to the item's own.
- `box_image` = the picture painted on the quad INSIDE an open takeout box, for when
  the card art doesn't work lying in a box. `FoodBoxImageUrl` falls back to `image`.
  Bag-kind foods only. `boxFoodRender(cr)` returns `label, itemImage, boxImage` — keep
  the two straight: the tray entry's `image` is the card, its `quad` is the box.

Any CONTENTS LIST (a meal's or bag's parts on a tray card, an inventory slot
description, the bag's eat menu, the POS vessel picker) groups by `layerIdentity(l)`,
not by item name: a generic vessel item is only told apart by what it holds, so a
takeout box counts and reads as its FOOD (`craft:<id>`, the food's label + art) and a
drink as its flavor. Grouping by item name would collapse a soup and a salad into two
indistinguishable "Takeout Box" rows.
- `consume` = `{ hunger, thirst, anim }` — what eating ONE serving restores (0-100
  percentages of the framework's bars) and which `consume_anims` entry plays.
  `ConsumeSpecFor(item, meta)` resolves it, filling gaps from the global `consume`
  setting; an un-authored DRINK is special-cased to thirst + a drinking clip so an
  upgraded config doesn't feed the wrong bar. A one-time `food_consume_seeded` backfill
  copies the shipped values onto matching stored foods (merge() only adds whole missing
  entries, never fields).

`consume_anims` (settings, seeded internally, edited in Settings → Eating) is the
animation catalogue: `{ id, label, dict, clip, prop, ms }`. The server resolves a
food's pick into the FULL clip spec and returns it with the eat response, so the client
holds no catalogue and an admin's retune applies immediately.

**A food's identity is its LABEL.** `SanitizeFoods` derives `id` from an explicit id →
the final step's output/flavor → the label slug (`foodSlug`), and an id-less food is
dropped on save. That last fallback is what a bag-kind food relies on now that it no
longer borrows an inventory item's name (`display_item`), and what lets a half-built
recipe survive being saved before its outputs are typed.

**Nothing is made from nothing.** Every food has to CONSUME something — components to
combine, an input to cook, a cup to pour. `RebuildDerived` refuses to derive a
component-less craft/assembly or an input-less pour (a component-less assembly would
satisfy `stackSatisfies` trivially, i.e. be buildable from an empty table), and
`AnnotateFoods` flags the offending part as `no_input` so the admin row says which step
is empty rather than the entry being silently inert in-game.

`FoodForItem(item, meta)` is what maps a held thing back to its authoring food:
`DerivedFoodById` (a takeout box's food id, a drink's flavor key) + `DerivedFoodByOutput`
(every terminal cook/assemble/pour output), both rebuilt in `RebuildDerived`.

**Item use** has no single cross-framework hook: ESX/QB take a per-name callback
(`RegisterUsableItem`, re-registered on a `bag_item`/`meal_item` rename via the
`pickle_restaurants:settingChanged` event), while ox_inventory calls the
`pickle_restaurants.useItem` **export** named in the item definition — so the bag and
meal ship as `stack = false, consume = 0` in `__INSTALL/items/`, and this resource
(never ox) decides when the vessel is destroyed. Eating tops up the framework's needs
via the bridge's `Nourish(source, hunger, thirst)` (0-100 percentages, scaled per
framework: esx_status ×10,000, QB metadata + HUD event, standalone none). Every
variant also fires `pickle_restaurants:nourish(source, hunger, thirst)`, so a server
running its own needs system hooks that instead of editing the bridge.

## One-item consolidation rule

Variants NEVER multiply items — they collapse into ONE item with the variation in
build-stack metadata: all doughnuts are `cooked_doughnut` (frosting/sprinkles =
finish meta), all drinks are the `drink_item` item (flavor meta), all meals the
`meal_item` item (layout meta, `^box` for pizza boxes), every bag-kind food the
`box_item` (food id meta) and every takeaway the `bag_item` (contents meta).
Assembled-but-uncooked
INTERMEDIATES (an assembly output that is some recipe's input, e.g. `raw_pizza`)
are tray-only — never exported by itemgen (grace-retained one release in `RETAIN`),
never required by sync/annotate validation (`assemblyMissing`/BuildSyncPayload skip
the output). An assembled input placed to cook with no readable recorded stack gets
its BASE recipe meta SYNTHESIZED at `place` so the cooked product never comes out
stackless (getTray/compSpec also fall back to the base stack for legacy stackless
instances). Follow this pattern for any new food family.

## Stack-height corrections

`STACK_TWEAKS` in `modules/cooking/client.lua` holds per-model MANUAL stacking
corrections (`sink` = shift a layer's seat, dragging everything above it along;
`rise` = replace the measured layer height). The measured model heights are always
the baseline — only add an entry when a specific prop needs a nudge (the pizza
cheese sheet ships with a small sink). Applied in `expandStackLayers` (product
towers, oven slots, previews) and `layoutParts` (discrete prep parts). TUNE IN-GAME.

## Localization

`locales/locale.lua` defines `_L(key, ...)` (string.format-style) reading
`Language[Config.Language]`. Strings live in `locales/translations/*.lua` (currently
`en.lua`). Use `_L(...)` for user-facing server text.

## Memory / house rule

Never add a `config.lua` to this resource — configuration is DB + in-game only. See
`memory/no-config-lua-design.md`.
</content>
</invoke>
