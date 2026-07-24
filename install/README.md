# pickle_restaurants — inventory item install

These are the inventory items the resource needs. Install the file for your framework:

| Inventory / framework | File | How |
| --- | --- | --- |
| **ox_inventory** | `ox_inventory.lua` | paste the entries into `ox_inventory/data/items.lua` |
| **QBCore** | `qbcore_items.lua` | paste the entries into `qb-core/shared/items.lua` |
| **Legacy ESX** (esx_inventory / native) | `esx_items.sql` | run the SQL against your database |

Item images (`<item>.png`) go in your inventory's image folder; the resource ships
matching art under `nui/items/` you can copy across.

## What's here — and what's deliberately not

The resource follows a **one-item, containers-out** model:

- **Handout items** — what actually leaves the kitchen and enters a player's
  inventory: `restaurant_bag`, `meal` (meal trays *and* boxed pizza — a boxed pizza
  is a meal variant), `drink` (every fountain flavor is this one item, the flavor
  rides as metadata), and `receipt`.
- **Raw inputs** — everything the kitchen buys as supplies and consumes: the raw
  cook inputs (`raw_beef_patty`, `raw_fries`, `raw_doughnut`, …), the assembly
  ingredients (`bun`, `cheese`, `lettuce`, `pizza_dough`, …), `empty_cup`, the
  baking `baking_mix`, and the tools (`frosting`, `sprinkles`, `ketchup`, …).

**Cooked & assembled foods are intentionally NOT items** — `burger`, `cheeseburger`,
`cooked_fries`, `cooked_beef_patty`, `cooked_doughnut`, `cooked_pizza`, `cooked_cake`,
`raw_pizza`, `raw_cake`, the `burnt_*` variants, and so on. They only ever exist in
the per-player **cooked-items tray** and are packaged into a bag, meal tray, or pizza
box at the prep station before they're sold. Because they're not installed, the POS
never offers them as standalone sellables — exactly the intended flow. If you *do*
want to sell a bare burger, add that item here and it becomes sellable automatically.

## Adding your own

If you add ingredients or tools in the in-game menu editor, add matching item
definitions here the same way. A new **cooked food** needs no item unless you want to
hand it out on its own — the kitchen treats any recipe/assembly/finish output as a
tray-only product automatically.
