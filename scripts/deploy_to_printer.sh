#!/usr/bin/env bash
# Deploy changes from this repo to the printer.
# - Deploys NotMine artifacts and/or the repo's ./config tree
# - Uses a single tarball snapshot backup for the printer config dir before applying changes
# - Keeps backups OUT of the repo and OUT of ~/printer_data/config
#
# Requirements: rsync, tar, diff; git optional unless --no-git

set -euo pipefail

# ------------------------- Paths -------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

REPO_NOTMINE_DIR="${REPO_NOTMINE_DIR:-$PROJECT_ROOT/NotMine}"
REPO_CONFIG_DIR="${REPO_CONFIG_DIR:-$PROJECT_ROOT/config}"

PRINTER_HOME="${PRINTER_HOME:-$HOME}"
EXTRAS_DIR="${EXTRAS_DIR:-$PRINTER_HOME/klipper/klippy/extras}"
KLIPPERCONFIG="${KLIPPERCONFIG:-$PRINTER_HOME/printer_data/config}"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-$PRINTER_HOME/.deploy_snapshots}"
CONFIG_SNAPSHOT_DIR="$SNAPSHOT_ROOT/klipper_config"
CONFIG_SNAPSHOT_FILE="$CONFIG_SNAPSHOT_DIR/config_${TIMESTAMP}.tgz"

NOTMINE_BACKUP_DIR="${NOTMINE_BACKUP_DIR:-$SNAPSHOT_ROOT/notmine_files/$TIMESTAMP}"

# ------------------------- Options -------------------------
DO_NOTMINE=0
DO_CONFIG=0
DRY_RUN=0
DELETE_FLAG=1
VERBOSE=0
CONFIRM=0

GIT_PULL=1
GIT_REMOTE=""
GIT_BRANCH=""
ALLOW_DIRTY=0
AUTO_STASH=0

SHOW_DIFF=0
DIFF_CONTEXT=3
DIFF_MAX_FILES=200

EXCLUDES=(
  "0_Xplorer/"
  ".deploy_backups/"
)

# ------------------------- Helpers -------------------------
log()  { echo -e "[deploy] $*"; }
warn() { echo -e "[deploy:WARN] $*"; }
fail() { echo -e "[deploy:ERROR] $*" >&2; exit 1; }

trap 'fail "Unexpected error on line $LINENO."' ERR

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd rsync
require_cmd tar
require_cmd diff

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--all|--notmine|--config] [options]

Targets (default: --all):
  --all            Deploy NotMine and config
  --notmine        Deploy only NotMine (xplorer.py)
  --config         Deploy only repo ./config

Options:
  --dry-run        Show what would change (no modifications)
  --diff           In dry-run, show unified diffs for changed files
  --diff-context N Diff context lines (default: 3)
  --diff-max N     Max files to diff (default: 200)
  --no-delete      Do not delete printer files missing from repo config
  --verbose        Verbose rsync
  --confirm        Ask for confirmation before modifying anything

Git options:
  --no-git         Skip git checks/pull
  --git-remote R   Remote for pull
  --git-branch B   Branch for pull
  --allow-dirty    Proceed with uncommitted changes
  --stash          Auto-stash before pull and pop after

Env overrides:
  REPO_NOTMINE_DIR, REPO_CONFIG_DIR, PRINTER_HOME, EXTRAS_DIR, KLIPPERCONFIG,
  SNAPSHOT_ROOT, NOTMINE_BACKUP_DIR
USAGE
}

confirm_or_exit() {
  [[ $CONFIRM -eq 1 && $DRY_RUN -eq 0 ]] || return 0
  read -r -p "Proceed with deployment? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) log "Cancelled."; exit 0 ;;
  esac
}

