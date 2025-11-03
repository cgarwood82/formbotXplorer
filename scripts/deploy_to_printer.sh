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
GIT_PULL=1              # 1=perform git pull before deploying
GIT_REMOTE=""
GIT_BRANCH=""
ALLOW_DIRTY=0
AUTO_STASH=0

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
  --confirm        Ask for confirmation before performing actions (also used to auto-approve preflight)
  --no-git         Skip git checks and pulling before deployment
  --git-pull       Force running git pull preflight (default behavior)
  --git-remote R   Use remote R for pull (default: origin if present)
  --git-branch B   Use branch B for pull (default: current branch)
  --allow-dirty    Proceed even if the working tree has uncommitted changes
  --stash          Auto-stash uncommitted changes before pull and pop after
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
# Track if a target was explicitly selected; default to --all if none.
TARGET_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) DO_NOTMINE=1; DO_CONFIG=1; TARGET_SET=1; shift ;;
    --notmine) DO_NOTMINE=1; DO_CONFIG=0; TARGET_SET=1; shift ;;
    --config) DO_NOTMINE=0; DO_CONFIG=1; TARGET_SET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-delete) DELETE_FLAG=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    --backup-dir) CONFIG_BACKUP_DIR="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    --no-git) GIT_PULL=0; shift ;;
    --git-pull) GIT_PULL=1; shift ;;
    --git-remote) GIT_REMOTE="$2"; shift 2 ;;
    --git-branch) GIT_BRANCH="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --stash) AUTO_STASH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $TARGET_SET -eq 0 ]]; then
  # No explicit target provided; default to deploying both NotMine and config
  DO_NOTMINE=1; DO_CONFIG=1
fi

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

confirm_with_message() {
  # $1: message to display before confirmation
  # Returns 0 to proceed, exits 0 otherwise
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  echo -e "$1"
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) log "Cancelled."; exit 0 ;;
  esac
}

# --- Git preflight -----------------------------------------------------------
STASH_MADE=0
GIT_HEAD_BEFORE=""

is_git_repo() { git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

choose_git_remote() {
  if [[ -n "$GIT_REMOTE" ]]; then echo "$GIT_REMOTE"; return; fi
  local def
  def=$(git -C "$PROJECT_ROOT" remote 2>/dev/null | head -n1)
  if git -C "$PROJECT_ROOT" remote | grep -q "^origin$"; then
    echo origin
  else
    echo "$def"
  fi
}

current_branch() { git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null; }

git_preflight() {
  [[ $GIT_PULL -eq 1 ]] || return 0
  if ! is_git_repo; then
    warn "Project is not a Git repo; skipping git pull."
    return 0
  fi

  require_cmd git

  local branch remote
  branch=${GIT_BRANCH:-$(current_branch)}
  remote=$(choose_git_remote)

  if [[ -z "$remote" || -z "$branch" ]]; then
    warn "Unable to determine git remote/branch; skipping git pull."
    return 0
  fi

  log "Git: branch=$branch remote=$remote (preflight)"

  # Check working tree cleanliness
  if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
    if [[ $AUTO_STASH -eq 1 && $DRY_RUN -eq 0 ]]; then
      log "Git: auto-stashing local changes"
      git -C "$PROJECT_ROOT" stash push -u -k -m "deploy_to_printer autostash $TIMESTAMP" >/dev/null || true
      STASH_MADE=1
    elif [[ $ALLOW_DIRTY -eq 1 ]]; then
      warn "Git: proceeding with dirty working tree (per --allow-dirty)."
    else
      fail "Git working tree has uncommitted changes. Use --allow-dirty or --stash to proceed."
    fi
  fi

  # Fetch and fast-forward pull
  git -C "$PROJECT_ROOT" fetch "$remote" "$branch" || fail "git fetch failed."

  # Show ahead/behind
  local upstream="$remote/$branch"
  if git -C "$PROJECT_ROOT" rev-parse "$upstream" >/dev/null 2>&1; then
    local counts
    counts=$(git -C "$PROJECT_ROOT" rev-list --left-right --count "$branch...$upstream" 2>/dev/null || echo "0	0")
    log "Git: ahead/behind (local...remote): $counts"
  fi

  if ! git -C "$PROJECT_ROOT" pull --ff-only "$remote" "$branch"; then
    fail "git pull failed (non fast-forward?). Resolve and retry or run with --no-git."
  fi

  GIT_HEAD_BEFORE=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
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

  # Safety: avoid destructive delete when source is empty unless explicitly confirmed
  if [[ $DELETE_FLAG -eq 1 && $DRY_RUN -eq 0 && $CONFIRM -eq 0 ]]; then
    if ! find "$REPO_CONFIG_DIR" -mindepth 1 -not -path '*/.git/*' -print -quit | grep -q .; then
      fail "Repo config directory appears empty; refusing to run rsync with --delete without --confirm. Re-run with --confirm or use --no-delete."
    fi
  fi

  # Preflight: run rsync dry-run to summarize actions (overwrites/creates/deletes)
  local -a preflight_args=("${args[@]}")
  # Ensure dry-run and itemized changes are on for preflight
  preflight_args+=("-n" "--itemize-changes")
  local preflight_out
  preflight_out=$(rsync "${preflight_args[@]}" "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/" || true)

  # Summarize changes
  local deletes updates total
  deletes=$(echo "$preflight_out" | grep -c '^\*deleting ' || true)
  # Count non-empty lines that look like itemized changes (start with [<>cdhs.]) excluding *deleting
  updates=$(echo "$preflight_out" | grep -E '^[<>cdhs\.].' | grep -v '^\*deleting ' | wc -l | tr -d ' ')
  total=$((deletes + updates))

  if [[ $DRY_RUN -eq 1 ]]; then
    log "Preflight summary: updates=$updates deletions=$deletes (total=$total)"
    # Show details in dry-run
    if [[ -n "$preflight_out" ]]; then
      echo "$preflight_out"
    fi
    return 0
  fi

  if (( total > 0 )); then
    log "Preflight summary: updates=$updates deletions=$deletes (total=$total)"
    if [[ $CONFIRM -eq 0 ]]; then
      confirm_with_message "About to apply the above changes to $KLIPPERCONFIG. Use --no-delete to avoid deletions or --dry-run to preview."
    fi
  else
    log "Preflight summary: no changes needed."
  fi

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
log "Targets:       NotMine=$([[ $DO_NOTMINE -eq 1 ]] && echo yes || echo no), Config=$([[ $DO_CONFIG -eq 1 ]] && echo yes || echo no)"
log "Git preflight: $([[ $GIT_PULL -eq 1 ]] && echo enabled || echo disabled)"

# Run git preflight early to ensure repo is up-to-date before computing any preflight diffs
git_preflight

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

# Pop stash if we created one
if [[ $STASH_MADE -eq 1 && $DRY_RUN -eq 0 ]]; then
  log "Git: restoring stashed changes"
  git -C "$PROJECT_ROOT" stash pop -q || warn "Git: failed to pop stash; your changes remain stashed."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry-run complete. No files were modified."
else
  log "Deployment complete."
fi
