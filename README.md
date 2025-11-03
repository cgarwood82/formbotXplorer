# Overview
This repo serves as a landing place for files that aren't in the main update manager
for the xplorer. Some of these files may be from the image, some may be from custom
configs that I later generate, but they aren't part of the update process.

This repository is also my primary backup for the printer's Klipper configuration.
All synced configuration files now live under the top-level `config/` directory.

## Repo Structure

### config/
Contains a mirror of `$HOME/printer_data/config` from the printer, with some rules:
- Root-level `*.cfg` and `*.conf` files (e.g., `printer.cfg`, `moonraker.conf`) are copied into `config/`.
- All subdirectories under `$HOME/printer_data/config` are mirrored into `config/`,
  except `0_Xplorer/` which is managed by Moonraker's update manager and versioned elsewhere.
- Examples (your actual set may vary by printer):
  - `config/01__User_Custom__CFG/`
  - `config/02__Boards_Serials/`
  - Other directories like `macros/`, etc., if present on the printer

### NotMine/
Holds files that are not managed through the main update manager but are useful to
install on the printer.
- `NotMine/xplorer.py`: A Klipper module loader used by Xplorer.
- `NotMine/variables.cfg`: A configuration file for the module(s).
- `scripts/install_notmine.sh` installs these into the appropriate printer locations and
  backs up prior versions into `NotMine/backup/` when replacing non-empty, different files.

### scripts/
Host maintenance scripts for this repo:
- `scripts/getChanges.sh`: Syncs printer configuration into `./config/` using `rsync`.
  - Safe defaults, supports `--dry-run`, `--no-delete`, `--commit`, and `--verbose`.
  - Excludes `0_Xplorer/` automatically.
- `scripts/deploy_to_printer.sh`: Deploys changes from this repo to the printer.
  - Targets: `--notmine` (NotMine artifacts), `--config` (repo `./config`), or `--all` (default).
  - Safety: `--dry-run`, `--no-delete`, `--verbose`, `--no-backup`, `--confirm`.
  - Git preflight (default ON): ensures you deploy the latest changes by running `git fetch` + `git pull --ff-only` on the current branch. Flags: `--no-git` (skip), `--git-pull` (force on), `--git-remote <R>`, `--git-branch <B>`, `--allow-dirty`, `--stash`.
  - Preflight summary: before applying config, the script runs an rsync dry-run and summarizes `updates` and `deletions`; it will prompt for confirmation unless you passed `--confirm`.
  - Backups: overwritten/deleted config files are backed up under `$HOME/printer_data/config/.deploy_backups/<timestamp>/` by default; NotMine backups go to `NotMine/backup/`.
- `scripts/install_notmine.sh`: Back-compat wrapper that now forwards to `deploy_to_printer.sh --notmine`. Prefer using `deploy_to_printer.sh` directly.

## Using getChanges.sh
- Normal sync (mirrors deletions by default):
  ```bash
  bash scripts/getChanges.sh
  ```
- Preview changes without modifying files:
  ```bash
  bash scripts/getChanges.sh --dry-run
  ```
- Avoid deleting files that were removed on the printer:
  ```bash
  bash scripts/getChanges.sh --no-delete
  ```
- Verbose output and auto-commit the results:
  ```bash
  bash scripts/getChanges.sh --verbose --commit
  ```

### Environment overrides
You can customize source/destination paths:
```bash
KLIPPERCONFIG="$HOME/printer_data/config" \
REPO_CONFIG_DIR="/path/to/this/repo/config" \
VERSIONCONTROLHOME="/path/to/this/repo" \
bash scripts/getChanges.sh
```

## Migration note
Older versions of this repo stored some configuration folders at the top level
(e.g., `01__User_Custom__CFG/`, `02__Boards_Serials/`). These now live under `config/`
with the same names (e.g., `config/01__User_Custom__CFG/`).