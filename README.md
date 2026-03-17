# drmon — Draconic Reactor Monitor

Monitor and failsafe automation for the **Draconic Evolution** reactor, energy storage, and pocket remote.
Compatible with **Draconic Evolution for Minecraft 1.20.1** and **CC:Tweaked**.

![Reactor monitor screenshot](examples/2.jpg)

---

## Features

### Reactor monitor (`drmon.lua`)
- Live readout of status, temperature, field strength, energy saturation, fuel level, generation rate
- Automated input-gate regulation to hold field strength at a configurable target %
- Touchscreen buttons to adjust output flux gate ±1k / ±10k / ±100k RF/t
- Toggle between **AUTO** (algorithm-controlled) and **MANUAL** input gate modes
- **Fuel ETA** — time remaining at current consumption rate
- **Uptime** and **cumulative RF generated** counters
- **Failsafe indicator** — flags when the reactor's built-in failsafe is active
- **Battery-linked hysteresis control** — stops the reactor when the energy core is full, restarts it when storage drains to a low-water mark (conserves fuel significantly)
- Automatic emergency shutdown when:
  - Field strength drops below threshold (default 15%) → emergency recharge
  - Temperature exceeds limit (default 8000 °C) → cools down and restarts
  - Fuel drops below 10%
- Auto-reactivation after emergency cool-down
- Peripheral **auto-reconnect** if a cable is unplugged and re-inserted
- Timestamped event log written to `drmon.log`
- Wireless remote support (ender modem / advanced wireless modem)

### Energy storage monitor (`bat.lua`)
- Live readout of current stored RF, max capacity, and fill percentage
- Colour-coded progress bar (green > 75%, orange > 25%, red below)
- **Net transfer rate** computed from energy delta — shows charge (+) or drain (−)
- **Time-to-full / time-to-empty** estimate

### Pocket remote (`pocket.lua`)
- Displays reactor status, temperature, field %, fuel %, generation rate, chaos saturation
- Keyboard shortcuts: **C** charge · **A** activate · **S** stop · **R** reboot
- Polls every 10 seconds; shows a "NO SIGNAL" indicator if the reactor computer goes quiet

---

## Requirements

| Item | Qty | Notes |
|---|---|---|
| Advanced Computer | 1 | Runs `drmon.lua` |
| Draconic Reactor (fully built) | 1 | One stabiliser must be directly adjacent to the computer |
| Flux Gates | 2 | One input (energy injector side), one output (energy storage side) |
| Advanced Monitor | 9 | Arranged in a 3×3 grid |
| Wired Modem | 4 | One on each: computer, input gate, output gate, monitor array |
| Networking Cable | — | Connects the four wired modems |
| Ender Modem / Advanced Wireless Modem | 1 (optional) | For pocket remote access |
| Advanced Pocket Computer | 1 (optional) | Runs `pocket.lua` |
| Energy Pylon (Draconic Evolution) | 1 (optional) | For battery-linked reactor control |

> **Why can't I use ender modems instead of cables?**
> `peripheral.wrap()` only works over the wired modem/cable network. Ender modems carry
> `rednet` messages only — they cannot proxy peripheral API calls. The reactor computer,
> flux gates, monitor, and energy pylon **must** be connected via wired modems and cables.
> Ender modems are the right choice for the pocket remote, where only message-passing
> is needed.

---

## Physical Setup

