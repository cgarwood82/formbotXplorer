# Local patches to third-party code on the printer

These run on the printer as uncommitted changes in other projects' checkouts.
An update through Moonraker either refuses (the repo shows as dirty) or wipes
them, so re-apply after updating: stash, fast-forward, pop, or `git apply`
the file here.

| Patch | Applies in | Base | Fixes |
|---|---|---|---|
| `afc-AFC_extruder-move_extruder-guards.patch` | `~/AFC-Klipper-Add-On` | DEV 8ba0f7b | Klipper crashes (`stepcompress`, `syncemitter`) when AFC borrows an extruder stepper that is active or synced to another extruder |
| `afc-AFC_led-guard-transmit-error.patch` | `~/AFC-Klipper-Add-On` | DEV 8ba0f7b | Klipper hangs after any MCU shutdown: an AFC LED update's send error escaped the reactor |
| `nevermore-port-release-and-ready-timer.patch` | `~/nevermore-controller` | 6c627d9 | `failed to connect - timed out` on restart (serial port never closed; restarts from an error state never disconnected), and a startup crash on `Unknown heater 'heater_bed'` with Klipper v0.13.0-786 |

None of these are upstream yet. AFC on Klipper v0.13.0-741 or newer needs
AFC from DEV 8ba0f7b or later regardless (the `absolute_extrude` rename).
