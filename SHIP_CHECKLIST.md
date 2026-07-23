# pickle_restaurants — Pre-Ship Review Checklist

A hands-on walkthrough for reviewing the resource before shipping `1.0.0`. There is no
`config.lua` — everything is configured in-game. Run through this on a **clean database**.

Each item is a mini test: **do the thing → confirm the expected result.** ⚙ = a
"TUNE IN-GAME" value you should calibrate for your map/models before ship.

---

## ✅ Already resolved & verified (no action needed)

These were fixed or confirmed in code this pass — listed so you don't re-check them:

- **Demo hack removed.** The `DEMO_KEEP_PREP` "REVERT ME" flag in cooking is gone; leaving a
  prep station now always saves/closes normally (this was the top ship-blocker).
- **Legacy migration layer removed** — the entire pre-"unified menu" pipeline, the legacy
  `pickle_restaurant_recipes` SQL table + its `ALTER` guards, ~22 one-time `*_seeded`
  backfills, and the itemgen grace-retain list. Live-table columns were folded into their
  `CREATE`s (`restaurants.groups`, `menu.variant`, orders `refunded`/`paid_account`/
  `redeemed`, standalone `accounts.bank`) — verified in code.
- **Cooking numeric-cheese decode removed** — `LegacyCheeseItem`, `legacy_cheese_item`,
  `LEGACY_FINISH_OUTPUTS`, the decode shims, and dead `cheeseModel` refs. Toppings resolve
  via `top` metadata + `sig`. *(This one still needs the in-game re-tests in §C6 — a fresh
  boot can't exercise it.)*
- **`dealerships_` context-menu ids renamed** to `restaurants_` in `core/client.lua`.
- **All server/core Lua compiles** (`luac5.4 -p`), no dangling references.

---

## 🧭 Decisions for you (not testable — product calls)

- [ ] **XP integration is unwired.** Confirmed in code: `bridge/xp` exposes `AddPlayerXP` /
  `GetPlayerLevel`, but **nothing in the resource ever calls them**. Either wire XP into the
  cook/sell flow or drop the `bridge/xp` folder — as shipped it does nothing.
- [ ] **`bridge/phone/gksphone/` is untracked in git** (`?? bridge/phone/gksphone/`). Commit
  it (it's a supported phone bridge) or remove it — right now it isn't part of the resource.
- [ ] **Debug/tuning console commands ship enabled** (all admin/console-gated). Keep for
  server owners to calibrate, or gate behind a debug flag: `/pickle_stackdbg`,
  `/pickle_modeldim`, `/pickle_prepdbg`, `/pickle_brand_debug|res|orient|reload`,
  `/pickle_screen_debug|state|res|orient`, `/pickle_kiosk_cam|res`,
  `/pickle_register_cam|sens|orient|res`, `/pickle_delivery_debug`, `/virtual_debug`,
  `/virtual_tune`.
- [ ] **NPC `happy` walk-away reaction** is reserved but currently identical to unhappy
  (`modules/npc_customers/client.lua`). Intended for ship, or wire a visible difference?
- [ ] **itemgen still exports per-flavor drink `output` keys** (`add(d.output)`) as a grace
  measure — harmless (only affects the generated item files, no runtime effect), but they
  aren't real items anymore. Drop on a later pass if you want the export minimal.
- [ ] **The `cheese` addressing column is now always `0`** but still threads the tray key +
  reservation keys. Fully removing it (re-key the tray table, drop the param everywhere) is a
  separate structural refactor — not required to ship.

---

## A. Install & boot

- [ ] Start the server against an **empty database**. Expect: boots with no errors; console
  prints `Booted: N restaurants, N props, N recipes.` On a clean DB that's `0, 0, N`.
- [ ] Run `/restaurants_items` as an admin, then install the generated items from
  `generated_items/` for your inventory (ox_inventory / ESX SQL / QBCore). Restart, run
  `/restaurants_items` again — the export should reflect your live menu and **not** contain
  retired items (`frosted_doughnut`, `decorated_cake`, `cheeseburger`, `raw_pizza`, etc.).
- [ ] Confirm the resource boots on your **framework** (ESX / QBCore / standalone) — only the
  matching bridge should load; no bridge errors in console.

## B. Admin setup (`/restaurants`)

- [ ] As an admin, open `/restaurants`. **Create a restaurant**, set yourself as owner, give
  it a name → confirm a codename slug is derived and it appears in the list.
- [ ] **Place props**: from the panel, place a grill (stovetop), a fryer, a soda fountain, a
  kitchen-prep table, a counter, and one screen (menu or orders). Each closes the panel →
  gizmo preview → `E` to place, then reopens the panel. ⚙ nudge positions to your map.
- [ ] Place a **seat** (invisible anchor, ghost-ped preview) and a **virtual point** (station
  anchor inside a kitchen shell) if you use them.
- [ ] **Menu editor** (foods/tools/ingredients is the only authoring surface): create a new
  interactive food with steps, a bag food, a tool, and an ingredient. Everything **auto-saves**
  (no save buttons) and shows a confirmation toast. Reload the panel → your edits persisted.
- [ ] **Brand/theme**: set a brand image + crop, change the theme (primary colour / dark|paper
  / radius) → the panel restyles live; the crop UI numbers match what lands on the prop.
- [ ] "**Reset menu to defaults**" restores the shipped foods/tools/ingredients.

## C. Cooking stations

### C1. Grill (stovetop) — patties + cheese ⚙ camera framing
- [ ] Walk to the grill, interact → scripted camera leans in, ped hides.
- [ ] Drag a **raw patty** onto the grill. It cooks `raw → cooked → burnt` on the timer;
  only the down (grill) side's timer runs.
- [ ] **Click the patty to flip** — it flips as one rigid body, banked time carries over.
- [ ] Drag a **cheese slice** onto the cooked-up face → it seats, then melts (applied →
  melted) after its timer. It only applies once that face is cooked.

### C2. Oven (stovetop doors) ⚙
- [ ] Click an oven **door** → it swings open (tweened, server-synced). Cooking pauses while open.
- [ ] Seat a bake/pizza in a slot → it cooks inside; a batch bake (cookie tray) lays out as a
  grid on its tray.

### C3. Fryer ⚙
- [ ] Drag fries/nuggets/a doughnut into a basket. Click to **lower** (starts frying) / **raise**
  (pauses). Collect cooked → you get the batch yield (e.g. a serving of fries).

### C4. Soda fountain ⚙ tap geometry / ice / pour offsets
- [ ] Place a cup under a tap — it **locks to the nearest free tap** (doesn't trail the cursor).
- [ ] Click a **drink tap** → colored stream pours, cup fills (empty → filling → filled), tinted
  by the drink's colour. Click the **middle nozzle** → ice cubes free-fall into the rim.
- [ ] Drag the **lid** onto a filled cup → caps it; it collects as the single drink item with
  the flavor as metadata (check the inventory slot).

### C5. Kitchen prep — building ⚙ stack tweaks / box hinge / condiments
- [ ] Drag components onto the table; they **stack** under the cursor. Grab a part → it lifts
  everything above it.
- [ ] Drag a pile together into a recipe → "**Make**" produces the product (correct one ranked
  first).
- [ ] **Serving tray**: drop it, arrange piles on the paper, "Make Meal" → one meal; leaving the
  station auto-makes trays.
- [ ] **Pizza box**: drop it, click the lid to swing open/closed, drop a pizza in (a non-pizza
  outlines red and is refused), "Box It Up" closes then makes a boxed meal; "Take Out" removes it.
- [ ] **Restaurant bag**: drop craft components, "Bag It Up" → one bag item labelled as the craft.
- [ ] **Baking**: rub the baking-mix over a cake tin / cookie tray (coverage fills the sheet /
  6 dough balls), drag the filled tray to the hotbar to collect the oven-ready input.
- [ ] **Finish tool** (frosting): pick a flavor on the card, rub it over a cooked cake/doughnut →
  the flavored result fades in at full coverage.
- [ ] **Condiment** (ketchup): drag the bottle over a stack → it flips, squeezes once, adds a
  sauce layer. Confirm it **can't** be the bottom layer.

### C6. 🚩 Legacy-removal re-tests (must pass — a fresh boot can't exercise these)
These validate the cooking numeric-cheese decode removal. If any fails, the removal regressed:
- [ ] **Cheese survives the sale.** Grill-cheese a patty (let it melt), build it into a burger
  at prep, sell it at the register, and take the food — the sold item still has cheese.
- [ ] **Variations stay distinct.** Make a plain burger and a cheeseburger (and a plain vs a
  pepperoni pizza). In the tray they're **separate entries**; selling one consumes the *right*
  instance, not whichever is on top.
- [ ] **Variations survive inventory.** Move a topped/varied item to your inventory and back —
  the topping/variation is intact (ox_inventory / qb; bare ESX falls back to the base recipe).
- [ ] **Finishes still classify.** A plain `cooked_doughnut` is **not** treated as frosted; a
  frosted one **is** terminal (can't be decomposed). Frosting/sprinkles render correctly.
- [ ] **Decompose intact.** Drag a topped product / meal back onto the prep table → it un-makes
  into an editable build with its topping + layout preserved.

### C7. Tray & expiration
- [ ] Cooked & uncooked tabs group items by variation. Burnt items sort to the back.
- [ ] A cooked item **counts down** and turns red in its last minute, then auto-clears at 0
  (per-recipe `expire_seconds`, else the global default). Collect-to-inventory and the two-click
  bin both work.

## D. Selling

- [ ] **Register (physical counter)** — interact → in-world POS DUI, camera + virtual cursor.
  Ring up an order (pick a customer, add items/modifiers/combos), take payment → customer is
  charged **cash**, gets a receipt, ticket appears; commission is paid. ⚙ cam/sensitivity.
- [ ] **Virtual register anchor** — opens the **fullscreen NUI** register instead.
- [ ] **Complete / cancel** a ticket → completing hands the food (with its variation); cancelling
  refunds via the single path (no double-refund on repeat clicks).
- [ ] **Kiosk** — interact → in-world order DUI; the customer pays their **own** order (no
  commission). ⚙ cam/sensitivity.
- [ ] **NPC customers** — with a restaurant open and staff clocked in, NPCs walk up and place
  real tickets off the priced menu; serve them (they pay on serve, may tip). Impatient ones leave.

## E. Management panel (boss/owner)

- [ ] Open the boss panel; each tab is permission-gated. **Hire** a nearby player, set grade &
  commission; **fire** someone.
- [ ] **Price list**: set/remove prices (incl. a per-flavor drink price) → boards update.
- [ ] **Supplies**: buy stock from balance; deposit/withdraw between pocket and pool.
- [ ] **Finances**: deposit/withdraw cash ↔ balance; ledger shows the entries.
- [ ] **Combos**: create a numbered combo (slots × options), price it → it appears on the board
  and sells, fulfilled from its component items.
- [ ] **Rename** is owner-only (a manager can't).

## F. Phone app ("Pickle Eats")

- [ ] Open the app on your phone bridge (lb-phone / gksphone / qs-smartphone). With no phone
  installed, nothing errors — the app just doesn't appear.
- [ ] Browse a storefront, **place a delivery order** → charged to **bank**, appears in the
  kitchen (KDS) queue; apply a promo / loyalty redemption if configured.
- [ ] Favorite & reorder; leave a review (1–5, order-gated); earn a loyalty punch.
- [ ] Staff: **clock in/out**; owner: check the analytics tab; create a promotion (broadcasts live).
- [ ] Reserve a **booth** → enter/leave teleports you into the instanced spot. ⚙ single global
  `BOOTH` anchor — confirm it's acceptable for your map.

## G. Delivery

- [ ] A driver claims a delivery order → gets a waypoint; the customer can track it live (GPS
  ping is rate-limited and only from the assigned driver). Delivering hands the food.
- [ ] Customer ⇄ driver **chat** works both ways.
- [ ] Disconnect the driver mid-run → the claim releases and the order can be re-claimed.

## H. Screens, branding & DUIs

- [ ] **Menu board** pages through the priced menu + combos; **orders board** shows live
  PREPARING/READY tickets newest-first. ⚙ `/pickle_screen_res|orient` to fit your prop.
- [ ] **Packaging brands** (cup/box/tray/kiosk) paint the nearest branded restaurant's image;
  ⚙ `/pickle_brand_res|orient`. Screens read as albedo (only as bright as the room) — a dim
  screen is an **emissive-shader/asset** fix, not a code one.

## I. Seating

- [ ] Sit on a placed seat anchor → chair animation, movement locked; `E` stands. Two players
  can't share one seat. ⚙ pose/offset.

## J. Framework / inventory matrix (spot-check)

- [ ] Repeat a **cook → build → sell → carry** loop on each framework you support (ESX /
  QBCore / standalone) and each inventory (ox_inventory + your fallback) — item images resolve,
  slot metadata (variations) survives, money routes to the right wallet.

## K. NUI build

- [ ] `cd web && npm run build` produces `nui/`, and the built output is **committed**. The game
  serves `nui/`, not `web/src`, so an un-built change won't show up in-game.
</content>
