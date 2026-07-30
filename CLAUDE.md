# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`pickle_restaurants` is a FiveM (FXServer, `fx_version 'cerulean'`, Lua 5.4) resource
implementing a fully in-game-configurable restaurant/cooking job. Servers create and
configure restaurants, props, recipes, menus and staff ranks entirely from an in-game
admin panel — **there is intentionally no `config.lua`**. (WHO works where is the one
thing this resource does not own: a restaurant is staffed by a framework JOB, so hiring
happens in the boss panel but lands in the framework. See "Jobs, ranks & permissions".) All gameplay configuration
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
runs `CreateTables()` (all `CREATE TABLE IF NOT EXISTS`), seeds default settings and
recipes, then loads everything into module-global
caches and sets `RestaurantsReady`. Tables are prefixed `pickle_restaurant*`.

**Caches (server, module-global, defined at the top of `core/server.lua`):**
`RestaurantCache`, `PropCache`, `RecipeCache`/`RecipeByInput`, `StockCache`, `TrayCache`,
`SettingsCache`, `TipCache` (the unpaid tip pool's running sum). (`EmployeeCache` went with
the employee model — employment is the framework's job now; a booking's held seats and
guests are cached by `modules/phone` on the booking row, deliberately not a second time
here.) Mutators (`AddStock`, `AddTray`,
`AdjustBalance`, `SetSetting`, …) write-through to both the cache and MySQL. Read the
cache; never re-query for data already cached.

**Client sync:** the client sends `pickle_restaurants:requestSync`; the server refreshes
the inventory catalogue and replies with `pickle_restaurants:setupInventory` (item list)
+ `pickle_restaurants:sync` (`BuildSyncPayload`). **Only valid configs are synced to the
world** — a recipe/drink/assembly referencing an item missing from the inventory
catalogue is filtered out of the payload (but still shown, flagged, in the admin panel so
it can be fixed). After any config change, server code calls `SyncToClient(-1)`.