# ------------------------- Arg parsing -------------------------
TARGET_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) DO_NOTMINE=1; DO_CONFIG=1; TARGET_SET=1; shift ;;
    --notmine) DO_NOTMINE=1; DO_CONFIG=0; TARGET_SET=1; shift ;;
    --config) DO_NOTMINE=0; DO_CONFIG=1; TARGET_SET=1; shift ;;

    --dry-run) DRY_RUN=1; shift ;;
    --diff) SHOW_DIFF=1; shift ;;
    --diff-context) DIFF_CONTEXT="$2"; shift 2 ;;
    --diff-max) DIFF_MAX_FILES="$2"; shift 2 ;;
    --no-delete) DELETE_FLAG=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --confirm) CONFIRM=1; shift ;;

    --no-git) GIT_PULL=0; shift ;;
    --git-remote) GIT_REMOTE="$2"; shift 2 ;;
    --git-branch) GIT_BRANCH="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --stash) AUTO_STASH=1; shift ;;

    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

if [[ $TARGET_SET -eq 0 ]]; then
  DO_NOTMINE=1; DO_CONFIG=1
fi

# ------------------------- Git preflight -------------------------
STASH_MADE=0

is_git_repo() { git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
current_branch() { git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null; }

choose_git_remote() {
  if [[ -n "$GIT_REMOTE" ]]; then echo "$GIT_REMOTE"; return; fi
  if git -C "$PROJECT_ROOT" remote | grep -q '^origin$'; then echo origin; return; fi
  git -C "$PROJECT_ROOT" remote 2>/dev/null | head -n1
}

git_preflight() {
  [[ $GIT_PULL -eq 1 ]] || return 0
  if ! is_git_repo; then
    warn "Not a git repo; skipping git pull."
    return 0
  fi
  require_cmd git

  local branch remote
  branch=${GIT_BRANCH:-$(current_branch)}
  remote=$(choose_git_remote)

  [[ -n "$branch" && -n "$remote" ]] || { warn "Cannot determine git remote/branch; skipping."; return 0; }

  log "Git: branch=$branch remote=$remote (preflight)"

  if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
    if [[ $AUTO_STASH -eq 1 && $DRY_RUN -eq 0 ]]; then
      git -C "$PROJECT_ROOT" stash push -u -k -m "deploy_to_printer autostash $TIMESTAMP" >/dev/null || true
      STASH_MADE=1
      log "Git: stashed local changes"
    elif [[ $ALLOW_DIRTY -eq 1 ]]; then
      warn "Git: dirty tree allowed (--allow-dirty)"
    else
      fail "Git working tree dirty. Use --allow-dirty or --stash."
    fi
  fi

  git -C "$PROJECT_ROOT" fetch "$remote" "$branch" || fail "git fetch failed"
  if ! git -C "$PROJECT_ROOT" pull --ff-only "$remote" "$branch"; then
    fail "git pull failed (non-fast-forward). Use --no-git or fix branch."
  fi
}

# ------------------------- NotMine deploy -------------------------
install_notmine() {
  local src_py="$REPO_NOTMINE_DIR/xplorer.py"
  local dst_py="$EXTRAS_DIR/xplorer.py"

  [[ -f "$src_py" ]] || { warn "Skip NotMine (missing): $src_py"; return 0; }

  mkdir -p "$EXTRAS_DIR" "$NOTMINE_BACKUP_DIR"

  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ -f "$dst_py" ]] && cmp -s "$src_py" "$dst_py"; then
      log "DRY-RUN: xplorer.py already up to date"
    else
      log "DRY-RUN: would install/update xplorer.py -> $dst_py"
    fi
    return 0
  fi

  if [[ -f "" ]] && ! cmp -s "" ""; then
    cp -f "$dst_py" "$NOTMINE_BACKUP_DIR/xplorer.py.${TIMESTAMP}.bak" || true
  fi

  cp -f "$src_py" "$dst_py"
  log "Installed NotMine: $dst_py"
}

# ------------------------- Snapshot -------------------------
snapshot_config_dir() {
  mkdir -p "$CONFIG_SNAPSHOT_DIR"
  log "Creating config snapshot: $CONFIG_SNAPSHOT_FILE"
  tar -C "$KLIPPERCONFIG" -czf "$CONFIG_SNAPSHOT_FILE" . || fail "Snapshot tar failed."
}

