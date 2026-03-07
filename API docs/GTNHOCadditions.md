# GTNH OC Additions

Adds additional OpenComputers drivers for blocks from the GTNH modpack.

## Features

### Galacticraft

- Control and monitor the **Cargo Loader & Unloader** and **Cargo Launch Controller** (enable/disable, frequencies, rocket docking status, operation results).
- Monitor and control **Airlock Controllers** (open/closed state).
- Monitor and control the **Bubble Distributor** (oxygen bubble visibility and size).
- Read energy storage from any **Galacticraft energy device** (generic fallback driver).
- Monitor and control the **Fuel Loader** (fuel tank info, loading state).
- Read collection speed from the **Oxygen Collector**.
- Monitor and control the **Oxygen Sealer** (sealed state, thermal control).
- Monitor and control **Solar Panels** (energy production, solar boost, operational status).
- Read live telemetry data from the **Telemetry Unit** (players, rockets, astro-miners, mobs).

### Nuclear Control

- Read the displayed text from cards inside an **Information Panel** or **Advanced Information Panel**.

---

## Currently Added Methods

### `cargo_loader`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `toggleEnabled()` | `bool` | Toggles the enabled state and returns the new state. |
| `getStatus()` | `bool, string` | Returns the success flag and the result of the last operation. Status values: `OUT_OF_ITEMS`, `TARGET_NOT_FOUND`, `TARGET_FULL`, `TARGET_LACKS_INVENTORY`, `SUCCESS`. |

### `cargo_unloader`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `toggleEnabled()` | `bool` | Toggles the enabled state and returns the new state. |
| `getInvStatus()` | `bool, string` | Returns the success flag and the result of the last operation. Status values: `TARGET_NOT_FOUND`, `TARGET_EMPTY`, `SUCCESS`. |

### `cargo_launch_controller`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `toggleEnabled()` | `bool` | Toggles the enabled state and returns the new state. |
| `getFrequency()` | `int` | Gets the source landing pad frequency. |
| `setFrequency(int frequency)` | `void` | Sets the source landing pad frequency. |
| `isValidFrequency()` | `bool` | Gets whether the current source frequency is valid. |
| `getDstFrequency()` | `int` | Gets the destination landing pad frequency. |
| `setDstFrequency(int frequency)` | `void` | Sets the destination landing pad frequency. |
| `isValidDstFrequency()` | `bool` | Gets whether the current destination frequency is valid. |
| `isRocketDocked()` | `bool` | Gets whether a cargo rocket is docked on the connected landing pad. |

### `airlock_controller`

| Method | Returns | Description |
|---|---|---|
| `isOpen()` | `bool` | Returns `true` when the airlock is open (not active). |

### `bubble_distributor`

| Method | Returns | Description |
|---|---|---|
| `isBubbleVisible()` | `bool` | Gets whether the oxygen bubble sphere is visible. |
| `setBubbleVisible(bool visible)` | `void` | Shows or hides the oxygen bubble sphere. |
| `getBubbleSize()` | `number` | Gets the current bubble radius. |

### `gc_energy_device`

Generic driver that works with any Galacticraft block that stores energy. More specific drivers (e.g. `solar_panel`, `fuel_loader`) take priority over this one.

| Method | Returns | Description |
|---|---|---|
| `getStoredEnergy()` | `number` | Gets the current stored GC energy. |
| `getMaxEnergy()` | `number` | Gets the GC energy capacity. |

### `fuel_loader`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `isLoading()` | `bool` | Returns `true` if fuel is actively being pumped into a rocket. |
| `getFuelTank()` | `table` | Returns fuel tank information (fluid name, amount, capacity). |

### `oxygen_collector`

| Method | Returns | Description |
|---|---|---|
| `getCollectionSpeed()` | `number` | Gets the current oxygen collection speed in units per second. |

### `oxygen_sealer`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `isSealed()` | `bool` | Returns `true` if the sealer is actively providing oxygen. |
| `isThermalControlEnabled()` | `bool` | Returns `true` if thermal control is enabled. |
| `isThermalControlWorking()` | `bool` | Returns `true` if thermal control is actively functioning. |

### `solar_panel`

| Method | Returns | Description |
|---|---|---|
| `isEnabled()` | `bool` | Gets the current enabled state. |
| `setEnabled(bool enable)` | `bool` | Sets the enabled state and returns the new state. |
| `getEnergyProduction()` | `number` | Gets the current energy output in GJ/tick. |
| `getBoost()` | `number` | Gets the solar boost as a percentage above baseline (e.g. `50` = 1.5×). |
| `getStatus()` | `string` | Gets the current operational status. Values: `DISABLED`, `NIGHT_TIME`, `RAINING`, `BLOCKED_FULLY`, `BLOCKED_PARTIALLY`, `GENERATING`, `UNKNOWN`. |

### `telemetry_unit`

| Method | Returns | Description |
|---|---|---|
| `isLinked()` | `bool` | Returns `true` if the unit is linked to an entity. |
| `readTelemetry()` | `table` | Returns a table of telemetry data for the linked entity (see below). |

#### `readTelemetry()` table fields

All entity types return: `name`, `x`, `y`, `z`, `speed` (blocks/sec).

Living entities additionally return: `health`, `maxHealth`, `recentlyHurt`, `pulseRate`.

| Entity type | Additional fields |
|---|---|
| `PLAYER` | `food` (%), `oxygenSecondsLeft` |
| `ROCKET` | `countdown` (sec), `isIgnited`, `fuelTank` (table) |
| `ASTRO_MINER` | `storedEnergy`, `maxEnergy`, `status` (`STUCK`, `DOCKED`, `TRAVELLING`, `MINING`, `RETURNING`, `DOCKING`, `OFFLINE`, `UNKNOWN`) |

### `info_panel`

| Method | Returns | Description |
|---|---|---|
| `getCardData(int cardIndex)` | `string` | Gets the text displayed on the card at the given slot, or `nil` if the index is invalid. |

### `advanced_info_panel`

| Method | Returns | Description |
|---|---|---|
| `getCardData(int cardIndex)` | `string` | Gets the text displayed on the card at the given slot, or `nil` if the index is invalid. |
