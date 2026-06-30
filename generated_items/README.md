# Generated restaurant items

These files were generated from the **current** recipes, drinks, assembly recipes
and restaurant menus configured in-game. They contain every inventory item the
restaurant system references. Re-run `/restaurants_items` after editing your
configuration to regenerate them.

46 items were exported.

## Install (pick the one matching your inventory)

- **ox_inventory** – copy the entries from `ox_inventory.lua` into
  `ox_inventory/data/items.lua`. Add a matching `<name>.png` to
  `ox_inventory/web/images/` for each item.
- **ESX (legacy `items` table)** – import `esx_items.sql` into your database.
- **QBCore** – copy the entries from `qbcore_items.lua` into
  `qb-core/shared/items.lua`, and add `<name>.png` to `qb-inventory/html/images/`.

Items already present in your inventory are safe to skip; the ESX SQL uses
`ON DUPLICATE KEY UPDATE` so re-importing only refreshes labels.
