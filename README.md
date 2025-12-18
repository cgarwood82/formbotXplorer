# Overview
This repo serves as a landing place for files that aren't in the main update manager
for the xplorer. Some of these files may be from the image, some may be from custom
configs that I later generate, but they aren't part of the update process.

This repository is also my primary backup for the printer's Klipper configuration.
All synced configuration files now live under the top-level `config/` directory.

## Repo Structure

### config/
Top-level Klipper configuration and related service configs for the printer. Key items:

- `printer.cfg`: The main entrypoint that `include`s the rest of the stack.
- `variables.cfg`: Runtime/state variables written by Klipper/macros.
- `KlipperScreen.conf`: UI configuration for KlipperScreen.
- `mainsail.cfg`: UI configuration for Mainsail.
- `moonraker.conf`: Moonraker service configuration.
- `crowsnest.conf`: Camera/stream configuration used by crowsnest.
- `timelapse.cfg`: Timelapse add-on configuration.

Subdirectories inside `config/`:

- `0_Xplorer/` — Base, vendor/default profiles
  - `01_Default_CFG/`: Xplorer-provided defaults: basic settings, macros, shell commands,
    and Xplorer variables. Files here should generally not be edited directly.
  - `README.md`: Notes about the default stack.

- `01__User_Custom__CFG/` — User overrides and add-ons
  - Place your custom configuration here (e.g. `overrides.cfg`, toolhead/chamber/LED configs).
  - These files are intended to override or extend the defaults under `0_Xplorer/`.

- `02__Boards_Serials/` — Board serial mappings
  - Per-board serial number config files (e.g. `Mainboard_serial.cfg`, `Tool0_serial.cfg`, etc.).
  - Keeps hardware identifiers separate from functional config.

- `03_Resonance_Measurements/` — Input shaper/resonance data
  - Stored plots and artifacts from resonance measurements for reference/tuning.

- `Macros/` — User macros grouped by purpose (bed leveling, probing, LED state, motion tests,
  print control, etc.). These are included by the main stack via `printer.cfg` or defaults.

### NotMine/
Holds files that are not managed through the main update manager but are useful to
install on the printer.
- `NotMine/xplorer.py`: A Klipper module loader used by Xplorer.

### scripts/
wip