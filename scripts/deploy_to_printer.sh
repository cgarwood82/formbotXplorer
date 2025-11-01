#!/usr/bin/env bash
# Deploy changes from this repo to the printer.
# Supports deploying NotMine artifacts and/or the repo's ./config tree.
# Provides backups on the printer (and retains NotMine backups in repo),
# safe dry-run mode, and sensible defaults.
#
# Requirements: rsync

set -euo pipefail

# --- Discover paths ----------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Repo-side
REPO_NOTMINE_DIR="${REPO_NOTMINE_DIR:-$PROJECT_ROOT/NotMine}"
REPO_CONFIG_DIR="${REPO_CONFIG_DIR:-$PROJECT_ROOT/config}"

# Printer-side
PRINTER_HOME="${PRINTER_HOME:-$HOME}"
EXTRAS_DIR="${EXTRAS_DIR:-$PRINTER_HOME/klipper/klippy/extras}"
KLIPPERCONFIG="${KLIPPERCONFIG:-$PRINTER_HOME/printer_data/config}"

# Backups
# Destination for config backups on the printer side. Default under printer config.
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
DEFAULT_CONFIG_BACKUP_DIR="$KLIPPERCONFIG/.deploy_backups/$TIMESTAMP"
CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-$DEFAULT_CONFIG_BACKUP_DIR}"
# NotMine backups stay in repo by default
NOTMINE_BACKUP_DIR="${NOTMINE_BACKUP_DIR:-$REPO_NOTMINE_DIR/backup}"

# Options / flags
DO_NOTMINE=0
DO_CONFIG=0
DRY_RUN=0
DELETE_FLAG=1           # 1=mirror deletions for config
VERBOSE=0
NO_BACKUP=0
CONFIRM=0

# Exclusions for config push
EXCLUDES=(
  "0_Xplorer/"     # user requested omit; managed elsewhere
  ".deploy_backups/"
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--all|--notmine|--config] [options]

Targets (choose one, default: --all):
  --all            Deploy NotMine and config
  --notmine        Deploy only NotMine artifacts (xplorer.py, variables.cfg)
  --config         Deploy only repo ./config to printer's config dir

Options:
  --dry-run        Show what would change without modifying files
  --no-delete      For config deploy, do not delete files removed in repo
  --verbose        Verbose output
  --no-backup      Do not create backups prior to overwrites/deletions
  --backup-dir DIR Backup directory on printer for config deploy (default: $DEFAULT_CONFIG_BACKUP_DIR)
  --confirm        Ask for confirmation before performing non-dry-run actions
  -h, --help       Show this help

Env overrides:
  REPO_NOTMINE_DIR   (default: $PROJECT_ROOT/NotMine)
  REPO_CONFIG_DIR    (default: $PROJECT_ROOT/config)
  PRINTER_HOME       (default: $HOME)
  EXTRAS_DIR         (default: $PRINTER_HOME/klipper/klippy/extras)
  KLIPPERCONFIG      (default: $PRINTER_HOME/printer_data/config)
  CONFIG_BACKUP_DIR  (default: $DEFAULT_CONFIG_BACKUP_DIR)
  NOTMINE_BACKUP_DIR (default: $REPO_NOTMINE_DIR/backup)
USAGE
}

# --- Arg parsing -------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  DO_NOTMINE=1; DO_CONFIG=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) DO_NOTMINE=1; DO_CONFIG=1; shift ;;
    --notmine) DO_NOTMINE=1; DO_CONFIG=0; shift ;;
    --config) DO_NOTMINE=0; DO_CONFIG=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-delete) DELETE_FLAG=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --backup-dir) CONFIG_BACKUP_DIR="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- Helpers -----------------------------------------------------------------
log() { echo -e "[deploy] $*"; }
warn() { echo -e "[deploy:WARN] $*"; }
fail() { echo "[deploy:ERROR] $*" >&2; exit 1; }

trap 'fail "An unexpected error occurred (line $LINENO)."' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd rsync

confirm_or_exit() {
  [[ $CONFIRM -eq 1 && $DRY_RUN -eq 0 ]] || return 0
  read -r -p "Proceed with deployment? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) log "Cancelled."; exit 0 ;;
  esac
}

# rsync convenience
rsync_base=("-a" "--human-readable" "--info=stats1,NAME")
[[ $VERBOSE -eq 1 ]] && rsync_base+=("-v")
[[ $DRY_RUN -eq 1 ]] && rsync_base+=("-n")

# Excludes array -> args
exclude_args=()
for ex in "${EXCLUDES[@]}"; do
  exclude_args+=("--exclude=$ex")
done

# --- Validation --------------------------------------------------------------
[[ -d "$PROJECT_ROOT" ]] || fail "Project root not found: $PROJECT_ROOT"
[[ -d "$REPO_NOTMINE_DIR" ]] || warn "NotMine directory not found: $REPO_NOTMINE_DIR"
[[ -d "$REPO_CONFIG_DIR" ]] || warn "Repo config directory not found: $REPO_CONFIG_DIR"

