#!/usr/bin/env bash
# Deploy changes from this repo to the printer.
# - Deploys NotMine artifacts and/or the repo's ./config tree
# - Uses a single tarball snapshot backup for the printer config dir before applying changes
# - Keeps backups OUT of the repo and OUT of ~/printer_data/config
#
# Requirements: rsync, tar, git (optional if --no-git), diff

set -euo pipefail

# --- Discover paths ----------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Repo-side
REPO_NOTMINE_DIR="${REPO_NOTMINE_DIR:-$PROJECT_ROOT/NotMine}"
REPO_CONFIG_DIR="${REPO_CONFIG_DIR:-$PROJECT_ROOT/config}"

# Printer-side (script is intended to run on the printer; can be overridden via env)
PRINTER_HOME="${PRINTER_HOME:-$HOME}"
EXTRAS_DIR="${EXTRAS_DIR:-$PRINTER_HOME/klipper/klippy/extras}"
KLIPPERCONFIG="${KLIPPERCONFIG:-$PRINTER_HOME/printer_data/config}"

# Timestamp
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Snapshots (tarball backups) - OUTSIDE printer_data/config and OUTSIDE repo
SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-$PRINTER_HOME/.deploy_snapshots}"
CONFIG_SNAPSHOT_DIR="$SNAPSHOT_ROOT/klipper_config"
CONFIG_SNAPSHOT_FILE="$CONFIG_SNAPSHOT_DIR/config_${TIMESTAMP}.tgz"

# Simple per-file backups for NotMine overwrites (optional, still outside repo)
NOTMINE_BACKUP_DIR="${NOTMINE_BACKUP_DIR:-$SNAPSHOT_ROOT/notmine_files/$TIMESTAMP}"

# Options / flags
DO_NOTMINE=0
DO_CONFIG=0
DRY_RUN=0
DELETE_FLAG=1           # 1=mirror deletions for config
VERBOSE=0
CONFIRM=0
GIT_PULL=1              # 1=perform git pull before deploying
GIT_REMOTE=""
GIT_BRANCH=""
ALLOW_DIRTY=0
AUTO_STASH=0
SHOW_DIFF=0
DIFF_CONTEXT=3
DIFF_MAX_FILES=50

# Exclusions for config push (relative to REPO_CONFIG_DIR root)
EXCLUDES=(
  "0_Xplorer/"          # managed separately in this repo; omit from deploy
  ".deploy_backups/"    # legacy (in case it exists)
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--all|--notmine|--config] [options]

Targets (choose one, default: --all):
  --all            Deploy NotMine and config
  --notmine        Deploy only NotMine artifacts (xplorer.py)
  --config         Deploy only repo ./config to printer's config dir

Options:
  --dry-run        Show what would change without modifying files
  --no-delete      For config deploy, do not delete files removed in repo
  --verbose        Verbose output
  --confirm        Ask for confirmation before performing actions (also used to auto-approve preflight)
  --no-git         Skip git checks and pulling before deployment
  --git-pull       Force running git pull preflight (default behavior)
  --git-remote R   Use remote R for pull (default: origin if present)
  --git-branch B   Use branch B for pull (default: current branch)
  --allow-dirty    Proceed even if the working tree has uncommitted changes
  --stash          Auto-stash uncommitted changes before pull and pop after
  --diff           For config deploy preflight (dry-run), show unified diffs for changed text files
  --diff-context N Diff context lines (default: 3)
  --diff-max N     Max files to diff (default: 50)
  -h, --help       Show this help

Env overrides:
  REPO_NOTMINE_DIR   (default: $PROJECT_ROOT/NotMine)
  REPO_CONFIG_DIR    (default: $PROJECT_ROOT/config)
  PRINTER_HOME       (default: $HOME)
  EXTRAS_DIR         (default: $PRINTER_HOME/klipper/klippy/extras)
  KLIPPERCONFIG      (default: $PRINTER_HOME/printer_data/config)
  SNAPSHOT_ROOT      (default: $PRINTER_HOME/.deploy_snapshots)
  NOTMINE_BACKUP_DIR (default: \$SNAPSHOT_ROOT/notmine_files/$TIMESTAMP)
USAGE
}

# --- Arg parsing -------------------------------------------------------------
TARGET_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) DO_NOTMINE=1; DO_CONFIG=1; TARGET_SET=1; shift ;;
    --notmine) DO_NOTMINE=1; DO_CONFIG=0; TARGET_SET=1; shift ;;
    --config) DO_NOTMINE=0; DO_CONFIG=1; TARGET_SET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-delete) DELETE_FLAG=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --confirm) CONFIRM=1; shift ;;
    --no-git) GIT_PULL=0; shift ;;
    --git-pull) GIT_PULL=1; shift ;;
    --git-remote) GIT_REMOTE="$2"; shift 2 ;;
    --git-branch) GIT_BRANCH="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --stash) AUTO_STASH=1; shift ;;
    --diff) SHOW_DIFF=1; shift ;;
    --diff-context) DIFF_CONTEXT="$2"; shift 2 ;;
    --diff-max) DIFF_MAX_FILES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $TARGET_SET -eq 0 ]]; then
  DO_NOTMINE=1; DO_CONFIG=1