**No migrations. The schema is DECLARED.** Every column a module needs is in that
table's one `CREATE TABLE IF NOT EXISTS` in `CreateTables()` — including the columns the
phone app owns on `pickle_restaurant_orders`. There are deliberately NO `ALTER TABLE` /
`SHOW COLUMNS` guards and no one-time data backfills gated behind a
`pickle_restaurant_settings` flag: those were stripped for the v1 release, so a new column
goes in the CREATE and nowhere else. Default settings/recipes are still merged in
idempotently on boot (missing keys only — never clobbering admin customisations), and the
shipped product art is seeded once into `item_images` — those are SEEDS, not migrations.

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
  point + heading + STYLE (placed with a ghost-ped gizmo preview, `saveSeat`; the
  style is asked for BEFORE the gizmo opens, since it decides the ghost's pose).
  A seat is placed in THREE gizmo passes: the seated ghost, a standing ghost for
  `metadata.exit` (where the player is put down when they stand), and the real
  serving-tray prop for `metadata.tray` (where a meal is laid out — read by
  `modules/dining`, which otherwise probes for a surface and can only find whatever
  geometry happens to be under the diner's reach). Both extra points are OPTIONAL:
  cancelling a pass means "not placed" and each consumer falls back. Because editing
  a seat always re-asks, a cancelled edit CLEARS that point — the only way to take
  one back off.
- `seating` — players sit on the placed seat anchors. `seating:sit` is the **ONE door**: it
  tracks per-anchor occupancy so two players can't share one seat, AND it enforces
  **reserved-seat access** — an anchor held by an active reservation admits only the holder
  and that reservation's granted guests, and answers everyone else
  `{ ok = false, reserved = true }`. Anything new that seats a player goes through that
  callback rather than growing its own copy of the rule. On a `reserved` refusal the client
  offers "Ask to sit here" (`seating:requestSeat`) — the server pages the HOLDER with both a
  phone notification and an ox_lib prompt (one request in flight per asker, expiring after
  60s; holder offline = `seat_holder_away`), and an accept adds the asker as a guest of the
  RESERVATION, so all of its seats. A revoked guest already sitting is deliberately NOT
  stood up: the gate is checked on sit, and standing a player up from another player's phone
  is a grief vector — they simply can't sit back down. See "Reserved seats".
  `main`'s `SpawnProp` gives a
  `seat` prop a "Sit" interaction (no world prop) → `SitOnSeat`; `E` sits and **ESC
  stands up** (`STAND_KEYS` — the same step-out set `modules/interactive` uses,
  read with the `Disabled*` variants + the frontend shove so the press can't also
  open the pause menu; `EnableInteraction` is toggled off while seated). ONE key
  backs out of everything, innermost first: while the eat-in meal is laid out the
  view owns ESC (the seat loop doesn't read it at all while `NUIView ~= "none"`, or
  one press would both close the meal and stand the diner up), and the help prompt
  names whichever the next press does (`seat_meal_prompt` / `seat_stand_prompt`,
  which draw the key as the `~INPUT_FRONTEND_PAUSE_ALTERNATE~` glyph — control 200,
  the input that MEANS Esc and one of `STAND_KEYS`, so the glyph follows a rebind.
  NOT 322, which is `INPUT_REPLAY_TOGGLE_TIMELINE` and merely sits on Esc).
  **Neither works mid-mouthful** — `IsConsuming()` (`modules/consume`) /
  `IsMealBusy()` (`modules/dining`): the bite is already committed server-side, so
  cancelling would put the vessel away with the food gone and leave the ped eating
  in the middle of the room. The dining page therefore has NO bottom hint line;
  the seated prompt is the one place that instruction lives. Server tracks per-anchor
  occupancy so two players can't share one seat.
  **A player sits EXACTLY on the anchor — nothing else gets a vote.** We
  `SetEntityCoords` + `FreezeEntityPosition` and play a looping clip. The freeze is
  the point, not a workaround: a frozen ped is skipped by the collision
  depenetration pass, which is what shoves a warped ped up out of an MLO chair's
  mesh. **SCENARIOS WERE TRIED AND REVERTED** — do not go back:
  `TaskStartScenarioAtPosition` decides for itself where to put the ped (players
  ended up through the floor), and the natives that report whether a ped is in a
  scenario are unreliable enough that a repair tick re-tasked forever, i.e. an
  endless sit-down loop. Movement CONTROLS are disabled while seated (the freeze
  holds position; this stops a held key walking them off on standing), the pose
  repair is rate-limited to 1s and gated on a `settled` flag — re-tasking per frame
  IS the loop bug — and `StandUp` uses `ClearPedTasks`, never `...Immediately`.
  Posture is per-seat: `Config.SeatStyles` (`core/shared.lua`) is the catalogue
  (`id`, locale-key `label`, `anim`, height trim `dz`), an anchor records its choice
  in `metadata.style`, and `GetSeatStyle(id)` never returns nil. The placement ghost
  and the real sit play the SAME clip at the SAME point (`SeatPreviewAnim` /
  `SeatSitOffsetZ`) — that identity is what makes placement WYSIWYG, so never let
  the two diverge. `saveSeat`/`updateProp` re-validate the submitted id.
  `StandUp` puts the player down on the seat's `metadata.exit` when it has one — a
  seat anchor sits ON the furniture, so standing up where you sat lands a booth or
  bar diner on the table. No exit point = stand in place (an open-floor chair).
  **The admin hover-highlight for a seat is DRAWN (`DrawMarker`), never a spawned
  ghost ped** — a ped preview crashed the client, because hovering a list of seat
  chips creates and deletes a ped per mouse-over and peds don't survive that churn
  (`ANCHOR_HL` in `modules/main/client.lua`; the spawn path is objects-only now).
  Player-only for now; NPCs sitting to be served would be a larger phase-2.
  TUNE IN-GAME: `Config.SeatStyles`.
- `doorstep` — the NPC-delivery HAND-OFF. A `delivery_door` prop (an invisible
  admin-placed anchor: point + heading facing OUT of the doorway, placed from the
  admin panel's Delivery doors card) is where `npc_customers` sends a delivery when
  the restaurant has any placed — otherwise it falls back to the old random-bearing
  point, so this is additive. Arriving doesn't complete the ticket: the phone's
  "delivered" action is NOT a plain relay (`modules/phone/client.lua`) — it runs
  `RunDoorstepHandoff` first (knock → step back → a LOCAL resident ped walks out of
  the doorway → the `mp_common givetake1_a/_b` exchange pair) and only then calls
  `sales:completeOrder`. Return contract: nil = no door, complete normally; false =
  there was one and the scene didn't happen (too far / interrupted), leave it open;
  true = go. **The scene is NETWORKED** — the resident and the branded bag are real
  networked entities, because client-local ones (what this shipped with) made a delivery
  look to everyone else like a man miming at a door. The hazard the local version avoided
  is real, so it is answered rather than accepted: a networked entity outlives the client
  that spawned it, so both net ids are reported to `doorstep/server.lua`
  (`doorstep:sceneEntities`) the moment they exist, and it deletes them on
  `playerDropped` or a deadline if the driver crashes mid-scene. Normal endings clean up
  client-side first (and `onResourceStop` too — a restart is the one ending neither of
  the scene's own paths reaches); `sceneDone` releases the server's hold. Deleting an
  already-deleted entity is a no-op, so the two racing is harmless.
  `doorstep:point` grants nothing; it only answers where the door is, for the
  assigned driver of that open delivery. The scene's timings are the `DOOR` table
  in `modules/doorstep/client.lua` (TUNE IN-GAME).
  **The door carries the action itself, so a delivery is served without opening the
  phone**: accepting a run ARMS a target option on that door (`ArmDoorstepTarget`,
  called from `beginDriving`; it returns the point, which is also where the nav
  marker's z comes from) and every ending disarms it (`EndDriveGen` → 
  `DisarmDoorstepTarget`). Armed per RUN, never per placed prop — a standing option on
  every invisible door would put a prompt on strangers' doorsteps for an order they
  don't hold. Both entry points call ONE function, `ServeDelivery` (modules/phone) =
  scene + `sales:completeOrder`; the door path passes no `mealSig`/`mealItem` (it has
  no ticket on screen to read one off, and the pin is only ever a hint).
  The scene CLOSES THE PHONE first (`PhoneApp.Close()`, defined per phone bridge —
  lb-phone's `ToggleOpen(false)`, candidate exports + a close event elsewhere via
  `PhoneCloseVia`): served from the app the phone is open and in the ped's hand, and
  its put-away animation fights every clip in the hand-off.
- `management` / `admin` — the boss/owner and admin panels. **Employment is the
  FRAMEWORK'S JOB, not a table of ours** — see "Jobs, ranks & permissions". The admin
  panel assigns each restaurant its job (`admin:setJob`; a restaurant REQUIRES one), and
  the boss panel holds the job roster (hire/fire/promote by grade), the **Ranks** editor
  (per-grade permissions + commission + salary, boss-gated) and **Payroll** (pay the tip
  pool out, run the wage bill, payslip history), plus the menu/supplies/finances/branding
  tabs it always had. The management payload ships `job` / `jobMissing`, the framework's
  `roster`, a per-grade `ranks` ARRAY (sorted; never a 0-based numeric map, which
  `json.encode` can't be trusted with), `tipPool`, the payslip history, and the
  `PERMISSIONS` array ITSELF — the rank editor renders that rather than a copy, so a new
  permission key appears in the panel the moment it appears in core. `setRank`'s reply
  carries the sanitized array and its relay deliberately does NOT refresh the panel (an
  auto-saving editor must not remount mid-typing), so `Management.tsx` mirrors the array
  and the Payroll tab prices the next run off live numbers. A restaurant with
  `jobMissing` says so prominently and disables all three tabs: a hire form that can
  only fail is worse than none, and the fix is an admin's.
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
consumed by `Branding.tsx` — NO more hardcoded `BRAND_TEXTURES`. Tune these numbers in `Config.RenderTargets` itself — a 90/270 turn changes the
derived surface, so the DUI is rebuilt from it.

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
  scripted camera on the screen, and **hides the player ped for the duration —
  `SetLocalPedHidden` (`modules/interactive`), NEVER `SetEntityVisible`**. Hiding your own
  body is a statement about YOUR shot, but `SetEntityVisible` on a player ped propagates:
  the whole server watched the cashier vanish from behind the counter. The native that is
  actually local is `SetEntityLocallyInvisible` ("not visible for yourself"), which lasts
  ONE FRAME — so the helper owns a re-assert loop and one flag, and every view (station
  camera, kiosk, register) goes through it rather than reaching for either native. A VIRTUAL CURSOR (mouse-look deltas →
  `SendDuiMouseMove` at the surface pixel) drives the page; CEF renders its OWN cursor
  onto the surface (never a world-drawn sprite — that lives in a different projection and
  clicks would miss it). The order still becomes a normal ticket (`sales:kioskOrder`).
  Camera framing / cursor speed / DUI aspect are `KIOSK` tunables (TUNE IN-GAME).
  **AN EXIT HINT IS DRAWN PER FRAME AND CLEARED ON CLOSE** (`helpThisFrame` +
  `ClearAllHelpMessages()` in both `kiosk` and `register`). A GTA help bubble lives
  ~7s of its own accord, so the old "re-arm once the last one expired" guard left the
  hint on screen for seconds after the player had walked away from the kiosk. The
  guard existed to stop the BEEP repeating — so the beep is now first-frame only
  (`not helpBeeped`), which is the actual fix. `modules/seating` / `modules/cookfx`
  already draw theirs per frame; match them.
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
  (from `ApplySync`) keep it bound/current. Camera/cursor tunables (TUNE IN-GAME);
  its resolution/orientation live in the shared render-target registry (below).
  A VIRTUAL register (`prop_type = "virtual_register"`) is an invisible anchor with no
  screen to paint — placed like a seat (`StartVirtualRegisterPlacement` → ghost-ball
  gizmo → `saveVirtualRegister`), it keeps the ordinary fullscreen NUI register
  (`OpenRegister`, `web/src/views/Register.tsx`). Both kinds share the `OrderBuilder`
  (its `big` prop selects the in-world layout) and the `Tickets` panel
  (`web/src/components/RegisterTickets.tsx`). Management stays a fullscreen NUI on both.
- `screens` — the customer-facing DUI boards (`html/screens.html`), same replacement
  trick as `rendertarget` but the page is DYNAMIC and fed live data each tick. One
  `SCREENS` entry per board (`txd`/`txn`/`w`/`h`/`rot`/`flip*`, TUNE IN-GAME):
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
- `cookfx` — the kitchen's PARTICLES and KITCHEN FIRES. The client half keeps no
  cooking state: each tick it asks `CookFxItems()` (bottom of `modules/cooking/
  client.lua`) what is on a station right now and reconciles live PTFX handles
  against it — steam on anything actively cooking (a grill face down, a basket
  lowered, a door shut), smoke on anything burnt. Every effect names its OWN
  `asset` in ONE `FX` table (TUNE IN-GAME), streamed per-effect on first use.
  The server half owns fires: it POLLS `BurntCookingItems()` (burnt food arrives
  and leaves through too many paths to hook each one), and food left burnt for
  `kitchen_fires.delay_seconds` sets its station alight.
  **The flame is a real `StartScriptFire`, not particles.** A ptfx casts no light,
  throws no heat and damages nobody, so a station "burning" as particles alone
  reads as a smoke machine — which is what it looked like before. Each client
  starts its OWN local script fire off the server's authoritative list (no fire
  netcode), re-lit every `FIRE.reignite_ms` because script fires burn themselves
  out, and removed on douse, on leaving range, and on `onResourceStop` — a fire
  left behind by a restart would keep burning with nothing able to put it out. The
  `FX.fire`/`FX.fireSmoke` particles layer on top of it.
  A burning station can't be USED, in both directions: `cooking:openStation`
  refuses it (the ONE door in, so no place/collect path needs its own check), and
  a station that ignites while someone is inside EJECTS them (`CookingStationId()`
  + `ForceStopCooking()` client-side, `ReleaseStationClaim()` server-side so the
  claim doesn't outlive them). Putting it out (G, `cookfx:extinguish`; requires the
  configured extinguisher item if it's installed, never consumed) destroys
  everything the station held. Settings live in `kitchen_fires` (Settings →
  Kitchen fires).
- `dlc` — the **DLC registry**. An add-on pack is its own resource that hands us a
  content table; its content is read out of THAT resource and **never written to our
  database**. Held in memory, overlaid on the three authored arrays at read time, and
  gone the moment the pack stops — nothing to migrate, nothing to clean up.
  See "DLC packs" below.

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

**Recipe groups match LOOSELY.** `RestaurantHasAccess` compares through
`NormalizeGroup` (trim + case-fold): group names are free text typed in one panel
and typed again on a food in another, so "Bakery" / "bakery" / "Bakery " is a
naming slip, not a distinction — and an exact match turns that slip into a
restaurant that silently can't cook anything.
Empty group list on a restaurant = access to everything (groups are an opt-in
restriction). `admin:setGroups` must `SyncToClient(-1)` — the synced payload is
group-filtered per restaurant, so without it the boards/kiosk/register/cooking bar
keep offering the old set.

### Jobs, ranks & permissions

**A restaurant is STAFFED BY A FRAMEWORK JOB.** `r.metadata.job` names it and
`r.metadata.ranks = { ["<grade>"] = { permissions, commission, salary, boss } }` says what
each GRADE of that job may do *at this restaurant*. There is no private employee roster
any more — hiring, firing and promoting are the framework's own job actions, so the two
can never drift apart. `pickle_restaurant_employees` is LEGACY: still declared (the schema
is declared, never migrated, and it is an upgrading server's only record of who used to
work where), never read or written. Do not add reads back.

**A restaurant REQUIRES a job.** With none assigned, nobody but an admin or the owner can
work there and every employment callback refuses (`mgmt_no_job`); the admin payload reports
`jobMissing` per restaurant and the management payload reports `job = nil` + `jobMissing`,
so a panel says why instead of offering a form that can only fail. An admin assigns it
(`admin:setJob` → `SetRestaurantJob`, which seeds a rank per grade: boss grades get
everything, the rest `default_rank_permissions`, and an already-authored rank is never
clobbered).

The framework is reached ONLY through the bridge job API, which every variant defines:
`JobsAvailable`, `GetJobList`, `GetJobGradeList`, `GetJobLabel`, `GetPlayerJobInfo`,
`SetPlayerJobGrade`, `IsJobBossGrade`, `GetJobEmployees(jobName, cb)` (cb ALWAYS fires —
`modules/management` blocks a panel open on it). ESX has no per-grade boss flag, so the
grade named `boss` (else the highest) is the heuristic. QB **and QBox** run through
`bridge/qb`: QBox ships as `qbx_core` with no `qb-core` resource but registers the
`qb-core` EXPORTS, so that bridge's guard accepts either and `bridge/custom`'s negative
guard is its exact mirror (both decide independently; custom loads first alphabetically and
cannot ask). On a frameworkless server WE are the job system — the `jobs` setting is the
job list (validated on read by `StandaloneJobs()`) and `pickle_restaurant_job_players` is
who holds what. Each bridge funnels its framework's own job event into ONE resource event
`pickle_restaurants:jobChanged(src)` (src nil = a job DEFINITION changed, so it applies to
every holder); core relays it to clients, since nothing is cached per player.

Server-side authority only. `ResolvePerms(restaurantId, source)` → `perms, isBoss, jobInfo`
is still the ONE authority: admin → owner → holds the restaurant's job (a boss grade, by
the framework's `isboss` OR the rank's own `boss`, gets `ALL_PERMS`; otherwise the rank's
permissions) → nothing. `isBoss` means "holds everything here". The 3rd return is the
player's JOB INFO (nil for an admin/owner who doesn't hold the job) — it used to be an
employee row, and consumers now read `.grade` off it rather than a per-person rate. DUTY is
deliberately NOT consulted: plenty of servers never toggle it, and a restaurant nobody can
work because a flag defaults to off is indistinguishable from broken. Core helpers:
`RestaurantJob`, `SetRestaurantJob`, `RestaurantRanks` (complete: framework grades ∪
authored ranks, keyed by grade NUMBER, stored under string keys because it lives in a JSON
column), `SetRestaurantRank`, `RankFor` (never nil — an undeclared grade still holds the
job, so it resolves to a basic employee, never a boss), `RestaurantRoster(rid, cb)` /
`RosterNow`. Gate every mutating callback with `HasPerm(...)` / `IsPlayerAdmin(...)` — the
NUI is untrusted. `PERMISSIONS` gained **`manage_payroll`** (paying the pool out and
running the wage bill), which a boss holds implicitly through `ALL_PERMS`.

**Pay is per RANK, never per person** (`management:setRank`, boss-gated): everyone on a
grade shares its `commission` and `salary`. `management:setCommission`, the per-employee
`commission_rate` column and Settings → Roles (`default_roles`) are all GONE — the boss
panel's Ranks tab replaces them. Hire/fire/setGrade validate the grade against the job's
REAL ladder and first check the target actually holds THIS restaurant's job (without that,
the callback could be pointed at any player in the server and strip an unrelated job);
hiring onto, promoting into or dismissing out of a boss grade is boss-only, because
`manage_employees` moves staff and must not be a route to handing out every permission.

Settings → Roles is gone with `default_roles`. What remains SERVER-WIDE is Settings →
Jobs (the standalone job list + the `default_rank_permissions` a fresh non-boss grade is
seeded with) and Settings → Reservations (`reservation_slots`, `reservation_hold_minutes`),
alongside Economy's `payroll_interval_minutes` and `tip_split`. `jobs`, `reservation_slots`
and `tip_split` are sanitized on the way in (`PLAIN_SANITIZERS` in `modules/admin/server.lua`
— sanitized but NOT menu content, so writing one doesn't drag `RebuildDerived()` along):
with no framework installed the job list IS the job system, a malformed slot id would create
a hold that never starts and never expires, and `tip_split` is an enum PayTips branches on.

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
- **THE BALANCE IS THE JOB'S SOCIETY ACCOUNT. We host no money.** There is no
  `balance` of ours to drift from the boss menu the rest of the server already uses:
  buying stock, banking a sale and paying wages all move the same dollars a job's own
  banking UI shows. `bridge/society/server.lua` is the ONE definition of that API
  (`SocietyAvailable`, `SocietyProvider`, `GetSocietyBalance`, `AddSocietyMoney`,
  `RemoveSocietyMoney`, `EnsureSocietyAccount`) and it is **probed BY PROVIDER, not by
  framework** — Renewed-Banking `provide`s both `qb-management` AND `esx_society`, so
  "ESX ⇒ addon accounts" is simply wrong on a server running it. Preference order:
  Renewed-Banking → qb-management → qb-banking → esx_addonaccount → our own table. The
  framework bridges deliberately define NONE of it (two definitions of
  `AddSocietyMoney` would be a load-order coin toss), and the probe is re-run on any
  resource start/stop so a bank that boots after us is picked up.
  `pickle_restaurants.balance` is DEAD: declared, never read, never written.
- **`RestaurantBalance(rid)` reads; `AdjustBalance(rid, delta)` moves and RETURNS
  WHETHER IT MOVED.** The account is shared with the rest of the server, so it can
  change between a read and a write — which makes the DEBIT the authority, never the
  pre-read. Every spend path now gates on it: stock is only granted if the money left,
  a withdrawal only pays out if the account gave it up, a deposit banks the cash BEFORE
  taking it off the player (a failure must cost them nothing), and a payroll run debits
  the whole wage bill first and pays nobody if that fails. No job ⇒ no account ⇒ no
  movement, logged loudly rather than dropped on the floor.
  `starting_balance` is applied when a job is ASSIGNED (an account only exists then) and
  only into an empty account, so re-assigning a job can't top a working business back up.
  A society account can't go negative, so a refund the business can't cover pays the
  customer anyway and leaves the ledger to show it — the customer is owed either way.
- **We are the bank only when there is no bank.** With no banking resource at all, the
  fallback provider uses `pickle_restaurant_society` (keyed by JOB — two restaurants on
  one job share their books, as a society account does everywhere else), and its
  withdrawal is ONE conditional UPDATE (`WHERE amount >= ?`) so two concurrent sales
  can't read-then-write the same total or overdraw it. Same reasoning as the standalone
  job store: the feature works frameworkless without pretending to be a bank on a server
  that has one.
- **A TIP IS STAFF MONEY, NOT HOUSE MONEY.** Tips used to be added to the restaurant
  balance, which quietly made every gratuity the owner's. They now land in
  `pickle_restaurant_tips` as unpaid rows and never touch the balance in either direction:
  `AddTip(rid, amount, identifier, source)`, the pool is `TipPool(rid)` (the unpaid rows
  are the truth; `TipCache` is the running sum), and `PayTips(rid)` splits it across the
  current roster per the `tip_split` setting (`"even"` | `"grade"`, weight = grade + 1 so a
  trainee still earns a share), CLAIMING the pool before any payout exactly as
  `RefundOrder` does. The rounding remainder goes to the first recipient — the pool is
  emptied, so every cent has to land somewhere.
- **Salaries DO come out of the balance, all or nothing.** `RunPayroll(rid)` pays each
  roster member their rank's `salary`, writes one `pickle_restaurant_payroll` row per
  recipient (`kind = "salary"`; tips write `"tips"`) plus ONE ledger line, and refuses the
  whole run when the balance can't cover the total (`payroll_insufficient`) — paying three
  of five staff is the failure a boss can't unpick. `payroll_interval_minutes > 0` runs it
  on a cadence from one core thread; every skip is silent, because "nobody owed" and "funds
  short" are ordinary states. Both paths pay ONLINE staff only: the one deferral mechanism
  here (pending refunds) exists so a CUSTOMER never loses money they already spent, and a
  wage nobody was present to earn is better caught by the next run than parked forever.
  Both return `(paid, recipientRows, errKey)` — the refusal is the THIRD value and the
  second is rows, not a count; `PAYOUT_ERRORS` in `modules/management/server.lua` maps each
  key to the boss-facing string, because the engine has no business wording a refusal.
- Commission is per RANK (`RankFor(rid, grade).commission`), not per employee row; an
  admin/owner with no job earns 0, as before. **It is NOT paid when the cashier is also
  the customer**: ringing up your own $8 burger charged $8, printed a receipt and handed
  back $1 (10%, rounded), which reads exactly like the POS giving change it has no
  business giving — and becomes a faucet once a rank's rate passes the rounding
  threshold. `payCommission` takes the ticket's customer identifier and skips itself on a
  match; commission is a cut for SERVING SOMEONE, and there is no service in a
  self-purchase.
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
  `meal`, is what gets *generated*; only `trayToInventory` requires it installed) places `pickle_tray_01` + `pickle_tray_paper_01` on the table. Food dropped over the tray anchors where it lands on the paper (clamped
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
- **A FINISH's render replaces the container stack.** `getTray` builds a containered
  bake's stack (`{ tin, cake_sheet }`) BEFORE it applies a finish, and a stack always beats
  a model client-side — so a frosted cake dragged out of the tray still rendered as a plain
  sheet sitting in its tin. Replace-mode now clears `stack`/`stackState` when it sets the
  flavor model: a decorated cake is a whole cake and it is out of the tin (applying the
  finish deletes both those props), so the flavor model is the ENTIRE render. Both stores
  do it — the tray branch and the inventory branch (see "Both of `getTray`'s stores must
  describe a vessel the SAME way"). `compSpec` was always right because it resolves the
  finish FIRST and returns early.
- **Cursor hit-testing goes through an item's MIDDLE.** These models are bottom-origin, so
  projecting an entity's own coords targets the FLOOR of it — fine for a flat patty, wrong
  for anything tall: a fountain cup only answered the cursor at its base while the body of
  it read as empty space. The station hover loop projects `coords.z + hoverHalfHeight(ent)`
  (memoized in a closure — that file is at Lua's 200-local ceiling, which is why its
  helpers are globals); the chip anchor deliberately keeps the origin projection. Same
  reasoning as `MealRenderPileSpan` in the dining view. A station's INTERACTION zone has
  the matching per-type lift (`STATION_TARGET_Z` in `modules/main/client.lua`): the soda
  fountain's whole working face is a metre up, so a zone at its feet read as "too far"
  while you stood at the nozzles.
- **Containered bakes.** A recipe's nullable `container_model` column (cake tin
  `pickle_cake_container_01`, future cookie trays) renders the food inside a container
  prop EVERYWHERE — oven slot, drag preview, prep table — by prepending it to the
  existing build-stack machinery (`it.stack`/`stackBase` in `place`; `withContainer`
  in `getTray`); only the `stackBase` layer swaps models as it cooks. The container is
  visual-only, never an item. NOTE: `pickle_cake_01..04` are the four flavored WHOLE
  cakes (strawberry/chocolate/vanilla/pickle), NOT cook states — the batter sheet
  bakes as `pickle_cake_mix_pour_02/03/04` (raw/cooked/burnt; best-guess mapping,
  correctable in the recipe editor).
- **Soda machine (drinks).** The fountain has SEVEN taps: the middle one dispenses
  ice, the other six map to the first six `drinks` settings entries by RAW config
  position (tap N = entry N — STABLE even when some flavors are invalid; a missing
  CUP item leaves its tap dark. Only `drinks[].input` must be an installed item:
  `output` is a flavor KEY, not an item — every poured drink collects as the ONE
  `drink_item` setting's item ("Restaurant Drink", default `drink`, mirroring
  `meal_item`) with the flavor riding as build-stack metadata
  (`{ { item = <output key> } }`, TraySig'd so each flavor is its own variation);
  `drinkFlavor`/`drinkRender` resolve the label + capped cup+lid render everywhere
  (getTray both paths, compSpec for drink layers in meals). BuildSyncPayload stamps
  each synced drink with its `tap` index so the client mirrors the server's
  `flavorForSlot` exactly; the model's printed flavor strip matches the default
  order). Cups are slot items
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
  by output covers a config with no colour set) —
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
  entries (`BuildSyncPayload` → client `Finishes` global). A sprinkles tool is one more config row —
  no code. Finishes now HAVE a full admin-panel editor (admin Menu tab → New Finish;
  `FinishFields` in `web/src/components/editors.tsx` edits tool/tool_model/rub_dist/
  group/cost + a nested targets→flavors editor incl. per-flavor hex colour). Fed by
  `AnnotateFinishes()` in the admin payload; saved whole via `admin:saveSettings`.

- **Condiments (ketchup / mustard / mayo) — the `condiments` setting.** A squeeze-bottle
  applicator that lays a sauce LAYER on a build stack. Config is a list of
  `{ item, container_model, applied_model }` (each flavor's `container_01` holds the sauce,
  `applied_01` is what's left on the food — no separate sauce item). Sibling to the finish
  tools in wiring (synced as the client `Condiments` global via `BuildSyncPayload`; a
  `kind = "condiment"` applicator card in `getIngredients`; `ingredient_costs` prices it) but DIFFERENT in effect: a finish consumes a FINISHED
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

## Reserved seats

A reservation is **ACCESS CONTROL over real seat anchors for one timeslot** — never an
instance and never a private room. Booking used to put the party in a routing bucket
(`6000 + id`) and teleport them into a single global "dining booth". That is gone, and with
it the `playerDropped` handler that reset the dropping player's bucket to 0 and in doing so
CLOBBERED every other resource's bucket assignment (jails, apartments, instanced jobs).

`phone:reserve` allocates N of the restaurant's own placed seat anchors and records them in
`pickle_restaurant_reservation_seats`; who else may share them lives in
`pickle_restaurant_reservation_guests`, granted per RESERVATION because a party that has
been let in is let in. **`modules/phone` owns both tables and the cache**: the cached row
(`ReservationCache[rid][id]`) carries `seats` (prop ids) and `guests`, and that cache — not
the tables — is what the sit gate, the `reservedSeats` sync map and the phone screens read.
Core deliberately keeps NO second cache of the same rows (it briefly did; two caches over
two tables is not a speed-up, it is a second truth): what core owns is the part that needs
no row at all — the slot vocabulary, the hold window, whether a row is live, and the sweep.
The phone's side is `ReservationForSeat(propId)`, `ReservationAdmits(res, ident)`,
`ReservationAddGuest`, `ReleaseReservation(res)`, `ReservedSeatMap(rid)`.

**ONE active reservation per person, anywhere.** More seats in the SAME slot at the SAME
restaurant EXTEND it (`party` is the desired TOTAL, 1..12); a different slot or restaurant is
refused. That is what "many seats, one timeslot" means in practice. The slot must be a
canonical id from the `reservation_slots` setting (`ReservationSlots()` validates on read:
`"now"` or `HH:MM`, and `"now"` always survives an emptied list) — it used to accept any
string ≤20 chars, so a hand-made payload could book a slot no capacity check and no expiry
would ever match. A hold runs from its slot time today for `reservation_hold_minutes`;
`ReservationActive(row)` decides. A **one-minute sweep** in core marks lapsed rows `expired`
and frees them through `ReleaseReservation` — the same path a cancellation takes, because an
expiry IS a cancellation the clock performed, and two ways to end a booking is how one of
them forgets the guest rows. Nothing else ends a booking: without the sweep one `"now"`
booking would hold a table until the next restart. `LoadReservations` additionally prunes
seat/guest rows orphaned by a crash.

`BuildClientRestaurant` carries `reservedSeats = { [propId] = true }` — holder-AGNOSTIC,
purely so the seat interaction reads "Reserved" instead of promising a chair the server will
refuse; whether THIS player may sit is still decided on `seating:sit`. The resolver lives in
the phone module, so core's call is guarded: core's first sync runs before that module has
loaded its bookings, and the sweep re-syncs once it can see them.

On the PHONE, the Reserve screen renders the server's canonical `slots[]` with `remaining`
straight off the payload — no client-side capacity arithmetic and no hardcoded slot array,
since a copy here could offer a time the server would refuse. The party stepper is a TOTAL
capped at `min(maxParty, remaining)`: `remaining` already excludes the caller's own held
seats, so adding them back would over-cap and hand the server a party it must reject.
`mine` is an OBJECT, not a list (one reservation per person), and a refusal says WHICH
mismatch it is. Guests are granted by SERVER ID through the CEF-safe `ask()` modal — a
customer's phone has no nearby-player list, and a server id is the only handle one player
can read off another. The phone's work screens follow the same job model as the panel
(Manage → Staff is the roster, Manage → Payroll pays tips and wages); rank PAY is editable
there but the permission MATRIX deliberately is not — a nine-checkbox grid per grade doesn't
fit a phone, so every phone-side `setRank` resends the rank's existing `permissions` so
editing a salary can never blank them.

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
  A mouthful BORROWS the seated ped: the eat/drink clip is a task, so it replaces
  the sit pose, which `modules/seating`'s repair loop cannot tell from a broken
  pose — it re-tasked the sit within `REPAIR_MS` and snapped the clip away, leaving
  the branded cup attached to a hand still in the diner's lap. `ConsumeAnim` now
  brackets every mouthful with `HoldSeatPose(true/false)` + `ReassertSeatPose()`
  (`modules/seating`), so the clip runs to the end and the pose comes back instantly
  instead of after the repair notices. The eaten pile is HIDDEN for the length of the
  clip (`SetMealPileVisible`) — the serving is in the diner's hand, so the copy on the
  tray has to go, or the same drink is in two places at once. Hidden, never deleted
  (a delete/respawn is the box-quad flash `RefreshMealView` avoids mid-serving), and
  `QuadSetVisible` (`modules/quad`) goes with it: a box's food picture is drawn from
  the entity matrix, so `SetEntityVisible` can't reach it.
  Eating one pile hands the view back to the GAMEPLAY camera for the mouthful
  (`stopCam()` before `ConsumeAnim`, re-framed by `RefreshMealView` after) — the
  tray camera looks down at the table, so eating under it frames food with the
  diner out of shot. `OpenMealView` also calls `RefreshBrands()`: packaging and
  cups are painted for the restaurant you are NEAREST, so a meal carried across
  town is eaten out of the local restaurant's branding, correct on the first frame.
  **A mouthful is eaten with the FOOD'S OWN PROPS, not the clip's.** An authored
  `consume_anims` entry carries whatever prop suited the clip, so every serving was
  eaten as a doughnut. `consume:eat` resolves `props` per mouthful: `LayerDisplay`
  answers for the things whose prop IS their identity (a drink's capped cup, a toy),
  and everything else goes through `LayerHeldProps` (`modules/cooking/server.lua`) —
  deliberately `compSpec`'s answer, the same resolver the kitchen and the diner's
  table render with, so the tower raised to a mouth is the one that stood on the
  tray (cook state, finish flavor, nested products, a side in its box). A MEAL PILE
  of several layers is rebuilt in the hand bottom-to-top. Only a layer that resolves
  to no prop at all falls back to the animation's own. A takeout box hands back its
  BASE only — its lid is a hinge-origin model and `attachHeldStack` stacks by
  measured height.
  A DRINK is drunk from the restaurant's own capped cup, not the animation
  catalogue's generic bottle: `LayerDisplay` returns the flavor's `drinkRender`
  (cup + lid) as `props`, and `ConsumeAnim`'s `attachHeldStack` puts the cup in the
  hand and the lid ON THE CUP ENTITY (never at a bigger bone offset — the hand
  frame is rotated, so a bone-space lid drifts off as the wrist turns). Branding
  needs no code: the cup's texture is a render target.
  **A held stack seats with the KITCHEN's maths, `HeldStackOffsets`** (bottom of the
  shared-prop primitives in `modules/cooking/client.lua`): `modelHeight`'s margin
  cancellation, the `STACK_MIN_GAP` floor, the model's `STACK_TWEAKS` sink and
  `layoutParts`' clamp. `attachHeldStack` measuring for itself is what floated the
  lid off the cup — `mx.z - mn.z` counts the physics box's ~0.04 collision margin
  twice (it dips below the origin by the same margin it overshoots the mesh top by,
  so the two only cancel when ADDED), a rounding error on a burger layer and a
  visible mistake on a drink.
  **WHICH HAND IS A PROPERTY OF THE CLIP, not of the food or the catalogue entry**
  (`HOLD` / `HOLD_BY_DICT` / `holdFor` in `modules/consume/client.lua`, keyed by
  DICT — an admin can rename an entry, but a dict's authored hand can't change). The
  DEFAULT is `PH_R_Hand` (28422) at 0,0,0: the scenario-library idles the drinks and
  snacks use (coffee, doughnut) bring the RIGHT hand to the mouth and are authored
  around that prop bone, so a zero offset lands the cup where the hand is shaped for
  it. Only the two `mp_player_int*` clips are left-handed (`SKEL_L_Hand` + the
  offsets every ESX/QB consumable uses) — the old single left-hand default came from
  that lineage and put every drink in the wrong hand. `drinkRender` BUILDS its list
  by appending: as a literal `{ dd.model, lid }` a flavor with no model left a hole
  at index 1, and `ipairs` stops there — the hand came out empty.
  **`ConsumeAnim` times the clip itself (`Wait(ms)`), never on `lib.progressBar`'s
  return.** A progress bar refuses to run in some states — notably while another
  resource holds NUI focus, i.e. the eat-in view — and returns instantly, which
  deleted the held props a frame after they were attached: the drink never appeared
  in the diner's hand at all. The bar is cosmetic, so it is fired alongside.
- **Takeout box → `box_item` when EATEN.** A third vessel kind (`vesselKind`
  returns `"box"`). SEATED it lays out on the table through `modules/dining` exactly
  like a meal; standing it's eaten where you are, with no contents menu — a box
  holds ONE food, so `consume:eat` consumes EVERY layer whatever indices arrive, and
  names/nourishes from the box + its whole stack (never the bottom component layer).
  `consume:mealSpecs` returns it as ONE part — the box pair with the food's picture
  inside, compSpec's takeout branch — not as its components.
- **Restaurant Bag → `bag_item` (TAKEAWAY).** The tray's sibling at prep: drop
  finished foods/drinks in, "Bag It Up", and `prepMakeBag` records one meta layer per
  pile. Usable anywhere: `modules/consume` opens an **ox_lib context menu** of the
  contents, eating one removes that layer, and the bag itself disappears when the last
  one goes.

**The three VESSELS are handed over as real items the moment they're crafted.** A
meal, a Restaurant Bag and a takeout box are what a customer leaves with, so
`giveVessel` (`modules/cooking/server.lua`) puts them straight into the maker's
inventory with their contents on the slot metadata, instead of the DB-backed tray.
It falls back to `AddTray` when the item isn't installed (these three are what the
resource GENERATES — never a requirement) or the inventory is full, so a made meal
is never destroyed for want of somewhere to put it. Success is tested by COMPARING
THE ITEM COUNT before/after: no bridge's `Inventory.AddItem` returns anything, so
trusting a return value would send every vessel to the tray.
Because of that, POS fulfilment reads TWO stores: `VesselCount`/`VesselTopMeta`/
`VesselVariations`/`VesselConsume` in `modules/sales/server.lua` union the tray pool
with the vessels the restaurant's STAFF are carrying (`vesselHolders`). Who counts as
staff is `vesselSources` → **`ResolvePerms`**, never an enumeration of stores: it was
`EmployeeCache` + `owner_identifier`, which missed everyone who works a restaurant
without being on its payroll. An ADMIN is the case that bites — they have every
permission, so they cook, bag and ring up like an employee, but they hold neither the
restaurant's job nor the restaurant, so a bag in their hands was invisible and the ticket
read "bag it or plate it up" while they stood at the till holding it. (The owner had the
identical bug before being special-cased.) Asking the permission system is what stops the
next such role needing its own special case — which is exactly why moving employment to the
framework's job cost this code nothing: `isBoss or jobInfo or perms.cook/sell` reads the new
model through the same door. That is the same
restaurant-wide pool by a different storage — the tray pool already spans every
cook's tray — and without it, crafting a bag would quietly remove it from the POS.

**A SELLABLE need not be an installed item; a LOOSE hand-over must be.** Cooked and
assembled foods live only in the restaurant-wide cooked-items pool and reach a customer
packed into a meal or a Restaurant Bag — which is why `RecipeMissingItems` /
`IsProductItem` never require them to be installed, and why `__INSTALL/items/` ships
none of them. `BuildSellableCatalog` therefore admits `ItemExists(x) or
IsProductItem(x)` (`sellableOk`) — gating the MENU on `ItemExists` instead hid every
cooked food from the POS, the boards, the kiosk and the phone, which reads exactly like
the group filter being broken. A tray-only sellable takes its label/art from the FOOD
that authors it (`FoodForItem` → `FoodImageUrl`), since there's no inventory row to
borrow from. The mirror-image rule lives in `PlanFulfillment`: a unit whose item isn't
installed can never be a `single` (completion `Inventory.AddItem`s those), so it is
reported as a shortfall until a vessel covers it. Its `looseOk` argument is the one
exception — an NPC is handed its food directly and nothing enters an inventory, so an
NPC ticket still fills straight from the pool.

**A bag SUPPLIES an order exactly like a meal, and a ticket may take SEVERAL.** Both are
"packed vessels" in the POS: `VesselItem`/`VesselItems` in `modules/sales/server.lua`
name the pair, and `PlanFulfillment(rid, order, mealSig, vesselItem, looseOk, pool)`
fills a ticket from two stores — vessels whose top-level layers cover required units
(`mealCovers`, exact variation match) and loose singles from the cooked-items pool.
SINGLES ARE SPENT FIRST (a loose burger fills a burger line without opening a bag), then
as many vessels as the rest needs are claimed, best-fit: most units covered, ties broken
by least left over inside, so a 4-item bag isn't spent on a 1-item ticket. `mealSig`/
`mealItem` are now a PIN, not the whole answer — that exact vessel goes first, is ignored
if it covers nothing (a stray pick can't give away an unrelated bag), and the planner
fills the remainder itself; the plan returns `vessels = {{item, sig}, …}` and completion
hands over every one. `AnnotateOrders` offers meals AND bags in one `mealOptions` list
(an option must both complete the order and actually carry something it asked for), so
`ok` and `ready` now agree and one-tap Complete works. `VesselItem` rejects anything that
isn't the meal or bag item, so a forged payload can never hand over an arbitrary item.

**A takeout box is a SINGLE, not a coverage vessel — and it lives in a POCKET.**
`giveVessel` puts all THREE crafted vessels straight into the maker's inventory, but
only the meal and the bag fulfil as VESSELS (claimed for the units their layers
cover). A box holds one food and IS the sellable unit — a `craft` line asks for the
box item pinned to that food id (`c:<id>`) — so it fills a ticket as a loose single.
The loose store used to be the cooked-items TRAY alone, which a made box only reaches
when the item isn't installed or the cook's pockets were full: a boxed soup sitting in
the cook's own inventory could never complete its own order, however ready the ticket
read. `SingleCountMatch` / `SingleConsumeMatch` (`modules/sales/server.lua`) are
therefore the loose store now — tray + staff-held, tray spent first for the same
reason `VesselConsume` drains it first. Scoped to the box on purpose (`isHeldSingle`):
a cook's personal drink or burger is their own, and only what this resource CRAFTS
into a pocket belongs to the pool. `AnnotateOrders` plans each ticket once per vessel
and now reads that store inside the planner, so the staff-inventory search is memoized
for the pass (`holderMemo`) — never consulted by the consume paths, which must always
see live inventory.
- **Takeout box → `box_item` (`pickle_takeout_box_01` + `_02`).** Where every
  `kind = "bag"` FOOD (soup, salad — the non-stack miscellaneous foods) is now
  created; the bag used to be that vessel. Mechanically the pizza box's twin (`TAKEP`
  ≡ `BOXP`: `LidCfg(kind)` returns either, and the seat/swing/close-before-make maths
  are shared) but it accepts loose food like a tray. `prepMakeBox` matches the
  contents against the food catalogue (`bestCraftForLayers`) and trays ONE `box_item`
  with the food id on its first meta layer — the `craft` flag `TraySig` writes as
  `~id` and the POS reads as its `c:` variant key (`boxFoodId`).

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
  `FoodImageUrl(food, item)` resolves it, falling back to the vessel item's own art.
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

**Both of `getTray`'s stores must describe a vessel the SAME way.** It lists the
cooked-items tray AND inventory-held products, in two separate branches — and a bag or
takeout box only ever got its `comps` (contents) on the TRAY branch. So the same bag
described itself two different ways depending on which store it came from: its
inventory slot read "Drumsticks" (`BuildInvMeta` → `stackDescription`, off exactly
those layers) while its kitchen card shipped no contents at all and fell through to
"No toppings". Anything added to one branch belongs in the other. On the NUI side a
vessel is not a build: `isVessel`/`contentsSummary` (`web/src/views/Cooking.tsx`) make
the card subtitle and the toppings row read its CONTENTS, since a packed vessel has no
base recipe to diff against and its `extras` are always empty.
**A serving is eaten in BITES (a drink, in SIPS).** `ConsumeSpecFor` resolves
`bites` (per food → global `consume` fallback → 3, or 4 for a drink), and
`consume:eat` takes ONE unless the caller passes `whole = true`. Progress is
recorded ON THE LAYER (`eaten`) and written back to the slot, so it is server state
that survives closing the menu, pocketing the meal and reconnecting — a half-eaten
burger stays half-eaten. Each mouthful restores its share and the LAST one settles
the remainder, so N bites always total exactly one serving however it's divided.
Both surfaces offer both: seated, a click on a pile is one bite and the hover
tooltip carries the "eat all of it" button (per the tooltip-not-cards rule; the
tooltip is the only `pointer-events-auto` element over the click-through world);
standing, each bag row opens a two-option sub-menu and a takeout box gets the same
pair built from the `food` block `consume:open` carries for it.

- `consume` = `{ hunger, thirst, anim, bites }` — what eating ONE serving restores (0-100
  percentages of the framework's bars) and which `consume_anims` entry plays.
  `ConsumeSpecFor(item, meta)` resolves it, filling gaps from the global `consume`
  setting; an un-authored DRINK is special-cased to thirst + a drinking clip so an
  upgraded config doesn't feed the wrong bar.

`consume_anims` (settings, seeded internally, edited in Settings → Eating) is the
animation catalogue: `{ id, label, dict, clip, prop, ms }`. The server resolves a
food's pick into the FULL clip spec and returns it with the eat response, so the client
holds no catalogue and an admin's retune applies immediately.

**A food's identity is its LABEL.** `SanitizeFoods` derives `id` from an explicit id →
the final step's output/flavor → the label slug (`foodSlug`), and an id-less food is
dropped on save. That last fallback is what a bag-kind food relies on (it borrows no
inventory item's name), and what lets a half-built recipe survive being saved before
its outputs are typed.

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
are tray-only — never real inventory items, never required by sync/annotate validation (`assemblyMissing`/BuildSyncPayload skip
the output). An assembled input placed to cook with no readable recorded stack gets
its BASE recipe meta SYNTHESIZED at `place` so the cooked product never comes out
stackless (getTray/compSpec also fall back to the base stack for legacy stackless
instances). Follow this pattern for any new food family.

**Every raw STATION INPUT is also an ingredient entry.** A raw patty / drumstick /
cut fries / nuggets / doughnut / cup was previously nothing but a key in
`ingredient_costs` — buyable in Supplies, but with no row in Menu → Ingredients, no
picture beside its price and no prep prop. An ingredient entry is what gives an item
an admin-visible identity, so they are all in `DEFAULT_INGREDIENTS` now, mapped to the
single-serving RAW props (`pickle_side_fries_01`, `pickle_chicken_drumstick_01`,
`pickle_dough_unapplied_01`, … — the `_01` of each family; the recipe's own cook-state
models are the in-basket/on-griddle piles instead). They must NOT become droppable
prep components: `isStationInput` (`modules/cooking/server.lua`) filters the
`GetPrepModels()` door in `getIngredients`, so a raw patty stays on its grill while a
DLC toy still reaches the bar through it. Components genuinely used in a build arrive
via the assembly/craft lists, which that guard never touches.

## DLC packs

An add-on pack (`pickle_restaurants_toys` is the first) is **its own resource**, and
its content lives and dies with it. There is no DB table, no settings row and no
migration: `modules/dlc/server.lua` holds a registry in memory and overlays it on
`GetFoods()` / `GetTools()` / `GetIngredientsCfg()` — the ONE place the runtime reads
the menu from. That single seam is why a pack needs no support anywhere else: recipe
cache, derived assembly/crafts/prep-models, the cooking bar, the POS catalogue, sync
validation, group filtering and the admin annotations all derive from those getters.
`ConsumeAnims()`, `IngredientCosts()` (the new accessor — **use it, not
`GetSetting("ingredient_costs")`**) and `RebuildItemImages()` take the same overlay.

**The authored config always wins.** A pack entry whose id/item an admin has also
authored is DROPPED, not appended — appending would double the entry and let a pack
take over a `DerivedPrepModels` / `DerivedFoodById` key the server's own config owns.
Same rule for costs, item art and clips (an admin can retune a pack's `consume_anims`
entry by authoring one with the same id).

**Pack content carries a `dlc` mark, and the three sanitizers DROP marked entries.**
That is the guarantee, and it belongs on the way IN: the admin panel saves its menu
lists whole, so without it a pack's food could be persisted into the settings table
and outlive the pack that defines it. `Menu.tsx` splits marked entries out of its
editable state for the same reason.

**A DLC entry is READ-ONLY in the menu tabs — no editor, no delete.** Models, group,
behaviour, the entry itself: all the pack's. The panel never prints a pack's PROP
names either. Settings → DLC (`DlcList()`) is the pack inventory.

**The one thing the server owns is PRICE, and it is edited in exactly one place:
Settings → Ingredient Costs** (internal key `pricing`; the tab is LABELLED "Ingredient
Costs"). Cost was never pack content — it is the `ingredient_costs` setting — so the
editor lists a row for every packaged item at the pack's default and STORES only rows
that differ from it (`packs` in `Pricing`). That rule is the whole design:
 - seeding the editor from `settings.ingredient_costs` alone showed $0 for everything
   a pack prices, and saving that back wrote a free toy over the pack's price;
 - seeding its STATE from the effective map instead would author every pack default
   the first time anything on that screen changed, freezing prices the pack should
   still be able to update.
Deleting an overridden row (or typing the pack's own number back) hands the price
back to the pack. `buildAdminData` therefore sends BOTH `ingredientCosts` (effective,
for display) and `dlcCosts` (the pack defaults alone, to compare against).
A per-FACE key is not an item, so the item picker can neither resolve nor safely edit
one: those rows render as a fixed identity (the toy's own name + art, cost only),
resolved from the annotated ingredients the panel already has.

`AnnotateIngredients` also carries `costKey`/`cost`/`defaultPrice` (per variant, on a
COPIED array — never stamp annotations onto a pack's own tables), which is what makes
an ingredient row show a default price at all; it previously computed neither.

**Handshake, both start orders:** the pack calls
`exports.pickle_restaurants:RegisterDLC(content)` on its own `onResourceStart` AND on
our `pickle_restaurants:dlcRequest` (fired at our boot, covering "the pack was already
running when we restarted"). Registration is idempotent by id. We watch
`onResourceStop` **ourselves** rather than trusting a pack to unregister — a pack that
crashed on start would never get the chance. Registered content is UNTRUSTED and goes
through the same sanitizers the NUI's writes do.

Merges are memoized on a shared `DlcRev` counter + the authored table's identity
(`SetSetting` writes a fresh table): with no pack installed the authored array is
handed straight back, and with one the merge rebuilds only on an actual change. This
matters — the cooking engine polls `IngredientDef`/`MeltingToppingFor`, and
`ResolveItemCost` walks the cost map per sellable.

**Ingredients can now author `consume`**, resolved by `ConsumeSpecFor` when no FOOD
claims the item. That is what makes a thing-in-its-own-right possible without a fourth
authoring kind: a **toy** is an ingredient (item + prop, bought into the larder,
dragged off the prep bar, dropped in a bag / box / serving tray like any component)
that also says what USING one does. The block gained `stress` (RELIEF — it drains a
bar rather than filling one, and deliberately never inherits the global `consume`
fallback, which is the FOOD default) and now actually keeps `bites` (it was documented
but silently stripped by `sanitizeConsume`).

**Ingredients can also author `variants`** — the one-item consolidation rule applied
to ingredients. A family of interchangeable things (the five kids-meal toys) is ONE
installed item (`restaurant_toy`) whose variation rides in metadata; each variant has
its own `id`/`label`/`model`/`image` and an optional `consume` layered over the
ingredient's, so the shared parts are stated once. **The metadata shape is the
DRINK's**: a nested one-layer stack `{ { item = <variant id> } }`
(`IngredientVariantMeta`), which is why `TraySig` tells two toys apart for free and
every store that already threads `stack` carries it — `prepAdd` writes it onto the
reservation and `prepMakeMeal`/`Bag`/`Box` needed no change at all. That write is only
safe on an UNSIGNED layer: `consumeLayers` overwrites `stack` from the store for
signed (product) layers and spends a plain component by item alone, so every toy comes
out of the same pool however it is faced — which is the point of one item.
Readers: `IngredientVariantOf` (core) → `compSpec` (model), `LayerDisplay`
(label/image/held prop), `layerIdentity` (a bag lists "Kitty Kat" and "Lardboy", not
"Toy ×2"), `ConsumeSpecFor` (variant `consume` merged over the ingredient's — shared
parts stated once, per-variant parts stated where they differ).

**Faces are what every surface LISTS** — a single generic row answers none of the
questions those surfaces exist for. The prep bar emits one card per variant
(`getIngredients`; an out-of-stock face is hidden like any out-of-stock component).
**The variant branch there MUST run before the plain `poolInvCount` early return** —
that reads the ingredient's GENERIC stock line, which is empty by design once faces
are stocked separately, so the shared `count <= 0` guard hid every toy from a fully
stocked larder. Supplies shows a row per face. The admin Menu tab expands an
ingredient into a row per face (`pushIng` in `Menu.tsx`), each carrying a "one of the
`<item>` items" line so five rows never read as five items to install, and each
pointing at its PARENT `index` so Edit/Delete act on the one authored entry that
defines them all. The chosen id rides the drag (`beginPrepPlace` → part → `prepAdd`)
and is re-validated server-side.

**Fallback for a metadata-less instance** (bare ESX, a hand-spawned item): a
variants-only ingredient authors no `model`, so `RebuildDerived` maps the item to the
FIRST variant's prop, and `ConsumeSpecFor` falls back to the INGREDIENT's own block.
Such a toy is generic — unnamed, average effect — but it renders, it works, and it is
never a dud. Author the ingredient's `consume` as the middle of the variant range for
exactly this reason.

**STOCK KEYS: variants are stocked and priced PER FACE.** `StockKey(item, variant)` →
`restaurant_toy:lardboy`; `SplitStockKey` reverses it and only reports a variant the
ingredient actually declares, so an item whose name contains a colon can't be mistaken
for one. This costs no schema change — `pickle_restaurant_stock.item` is a plain
varchar in OUR table, never a foreign key into the framework's inventory.
**Per-toy pricing is only meaningful with per-toy stock**: one generic line at one
price would let a restaurant buy five $7 Smelly Kats and hand out five $14 Lardboys.
`ingredient_costs` is therefore keyed by stock key, and Supplies shows a row per face.

`poolStockKey(rid, item, variant)` is the ONE resolver — it returns the key to spend,
so `poolInvCount` and `poolInvConsume` (both now taking an optional `variant`) can
never disagree about which line they're looking at. Order: the face's own line →
the ingredient's GENERIC line (a hand deposit, or a refund whose metadata was stripped;
such a unit should be usable as any face rather than stranded) → personal inventory.
`consumeLayers` puts the variant in its aggregation key and pins `t.key` during the
CHECK loop so the units verified are the units spent — re-resolving in the spend loop
could pick a different line if two cooks raced the pool. `reservedUnits` takes a
variant so placed Lardboys don't eat into the Kitty Kat count. `prepDecompose` refunds
under the same stock key it was spent from, so pulling a Lardboy out of a meal puts a
Lardboy back.

**A face's picture comes from the PACK, not the inventory.** An inventory resolves
art by ITEM name, and a variant is not an item — there is no `lardboy` row for it to
look up — so a variant's `image` is an absolute `nui://<pack>/…` url, served by the
pack's own `files{}`. (The generic item's art can ride the DLC payload's
`item_images` into `ItemImageCache`; that still does NOT reach the inventory's own
slot rendering, which only its image folder can feed.) An ingredient's own `group`
is a REAL access gate in `addComp` — the `GetPrepModels()` door is how a standalone
ingredient reaches the bar, and it was the only content path with no group check.
Ungrouped ingredients (every one the base ships) are unaffected. The Menu tab badges
a face with its PARENT's `label` ("TOY") rather than the generic kind.

**An ingredient with a `consume` block is SELLABLE** (`BuildSellableCatalog`) — the
same marker that makes it usable makes it orderable, so a toy reaches the POS, the
kiosk, the boards and the phone while a component (lettuce) never can. Assembly
components are excluded belt-and-braces. A multi-faced one sells ONE LINE PER FACE
(`restaurant_toy::lardboy`), priced from that face's stock key and carrying its own
art — the takeout box's pattern. Fulfilment pins the face through the paired keys
`variationKey` (`v:<id>`, read off the instance's metadata) / `lineVariationKey`, so
a Lardboy line is filled by a bagged Lardboy and never by a Smelly Kat. Like every
cooked food, a toy has no loose-pool store, so it reaches a customer inside a bag or
on a meal tray.

A per-face line is **bought, never carried**: deposit/withdraw move real inventory
items, and the pocket item is generic — a deposit would have no face to record and a
withdrawal would launder a dear toy into a cheap one. Both callbacks refuse a variant
key (`mgmt_variant_not_movable`) and the Supplies row hides those buttons (`movable`).
`ResolveItemCost` prices a bare variants item at its CHEAPEST face so it never reads
as free.

`spec.play` is DERIVED, not authored: relieves stress + feeds nothing ⇒ used, not
eaten. It collapses the bag's "bite / finish it" sub-menu to one "Play with this" row,
swaps the dining tooltip to a single button, changes the notification, and
`LayerDisplay` returns the ingredient's own model as `props` so the ped holds the
actual toy instead of the eat clip's generic burger. Stress reaches the framework
through the bridge's new `Relax(source, amount)` (QB/QBox: `stress` metadata +
`hud:client:UpdateStress`; ESX: `esx_status:remove` on `stress`; standalone: nothing),
with the public `pickle_restaurants:relax` event as the hook for any other system —
the exact shape `Nourish` already uses.

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
