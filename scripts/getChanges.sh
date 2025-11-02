#!/usr/bin/env bash
# Sync Klipper config into repo under ./config/ for easy backup.
# - Copies root-level *.cfg and *.conf
# - Copies all subdirectories except 0_Xplorer (managed by Moonraker)
# Defaults are safe and idempotent. Requires: rsync, git (optional).

set -euo pipefail

# --- Config -----------------------------------------------------------------
# Discover project root based on this script's location
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Source (printer) and destination (repo) roots
KLIPPERCONFIG="${KLIPPERCONFIG:-$HOME/printer_data/config}"
# Destination inside this repo for configs
REPO_CONFIG_DIR="${REPO_CONFIG_DIR:-$PROJECT_ROOT/config}"
# Repo root (used for optional git commit)
VERSIONCONTROLHOME="${VERSIONCONTROLHOME:-$PROJECT_ROOT}"

# Exclusions (relative patterns). Add as needed.
EXCLUDES=(
  ".git/"
  "*.tmp"
  "*.swp"
  "*~"
  "__pycache__/"
  "0_Xplorer/"   # explicitly omit managed folder
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
  KLIPPERCONFIG       Source root (default: $HOME/printer_data/config)
  REPO_CONFIG_DIR     Destination directory in repo (default: ./config)
  VERSIONCONTROLHOME  Repo root for git operations (default: project root)
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
mkdir -p "$REPO_CONFIG_DIR"
[[ -d "$VERSIONCONTROLHOME" ]] || fail "Destination (repo) not found: $VERSIONCONTROLHOME"

# Build base rsync args
RS_BASE_ARGS=("-a" "--human-readable" "--info=stats1,NAME")
[[ $VERBOSE -eq 1 ]] && RS_BASE_ARGS+=("-v")
[[ $DRY_RUN -eq 1 ]] && RS_BASE_ARGS+=("-n")
[[ -n "${DELETE_FLAG}" ]] && RS_DELETE_ARGS=("--delete") || RS_DELETE_ARGS=()

# Add common excludes to arg sets
COMMON_EXCLUDES=()
for ex in "${EXCLUDES[@]}"; do
  COMMON_EXCLUDES+=("--exclude=$ex")
done

log "Source:        $KLIPPERCONFIG"
log "Destination:   $REPO_CONFIG_DIR"
log "Options:       ${RS_BASE_ARGS[*]} ${RS_DELETE_ARGS[*]} ${COMMON_EXCLUDES[*]}"

changed_any=0

# 1) Sync root-level *.cfg and *.conf into REPO_CONFIG_DIR
log "Syncing root-level *.cfg and *.conf"
ROOT_ARGS=("${RS_BASE_ARGS[@]}" "${RS_DELETE_ARGS[@]}" "--prune-empty-dirs")
# include only cfg/conf at root and exclude everything else
ROOT_ARGS+=("--include=*.cfg" "--include=*.conf" "--exclude=*")
ROOT_ARGS+=("${COMMON_EXCLUDES[@]}")
if output=$(rsync "${ROOT_ARGS[@]}" "$KLIPPERCONFIG/" "$REPO_CONFIG_DIR/"); then
  if [[ -n "$output" ]]; then
    changed_any=1
    echo "$output"
  else
    log "No root-level cfg/conf changes"
  fi
fi

# 2) Sync all subdirectories except 0_Xplorer into REPO_CONFIG_DIR/<dir>
log "Syncing subdirectories (excluding 0_Xplorer)"
DIR_ARGS=("${RS_BASE_ARGS[@]}" "${RS_DELETE_ARGS[@]}" "--prune-empty-dirs")
# Only include top-level directories and their contents;
# exclude root-level files to avoid duplication with step (1).
# Explicitly exclude the managed 0_Xplorer folder.
DIR_ARGS+=("--exclude=/0_Xplorer/" "--include=/*/" "--exclude=/*")
DIR_ARGS+=("${COMMON_EXCLUDES[@]}")
if output=$(rsync "${DIR_ARGS[@]}" "$KLIPPERCONFIG/" "$REPO_CONFIG_DIR/"); then
  if [[ -n "$output" ]]; then
    changed_any=1
    echo "$output"
  else
    log "No directory changes"
  fi
fi

# Optional git commit (run from repo root)
if [[ $AUTO_COMMIT -eq 1 && $DRY_RUN -eq 0 ]]; then
  if command -v git >/dev/null 2>&1; then
    (cd "$VERSIONCONTROLHOME" && \
      git add -A && \
      if ! git diff --cached --quiet; then
        msg="chore(getChanges): sync printer config -> ./config $(date '+%Y-%m-%d %H:%M:%S')"
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