fi

# --- Helpers -----------------------------------------------------------------
log() { echo -e "[deploy] $*"; }
warn() { echo -e "[deploy:WARN] $*"; }
fail() { echo "[deploy:ERROR] $*" >&2; exit 1; }

trap 'fail "An unexpected error occurred (line $LINENO)."' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd rsync
require_cmd tar

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

  git -C "$PROJECT_ROOT" fetch "$remote" "$branch" || fail "git fetch failed."

  local upstream="$remote/$branch"
  if git -C "$PROJECT_ROOT" rev-parse "$upstream" >/dev/null 2>&1; then
    local counts
    counts=$(git -C "$PROJECT_ROOT" rev-list --left-right --count "$branch...$upstream" 2>/dev/null || echo "0	0")
    log "Git: ahead/behind (local...remote): $counts"
  fi

  if ! git -C "$PROJECT_ROOT" pull --ff-only "$remote" "$branch"; then
    fail "git pull failed (non fast-forward?). Resolve and retry or run with --no-git."
  fi
}

# rsync convenience
rsync_base=("-a" "--human-readable" "--info=stats1,NAME")
[[ $VERBOSE -eq 1 ]] && rsync_base+=("-v")
[[ $DRY_RUN -eq 1 ]] && rsync_base+=("-n")

# Excludes -> args
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
install_file_smart() {
  local src="$1"; local dest="$2"; local backup_root="$3"
  local name; name
  name=$(basename "$dest")

  if [[ ! -f "$src" ]]; then
    warn "Skip (source missing): $src"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -e "$dest" ]]; then
      if ! cmp -s "$src" "$dest"; then
        log "DRY-RUN: would back up $dest -> $backup_root/${name}.${TIMESTAMP}.bak"
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
      mkdir -p "$backup_root"
      local backup_path="$backup_root/${name}.${TIMESTAMP}.bak"
      if [[ -s "$dest" ]]; then
        cp -f -- "$dest" "$backup_path"
        log "Backed up $dest -> $backup_path"
      else
        log "Destination $dest is empty; skipping backup copy."
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

install_notmine() {
  local src_py="$REPO_NOTMINE_DIR/xplorer.py"
  local dest_py="$EXTRAS_DIR/xplorer.py"
  install_file_smart "$src_py" "$dest_py" "$NOTMINE_BACKUP_DIR"
}

