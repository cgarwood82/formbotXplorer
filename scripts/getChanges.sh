#!/usr/bin/env bash
# Sync selected Klipper config subfolders into this repository working tree.
# Defaults are safe and idempotent. Requires: rsync, git (optional).

set -euo pipefail

# --- Config -----------------------------------------------------------------
# Discover project root based on this script's location
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Source (printer) and destination (repo) roots
KLIPPERCONFIG="${KLIPPERCONFIG:-$HOME/printer_data/config}"
VERSIONCONTROLHOME="${VERSIONCONTROLHOME:-$PROJECT_ROOT}"

# Directories (relative to KLIPPERCONFIG) to sync into repo root
SYNC_DIRS=(
  "01__User_Custom__CFG"
  "02__Boards_Serials"
)

# Exclusions (relative patterns). Add as needed.
EXCLUDES=(
  ".git/"
  "*.tmp"
  "*.swp"
  "*~"
  "__pycache__/"
)

# Options
DELETE_FLAG="--delete"        # mirror deletions; override with --no-delete
DRY_RUN=0                      # set by --dry-run
AUTO_COMMIT=0                  # set by --commit
VERBOSE=0                      # set by --verbose

# --- Args -------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --dry-run       Show what would change without modifying files
  --no-delete     Do not delete files in repo that were removed in source
  --commit        git add -A and commit changes after sync
  --verbose       Print verbose rsync output
  -h, --help      Show this help

Env overrides:
  KLIPPERCONFIG   Source root (default: $HOME/printer_data/config)
  VERSIONCONTROLHOME  Repo root (default: project root)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-delete) DELETE_FLAG=""; shift ;;
    --commit) AUTO_COMMIT=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- Helpers ----------------------------------------------------------------
log() { echo -e "[getChanges] $*"; }
fail() { echo "[getChanges:ERROR] $*" >&2; exit 1; }

trap 'fail "An unexpected error occurred (line $LINENO)."' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd rsync

# Validate source and destination roots
[[ -d "$KLIPPERCONFIG" ]] || fail "Source directory not found: $KLIPPERCONFIG"
[[ -d "$VERSIONCONTROLHOME" ]] || fail "Destination (repo) not found: $VERSIONCONTROLHOME"

# Build rsync args
RS_ARGS=("-a" "--human-readable" "--info=stats1,NAME")
[[ $VERBOSE -eq 1 ]] && RS_ARGS+=("-v")
[[ $DRY_RUN -eq 1 ]] && RS_ARGS+=("-n")
[[ -n "${DELETE_FLAG}" ]] && RS_ARGS+=("--delete")

for ex in "${EXCLUDES[@]}"; do
  RS_ARGS+=("--exclude=$ex")
done

log "Source:      $KLIPPERCONFIG"
log "Destination: $VERSIONCONTROLHOME"
log "Options:     ${RS_ARGS[*]}"

changed_any=0
for rel in "${SYNC_DIRS[@]}"; do
  src="$KLIPPERCONFIG/$rel/"        # trailing slash: copy contents
  dst="$VERSIONCONTROLHOME/$rel/"   # mirror directory layout

  if [[ ! -d "$src" ]]; then
    log "Skip (missing): $src"
    continue
  fi
  mkdir -p "$dst"

  log "Syncing: $rel"
  # Capture rsync output to decide if anything changed
  if output=$(rsync "${RS_ARGS[@]}" --prune-empty-dirs "$src" "$dst"); then
    if [[ -n "$output" ]]; then
      changed_any=1
      echo "$output"
    else
      log "No changes in $rel"
    fi
  fi
done

# Optional git commit
if [[ $AUTO_COMMIT -eq 1 && $DRY_RUN -eq 0 ]]; then
  if command -v git >/dev/null 2>&1; then
    (cd "$VERSIONCONTROLHOME" && \
      git add -A && \
      if ! git diff --cached --quiet; then
        msg="chore(getChanges): sync from printer $(date '+%Y-%m-%d %H:%M:%S')"
        git commit -m "$msg"
        log "Committed changes: $msg"
      else
        log "No staged changes to commit"
      fi)
  else
    log "git not found; skipping commit"
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry-run complete. No files were modified."
else
  if [[ $changed_any -eq 1 ]]; then
    log "Sync complete with changes."
  else
    log "Sync complete. No changes detected."
  fi
fi