# ------------------------- Diff listing (robust) -------------------------
# We use rsync --out-format to emit ONLY the changed file path, one per line.
# This avoids parsing itemize glyphs entirely.
collect_changed_files() {
  local -a rsync_args=()
  rsync_args+=("-a" "--prune-empty-dirs")
  [[ $DELETE_FLAG -eq 1 ]] && rsync_args+=("--delete")
  [[ $VERBOSE -eq 1 ]] && rsync_args+=("-v")

  for ex in "${EXCLUDES[@]}"; do
    rsync_args+=("--exclude=$ex")
  done

  # Only list files that would be sent (non-deletions). Out-format prints "%n" = filename.
  rsync "${rsync_args[@]}" -n \
    --out-format='%n' \
    "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/" \
  | sed '/^$/d'
}

show_diffs_for_changed_files() {
  local -a files=()
  mapfile -t files < <(collect_changed_files)

  if [[ ${#files[@]} -eq 0 ]]; then
    log "Diffs: (no files would be updated)"
    return 0
  fi

  log "Diffs for changed files (repo -> printer):"

  local shown=0
  for p in "${files[@]}"; do
    (( shown >= DIFF_MAX_FILES )) && { warn "Diff limit reached ($DIFF_MAX_FILES files)."; break; }

    local src="$REPO_CONFIG_DIR/$p"
    local dst="$KLIPPERCONFIG/$p"

    [[ -f "$src" ]] || continue

    if [[ ! -f "$dst" ]]; then
      log "---- $p (new file on deploy)"
      ((shown++))
      continue
    fi

    log "---- $p"
    set +e
    diff -U "$DIFF_CONTEXT" --label "printer/$p" --label "repo/$p" "$dst" "$src"
    set -e
    ((shown++))
  done
}

# ------------------------- Config deploy -------------------------
deploy_config() {
  [[ -d "$REPO_CONFIG_DIR" ]] || fail "Repo config directory missing: $REPO_CONFIG_DIR"
  mkdir -p "$KLIPPERCONFIG"

  local -a args=()
  args+=("-a" "--prune-empty-dirs" "--human-readable" "--info=stats1,NAME")
  [[ $VERBOSE -eq 1 ]] && args+=("-v")
  [[ $DRY_RUN -eq 1 ]] && args+=("-n")
  [[ $DELETE_FLAG -eq 1 ]] && args+=("--delete")
  for ex in "${EXCLUDES[@]}"; do
    args+=("--exclude=$ex")
  done

  log "Deploying repo config -> $KLIPPERCONFIG"
  log "  delete: $([[ $DELETE_FLAG -eq 1 ]] && echo yes || echo no)"
  log "  snapshot: $([[ $DRY_RUN -eq 0 ]] && echo "$CONFIG_SNAPSHOT_FILE" || echo "(skipped: dry-run)")"

  # Always show the rsync itemized preview (helpful regardless)
  local preview
  preview=$(rsync "${args[@]}" --itemize-changes "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/" || true)

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "$preview"
    if [[ $SHOW_DIFF -eq 1 ]]; then
      show_diffs_for_changed_files
    fi
    return 0
  fi

  confirm_or_exit
  snapshot_config_dir
  rsync "${args[@]}" "$REPO_CONFIG_DIR/" "$KLIPPERCONFIG/"
  log "Config deployment complete. Snapshot saved at: $CONFIG_SNAPSHOT_FILE"
}

# ------------------------- Main -------------------------
log "Repo:           $PROJECT_ROOT"
log "Repo config:    $REPO_CONFIG_DIR"
log "Printer config: $KLIPPERCONFIG"
log "Snapshots root: $SNAPSHOT_ROOT"
log "Dry-run:        $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
log "Targets:        NotMine=$([[ $DO_NOTMINE -eq 1 ]] && echo yes || echo no), Config=$([[ $DO_CONFIG -eq 1 ]] && echo yes || echo no)"

git_preflight

if [[ $DO_NOTMINE -eq 1 ]]; then
  log "--- Deploy NotMine ---"
  install_notmine
fi

if [[ $DO_CONFIG -eq 1 ]]; then
  log "--- Deploy config ---"
  deploy_config
fi

if [[ $STASH_MADE -eq 1 && $DRY_RUN -eq 0 ]]; then
  log "Git: restoring stashed changes"
  git -C "$PROJECT_ROOT" stash pop -q || warn "Git: stash pop failed; changes remain stashed."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "Dry-run complete. No files were modified."
else
  log "Deployment complete."
fi