# --- Diff helper -------------------------------------------------------------
show_preflight_diffs() {
  local preflight_out="$1"

  [[ $SHOW_DIFF -eq 1 ]] || return 0
  require_cmd diff

  # "file" is optional but helps skip binaries safely
  command -v file >/dev/null 2>&1 || warn "Command 'file' not found; will diff without binary detection."

  log "Diffs for changed files (repo -> printer):"

  local -a paths=()
  while IFS= read -r line; do
    # Only diff regular files that rsync will send (">f")
    [[ "$line" =~ ^\>f ]] || continue

    # Only diff when CONTENT likely changed: 'c' (checksum) or 's' (size).
    # Look ONLY at the 11-char itemize field (before the space), not the filename.
    local flags="${line:0:11}"
    [[ "$flags" == *c* || "$flags" == *s* ]] || continue

    # Path begins at column 13 (0-based index 12): 11 flags + space
    local path="${line:12}"
    path="${path#"${path%%[![:space:]]*}"}"
    [[ -n "$path" ]] && paths+=("$path")
  done <<< "$preflight_out"

  if [[ ${#paths[@]} -eq 0 ]]; then
    log "  (No content-changing regular files detected to diff.)"
    return 0
  fi

  local shown=0
  for p in "${paths[@]}"; do
    (( shown >= DIFF_MAX_FILES )) && { warn "Diff limit reached ($DIFF_MAX_FILES files)."; break; }

    local src="$REPO_CONFIG_DIR/$p"
    local dst="$KLIPPERCONFIG/$p"

    [[ -f "$src" ]] || continue
    [[ -f "$dst" ]] || { log "---- $p (new file)"; ((shown++)); continue; }

    # Skip binaries if we have `file`
    if command -v file >/dev/null 2>&1; then
      if file --mime "$src" "$dst" | grep -qi 'charset=binary'; then
        log "---- $p (binary; skipping diff)"
        ((shown++))
        continue
      fi
    fi

    log "---- $p"
    # diff order is: printer then repo, so:
    #  - lines are "removed from printer by deploy"
    #  + lines are "added from repo by deploy"
    diff -U "$DIFF_CONTEXT" --label "printer/$p" --label "repo/$p" "$dst" "$src" || true
    ((shown++))
  done
}

# --- Config deployment (tarball snapshots) -----------------------------------
snapshot_config_dir() {
  mkdir -p "$CONFIG_SNAPSHOT_DIR"
  log "Creating config snapshot: $CONFIG_SNAPSHOT_FILE"
  tar -C "$KLIPPERCONFIG" -czf "$CONFIG_SNAPSHOT_FILE" . || fail "Snapshot tar failed."
}

deploy_config() {
  [[ -d "$REPO_CONFIG_DIR" ]] || fail "Repo config directory not found: $REPO_CONFIG_DIR"

  local -a args=("${rsync_base[@]}" "--prune-empty-dirs")
  [[ $DELETE_FLAG -eq 1 ]] && args+=("--delete")
  args+=("${exclude_args[@]}")

  log "Deploying repo config -> $KLIPPERCONFIG"
  log "  delete: $([[ $DELETE_FLAG -eq 1 ]] && echo yes || echo no)"
  log "  snapshot: $([[ $DRY_RUN -eq 0 ]] && echo "$CONFIG_SNAPSHOT_FILE" || echo "(skipped: dry-run)")"

  # Safety: avoid destructive delete when source is empty unless explicitly confirmed
  if [[ $DELETE_FLAG -eq 1 && $DRY_RUN -eq 0 && $CONFIRM -eq 0 ]]; then
    if ! find "$REPO_CONFIG_DIR" -mindepth 1 -not -path '*/.git/*' -print -quit | grep -q .; then
      fail "Repo config directory appears empty; refusing to run rsync with --delete without --confirm. Re-run with --confirm or use --no-delete."
    fi
  fi

  # Preflight: rsync dry-run itemized
  local -a preflight_args=("${args[@]}")
  preflight_args+=("-n" "--itemize-changes")
  local preflight_out
  preflight_out=$(rsync "${preflight_args[@]}" "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/" || true)

  local deletes updates total
  deletes=$(echo "$preflight_out" | grep -c '^\*deleting ' || true)
  updates=$(echo "$preflight_out" | grep -E '^[<>cdhs\.].' | grep -v '^\*deleting ' | wc -l | tr -d ' ')
  total=$((deletes + updates))

  if [[ $DRY_RUN -eq 1 ]]; then
    log "Preflight summary: updates=$updates deletions=$deletes (total=$total)"
    [[ -n "$preflight_out" ]] && echo "$preflight_out"
    show_preflight_diffs "$preflight_out"
    return 0
  fi

  if (( total > 0 )); then
    log "Preflight summary: updates=$updates deletions=$deletes (total=$total)"
    if [[ $CONFIRM -eq 0 ]]; then
      confirm_with_message "About to apply the above changes to:\n  $KLIPPERCONFIG\nA tar snapshot will be created first at:\n  $CONFIG_SNAPSHOT_FILE\nUse --dry-run to preview or --no-delete to avoid deletions."
    fi
  else
    log "Preflight summary: no changes needed."
    return 0
  fi

  # Snapshot then deploy
  snapshot_config_dir
  rsync "${args[@]}" "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/"
  log "Config deployment complete. Snapshot saved at: $CONFIG_SNAPSHOT_FILE"
}

# --- Main --------------------------------------------------------------------
log "Repo:           $PROJECT_ROOT"
log "NotMine dir:    $REPO_NOTMINE_DIR"
log "Repo config:    $REPO_CONFIG_DIR"
log "Printer home:   $PRINTER_HOME"
log "Extras:         $EXTRAS_DIR"
log "Printer config: $KLIPPERCONFIG"
log "Snapshots root: $SNAPSHOT_ROOT"
log "Dry-run:        $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
log "Verbose:        $([[ $VERBOSE -eq 1 ]] && echo yes || echo no)"
log "Targets:        NotMine=$([[ $DO_NOTMINE -eq 1 ]] && echo yes || echo no), Config=$([[ $DO_CONFIG -eq 1 ]] && echo yes || echo no)"
log "Git preflight:  $([[ $GIT_PULL -eq 1 ]] && echo enabled || echo disabled)"

git_preflight
confirm_or_exit

if [[ $DO_NOTMINE -eq 1 ]]; then
  log "--- Deploy NotMine ---"
  install_notmine
fi

if [[ $DO_CONFIG -eq 1 ]]; then
  log "--- Deploy config ---"
  deploy_config
fi

# Restore stash if we made one
if [[ $STASH_MADE -eq 1 && $DRY_RUN -eq 0 ]]; then
  log "Git: restoring stashed changes"
  git -C "$PROJECT_ROOT" stash pop -q || warn "Git: failed to pop stash; your changes remain stashed."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry-run complete. No files were modified."
else
  log "Deployment complete."
fi