### Reactor computer wiring

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   [Monitor 3×3]                                         │
│        │ Wired Modem                                    │
│        └──── cable ──── cable ──── cable ────┐          │
│                                              │          │
│   [Flux Gate IN] ─ Wired Modem ─ cable ─ [Wired Modem] │
│                                              │          │
│   [Flux Gate OUT] ─ Wired Modem ─ cable ────┘          │
│                                    │                    │
│                              [Advanced Computer]        │
│                                    │                    │
│                           [Reactor Stabiliser]          │
│                          (directly adjacent)            │
│                                                         │
│   [Energy Pylon] ─ Wired Modem ─ cable ──┘  (optional) │
└─────────────────────────────────────────────────────────┘
```

- The reactor stabiliser **must touch a side** of the advanced computer directly — no modem needed for it.
- All other peripherals connect via a shared wired modem/cable network.
- Turn on each wired modem after placing it (right-click). The peripheral names (`flux_gate_0`, `monitor_0`, etc.) appear once the modem is active.
- If you add an ender modem to the computer, the pocket remote gains access automatically.

### Monitor arrangement

Set up a **3×3 grid of advanced monitors** all touching. Place a wired modem on any non-front face of the arrangement and connect it to the cable network. The monitor will appear as a single large display.

Recommended text scale: **0.5** (set with `monitor <side> set textScale 0.5` or right-clicking the monitor and using the in-game settings) — gives enough rows to show all display sections including the battery panel.

---

## Installation

### Reactor computer

1. Boot the advanced computer and run:
   ```
   pastebin get mgF6RZFQ startup
   startup
   ```
   *(or replace the pastebin code with the `install.lua` from this repo if self-hosting)*

2. The installer will:
   - Download `drmon.lua`, `bat.lua`, and `lib/f.lua`
   - Auto-detect the reactor side, flux gates, and monitor
   - Ask which flux gate is the **input** gate (the one connected to the energy injector)
   - Optionally ask for the energy pylon peripheral name (for battery-linked control)
   - Save `config.txt` and launch the program

3. The program launches automatically on every reboot.

### Energy storage monitor (separate computer)

Edit the top of `bat.lua` to match your setup:
```lua
local pylonSide   = "back"   -- side the energy pylon is on
local monitorSide = "left"   -- side the monitor is on
```
Then copy `bat.lua` to the computer and run it:
```
> bat
```
To auto-run on boot, rename or copy it to `startup`.

### Pocket remote

On an advanced ender pocket computer:
```
pastebin get PUWxdYWY startup
startup
```
*(or copy `pocket.lua` to the pocket computer)*

The pocket computer will search for a wireless modem automatically. Make sure the reactor computer also has an ender modem attached and `rednet` open on it (the `wireless()` coroutine in `drmon.lua` handles this automatically).

---

## Configuration

Settings are stored in `config.txt` (one value per line). Re-running `install.lua` regenerates this file interactively. You can also edit it directly:

| Line | Key | Default | Description |
|---|---|---|---|
| 1 | version | `5.1` | Config format version |
| 2 | monType | `reactor` | `reactor` or `bat` |
| 3 | reactorSide | `back` | Side the reactor stabiliser is on |
| 4 | igateName | — | Peripheral name of the input flux gate |
| 5 | ogateName | — | Peripheral name of the output flux gate |
| 6 | monName | — | Peripheral name of the monitor |
| 7 | oFlow | `0` | Initial output gate flow (RF/t) |
| 8 | iFlow | `900000` | Initial input gate flow (RF/t) |
| 9 | autoInputGate | `1` | `1` = AUTO mode, `0` = MANUAL mode |
| 10 | batteryMode | `0` | `1` = battery-linked control ON |
| 11 | batteryHighPct | `95` | Stop reactor when storage reaches this % |
| 12 | batteryLowPct | `25` | Restart reactor when storage drains to this % |
| 13 | batteryPylonName | — | Peripheral name of the energy pylon |

### Tunable constants (top of `drmon.lua`)

These are not in `config.txt`; edit the file directly:

```lua
local targetStrength     = 50    -- target field strength %
local maxTemperature     = 8000  -- °C: triggers emergency shutdown
local safeTemperature    = 3000  -- °C: safe temperature to restart after cooling
local lowestFieldPercent = 15    -- %: emergency-charge field floor
local activateOnCharged  = 1     -- 1 = auto-activate when fully charged
```

---

## Monitor Layout

```
┌───────────────────────────────┐
│ Reactor v5.1      RUNNING     │  ← status (colour-coded)
│                               │
│ Generation         12,345 rf/t│
│                               │
│ Temperature         4,231 C   │
│ Output Gate        50,000 rf/t│
│  <   <<  <<<   >>>  >>   >   │  ← output gate buttons
│ Input Gate         22,000 rf/t│
│          AU                   │  ← AUTO/MANUAL toggle (tap AU/MA)
│ Energy Sat.          83.20%   │
│ ████████████████░░░░░░░░░░░░  │
│                               │
│ Field T:50%         73.45%    │
│ ████████████████████░░░░░░░░  │
│                               │
│ Fuel     89.23%     12h 04m   │  ← fuel % + time-to-empty
│ ██████████████████████░░░░░░  │
│ Up 01:23:45        1.23T RF   │  ← uptime | cumulative RF
│ Action  Reactivated (cooled)  │
│                               │
│ Battery  ON          75.3%    │  ← battery mode toggle (tap ON/OF)
│ Stop@95%         Start@25%    │
│ ██████████████████░░░░░░░░░░  │  ← battery progress bar
└───────────────────────────────┘
```

**Touchscreen interactions:**
- **Output gate row (8):** Tap `<` / `<<` / `<<<` to decrease by 1k / 10k / 100k; `>` / `>>` / `>>>` to increase
- **Input gate row (10):** Same buttons, visible only in MANUAL mode
- **`AU` / `MA` badge (row 10, cols 14–15):** Tap to toggle AUTO ↔ MANUAL input gate control
- **`ON` / `OF` badge (row 22, cols 10–11):** Tap to toggle battery-linked control (requires pylon configured)

---

## Battery-Linked Reactor Control

When enabled, drmon monitors the energy core fill level and manages the reactor automatically:

1. Reactor runs normally until storage reaches **batteryHighPct** (default 95%)
2. Reactor is stopped; flux gates are closed
3. Base draws from storage until it drains to **batteryLowPct** (default 25%)
4. Reactor charges up and resumes

This can dramatically extend fuel life on bases that don't continuously consume reactor-level power. The reactor only runs as much as necessary to keep up with actual demand.

**Requirements:** The energy pylon must be on the same wired modem network as the reactor computer, and its peripheral name must be set in `config.txt` (or entered during `install.lua`).

**Safety:** Battery-linked control is skipped entirely if an emergency shutdown (temperature or field) is active. Manual remote commands (`startup` / `shutdown` via pocket remote) also clear the battery-pause state so you retain full manual override.

---

## Wireless Remote Commands

The reactor computer listens for `rednet` messages on any wireless/ender modem it finds:

| Message | Action |
|---|---|
| `status` | Replies with the full `getReactorInfo()` table |
| `startup` | Charges and activates the reactor |
| `shutdown` | Stops the reactor |
| `reboot` | Reboots the computer |
| `checkin` | Replies `hello v5.1` |
| `identify` | Toggles monitor background light blue (useful when managing multiple reactors) |

---

## Upgrading from a previous version

1. On the reactor computer, hold **Ctrl+T** to terminate the running program, then:
   ```
   reboot
   ```
2. On reboot, `startup` runs `install.lua` which detects the version mismatch, re-runs the setup wizard, and migrates `config.txt` automatically.

---

## File Reference

| File | Runs on | Purpose |
|---|---|---|
| `install.lua` | Reactor computer | First-time setup wizard; downloads all files |
| `drmon.lua` | Reactor computer | Reactor monitoring, control, and automation |
| `bat.lua` | Storage computer | Energy core / pylon monitor |
| `pocket.lua` | Ender pocket computer | Wireless remote status and control |
| `pocket-install.lua` | Ender pocket computer | Downloads `pocket.lua` |
| `lib/f.lua` | (shared library) | Formatting and monitor-drawing utilities |

---

## Troubleshooting

**"Reactor not found on side: back"**
The reactor stabiliser is not directly adjacent to the computer, or is on a different side. Re-run `install.lua` to reconfigure, or edit line 3 of `config.txt`.

**"getReactorInfo() returned nil"**
The reactor build is incomplete (missing stabilisers, containment blocks, or fuel). Fix the build, then reboot.

**Flux gates not responding**
Check that the wired modems on both flux gates are turned on (right-click to toggle). The peripheral names in `config.txt` must match exactly what appears on the modem network. Re-run `install.lua` to re-detect.

**Monitor shows nothing**
Confirm all 9 monitor blocks are arranged in a 3×3 touching grid, the wired modem on the monitor array is turned on, and the cable is connected to the same network as the computer.

**Battery-linked control does nothing**
- Confirm `batteryPylonName` in `config.txt` is not blank
- Confirm the energy pylon's wired modem is turned on
- Tap the `ON` badge on the monitor to enable the mode (it defaults to OFF)
- Check `drmon.log` for error messages

**Pocket remote shows "NO SIGNAL"**
- The reactor computer needs an ender modem (the wired network modem is not enough for wireless)
- Make sure neither computer is in an unloaded chunk