mkdir -p "$EXTRAS_DIR" "$KLIPPERCONFIG"

# --- NotMine deployment ------------------------------------------------------
install_notmine() {
  local src_py="$REPO_NOTMINE_DIR/xplorer.py"
  local src_cfg="$REPO_NOTMINE_DIR/variables.cfg"
  local dest_py="$EXTRAS_DIR/xplorer.py"
  local dest_cfg="$KLIPPERCONFIG/variables.cfg"

  mkdir -p "$NOTMINE_BACKUP_DIR"

  install_file_smart "$src_py" "$dest_py" "$NOTMINE_BACKUP_DIR"
  install_file_smart "$src_cfg" "$dest_cfg" "$NOTMINE_BACKUP_DIR"
}

# Smart file installer with backups that skip empty destination files
install_file_smart() {
  local src="$1"; local dest="$2"; local backup_root="$3"
  local name; name=$(basename "$dest")

  if [[ ! -f "$src" ]]; then
    warn "Skip (source missing): $src"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -e "$dest" ]]; then
      if ! cmp -s "$src" "$dest"; then
        if [[ -s "$dest" && $NO_BACKUP -eq 0 ]]; then
          log "DRY-RUN: would back up $dest -> $backup_root/${name}.${TIMESTAMP}.bak"
        fi
        log "DRY-RUN: would update $dest from $src"
      else
        log "DRY-RUN: $name already up to date"
      fi
    else
      log "DRY-RUN: would install $dest from $src"
    fi
    return 0
  fi

  if [[ -e "$dest" ]]; then
    if ! cmp -s "$src" "$dest"; then
      if [[ -s "$dest" && $NO_BACKUP -eq 0 ]]; then
        mkdir -p "$backup_root"
        local backup_path="$backup_root/${name}.${TIMESTAMP}.bak"
        cp -f -- "$dest" "$backup_path"
        log "Backed up $dest -> $backup_path"
      else
        log "Destination $dest is empty or backups disabled; skipping backup."
      fi
      cp -f -- "$src" "$dest"
      log "Updated $dest from $src"
    else
      log "No changes for $name; already up to date."
    fi
  else
    cp -f -- "$src" "$dest"
    log "Installed $dest"
  fi
}

# --- Config deployment -------------------------------------------------------
deploy_config() {
  [[ -d "$REPO_CONFIG_DIR" ]] || fail "Repo config directory not found: $REPO_CONFIG_DIR"

  local -a args=("${rsync_base[@]}" "--prune-empty-dirs")
  if [[ $DELETE_FLAG -eq 1 ]]; then
    args+=("--delete")
    # If backups enabled, keep overwritten/deleted files
    if [[ $NO_BACKUP -eq 0 ]]; then
      args+=("--backup" "--backup-dir=$CONFIG_BACKUP_DIR")
    fi
  else
    # Even without --delete, back up overwritten files if enabled
    if [[ $NO_BACKUP -eq 0 ]]; then
      args+=("--backup" "--backup-dir=$CONFIG_BACKUP_DIR")
    fi
  fi

  args+=("${exclude_args[@]}")

  # Ensure backup directory exists on real runs
  if [[ $DRY_RUN -eq 0 && $NO_BACKUP -eq 0 ]]; then
    mkdir -p "$CONFIG_BACKUP_DIR"
  fi

  log "Deploying repo config -> $KLIPPERCONFIG"
  log "  delete: $([[ $DELETE_FLAG -eq 1 ]] && echo yes || echo no)  backups: $([[ $NO_BACKUP -eq 0 ]] && echo yes || echo no)"
  log "  backup dir: $([[ $NO_BACKUP -eq 0 ]] && echo "$CONFIG_BACKUP_DIR" || echo "(disabled)")"

  # Push everything under repo config to the printer config
  rsync "${args[@]}" "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/"

  if [[ $DRY_RUN -eq 0 && $NO_BACKUP -eq 0 ]]; then
    # Optional cleanup: remove zero-length files from backup dir to align with
    # the policy of skipping empty destination files.
    find "$CONFIG_BACKUP_DIR" -type f -size 0 -print -delete 2>/dev/null || true
  fi
}

# --- Main --------------------------------------------------------------------
log "Repo:          $PROJECT_ROOT"
log "NotMine dir:   $REPO_NOTMINE_DIR"
log "Repo config:   $REPO_CONFIG_DIR"
log "Printer home:  $PRINTER_HOME"
log "Extras:        $EXTRAS_DIR"
log "Printer config:$KLIPPERCONFIG"
log "Dry-run:       $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
log "Verbose:       $([[ $VERBOSE -eq 1 ]] && echo yes || echo no)"

confirm_or_exit

changed_any=0

if [[ $DO_NOTMINE -eq 1 ]]; then
  log "--- Deploy NotMine ---"
  install_notmine
  changed_any=1 # we don't compute diffs precisely here; consider deployment act
fi

if [[ $DO_CONFIG -eq 1 ]]; then
  log "--- Deploy config ---"
  deploy_config
  changed_any=1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry-run complete. No files were modified."
else
  log "Deployment complete."
fi
