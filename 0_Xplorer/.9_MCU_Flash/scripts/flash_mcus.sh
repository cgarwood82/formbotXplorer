#!/usr/bin/env bash
# Unified Klipper MCU flashing utility for Xplorer
# - Default: flash all active MCUs referenced by printer.cfg
# - Targeted: flash only specific MCUs via --targets mcu1,mcu2 or positional names
# - Dry run: --dry-run prints what would be flashed, sources, and reasons for any skips
# - Skips: beacon/cartographer devices are detected and skipped automatically
# - Sudo: requires passwordless sudo for make; script verifies before proceeding
# - Services: stops Klipper once before flashing, restarts at the end
#
# This script relies on per-board .config templates in .9_MCU_Flash/MCU_config
# and on per-MCU serial declarations in ~/printer_data/config/02__Boards_Serials/*.cfg
# Active MCUs are determined from ~/printer_data/config/printer.cfg

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
MCU_CFG_DIR="${REPO_ROOT}/.9_MCU_Flash/MCU_config"
PRINTER_CFG="${HOME}/printer_data/config/printer.cfg"
CONFIG_DIR="${HOME}/printer_data/config"
SERIALS_DIR="${HOME}/printer_data/config/02__Boards_Serials"
KLIPPER_DIR="${HOME}/klipper"

# ------------- Argument parsing -------------
DRY_RUN=0
TARGETS=()
KEEP_KLIPPER_RUNNING=0
DEBUG=0

print_usage() {
  cat <<'USAGE'
Usage: flash_mcus.sh [options] [mcu_name ...]

Options:
  --targets list    Comma-separated list of MCU names to flash (alternative to positional names)
  --dry-run         Do not flash; print detected MCUs, board mapping, config used, and actions
  --keep-klipper    Do not stop/start Klipper (useful for dry-run or manual control)
  --config path     Use an alternate printer.cfg (default: ~/printer_data/config/printer.cfg)
  --debug           Verbose discovery: show resolved includes and MCU source files
  -h, --help        Show this help

Notes:
- Active MCUs are discovered by reading printer.cfg and all included files (supports globs),
  then collecting [mcu] and [mcu <name>] sections.
- Per-MCU serial/CAN IDs are read from ~/printer_data/config/02__Boards_Serials/*.cfg files,
  which must each contain a single [mcu <name>] section and either a 'serial:' or 'canbus_uuid:' line.
- Board mapping is inferred heuristically from MCU name and/or the USB symlink path contents.
  You may need to adjust folder names in .9_MCU_Flash/MCU_config to fit your hardware.
- MCUs named or described as 'beacon' or 'cartographer' are skipped.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)
      IFS=',' read -r -a TARGETS <<< "$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --keep-klipper) KEEP_KLIPPER_RUNNING=1; shift ;;
    --config)
      PRINTER_CFG="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; print_usage; exit 2 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

# ------------- Helpers -------------
log() { echo -e "$*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; }

requires() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found in PATH"; exit 3; }
}

sanitize_name() {
  # lowercases and strips surrounding spaces
  local s="$1"; s="${s,,}"; s="${s// /}"; echo "$s"
}

is_forbidden_mcu_name() {
  local name_lc="$(sanitize_name "$1")"
  if [[ "$name_lc" == *"beacon"* || "$name_lc" == *"cartographer"* ]]; then
    return 0
  fi
  return 1
}

# Include resolution and MCU discovery
# Recursively resolve [include <path>] from a root cfg and echo file paths (unique by caller).
resolve_includes() {
  local root="$1"; local depth="${2:-0}"; local max_depth=6
  (( depth > max_depth )) && return 0
  [[ -f "$root" ]] || return 0
  echo "$root"
  # parse include lines not commented out
  while IFS= read -r line; do
    # strip inline comments
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*\[include[[:space:]]+([^\]]+)\][[:space:]]*$ ]] || continue
    local inc_path="${BASH_REMATCH[1]}"
    inc_path="${inc_path//\"/}"
    inc_path="${inc_path//\'/}"
    local expanded=()
    shopt -s nullglob
    if [[ "$inc_path" = /* ]]; then
      expanded=( $inc_path )
    else
      local base_dir; base_dir=$(dirname -- "$root")
      expanded=( "$base_dir"/$inc_path "$CONFIG_DIR"/$inc_path )
    fi
    for p in "${expanded[@]}"; do
      for f in $p; do
        [[ -f "$f" ]] || continue
        resolve_includes "$f" $((depth+1))
      done
    done
    shopt -u nullglob
  done < "$root"
}

# Extract active MCU names from a set of files; output lines "name|source"
extract_mcus_from_files() {
  local f
  for f in "$@"; do
    # Use sed to find lines beginning with [mcu or [mcu <name>] and extract the name
    sed -n \
      -e 's/#.*$//' \
      -e '/^[[:space:]]*\[mcu[[:space:]]*\]/!d' \
      -e 's/^[[:space:]]*\[mcu[[:space:]]*//' \
      -e 's/\].*$//' \
      -e 'p' "$f" | while IFS= read -r name; do
        # Trim leading/trailing spaces (POSIX-safe)
        name=${name#${name%%[![:space:]]*}}
        name=${name%${name##*[![:space:]]}}
        [[ -z "$name" ]] && name="mcu"
        printf '%s|%s\n' "$name" "$f"
      done
  done | sed '/^$/d'
}

# Return active MCUs by resolving includes; outputs "name|source"
get_active_mcus_from_printer_cfg() {
  [[ -f "$PRINTER_CFG" ]] || { err "printer.cfg not found at $PRINTER_CFG"; return 1; }
  # unique list of files
  mapfile -t files < <(resolve_includes "$PRINTER_CFG" | awk '!seen[$0]++')
  extract_mcus_from_files "${files[@]}" | awk -F'|' '!seen[$1]++'
}

# Helper to list resolved cfgs (for --debug)
list_resolved_cfgs() {
  [[ -f "$PRINTER_CFG" ]] || return 0
  resolve_includes "$PRINTER_CFG" | awk '!seen[$0]++'
}

# Read all serial config files and build mapping: name -> {type,id,file}
# Supports lines: serial: <path>   OR   canbus_uuid: <uuid>
collect_mcu_serials() {
  [[ -d "$SERIALS_DIR" ]] || { err "Serials directory not found: $SERIALS_DIR"; return 1; }
  shopt -s nullglob
  for f in "$SERIALS_DIR"/*.cfg; do
    # find the [mcu name]
    local sec name id type
    sec=$(awk '/^\[mcu/{print; exit}' "$f" 2>/dev/null || true)
    if [[ -z "$sec" ]]; then continue; fi
    name=$(echo "$sec" | sed -E 's/^\[mcu( |\])/?/; s/^\[mcu\]$/mcu/; s/^\[mcu //; s/\]$//')
    [[ -z "$name" ]] && name="mcu"
    # extract id
    id=$(awk -F':' '/^[[:space:]]*serial[[:space:]]*:/ {sub(/^[[:space:]]+/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$f" || true)
    if [[ -n "$id" ]]; then type="serial"; else
      id=$(awk -F':' '/^[[:space:]]*canbus_uuid[[:space:]]*:/ {sub(/^[[:space:]]+/,"",$2); gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' "$f" || true)
      [[ -n "$id" ]] && type="canbus" || type="unknown"
    fi
    echo "$name|$type|$id|$f"
  done
}

# Decide which board config folder to use for a given MCU based on name and id path
resolve_board_profile() {
  local name="$1"; local type="$2"; local id="$3"; local serial_cfg_file="$4"
  local name_lc="$(sanitize_name "$name")"
  local cfg_path=""; local note=""

  # Skip forbidden devices by name (handled earlier), but include rationale here if called directly
  if is_forbidden_mcu_name "$name"; then
    echo "|skip|forbidden device (beacon/cartographer)"
    return 0
  fi

  # 0) Explicit board hint in the serial cfg (comment or key) takes precedence
  local bhint
  bhint=$(extract_board_hint "$serial_cfg_file" || true)
  if [[ -n "$bhint" ]]; then
    if cfgp=$(profile_config_path "$bhint" 2>/dev/null); then
      echo "$cfgp|ok|$bhint (from board hint)"
      return 0
    else
      # If the hint does not match a folder, fall through to heuristics but keep a note
      note="(board hint '$bhint' not found under MCU_config)"
    fi
  fi

  # Heuristics by serial cfg filename
  local basefile
  basefile=$(basename -- "$serial_cfg_file" 2>/dev/null || echo "")
  local basefile_lc="$(sanitize_name "$basefile")"

  # Toolboards (EBB36)
  if [[ "$name_lc" == tool* || "$basefile_lc" == tool* || "$name_lc" == *ebb* ]]; then
    cfg_path="${MCU_CFG_DIR}/BTT_EBB36/.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|BTT EBB36 ${note}"; return 0; }
  fi

  # Fysetc Hexa probes
  if [[ "$name_lc" == *hexa* || "$basefile_lc" == *hexa* ]]; then
    # Prefer klipper.config for normal flashing
    cfg_path="${MCU_CFG_DIR}/Fysetc_Hexa/klipper.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|Fysetc Hexa ${note}"; return 0; }
  fi

  # Fysetc H36
  if [[ "$name_lc" == *h36* || "$basefile_lc" == *h36* ]]; then
    cfg_path="${MCU_CFG_DIR}/Fysetc_H36/klipper.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|Fysetc H36 ${note}"; return 0; }
  fi

  # Mainboard (Manta M8P variants)
  if [[ "$name_lc" == m1 || "$name_lc" == mcu || "$name_lc" == main* || "$basefile_lc" == main* ]]; then
    # Try to detect V1.1 vs V2.0 via the usb symlink name: stm32f072 => V1.1, stm32g0* => V2.0
    local id_lc="$(sanitize_name "$id")"
    local folder=""
    if [[ "$id_lc" == *stm32f072* ]]; then
      folder="BTT_Manta_M8P_V1.1"
    elif [[ "$id_lc" == *stm32g0* || "$id_lc" == *g0b1* ]]; then
      folder="BTT_Manta_M8P_V2.0"
    else
      # Unknown: prefer V2.0 but warn
      folder="BTT_Manta_M8P_V2.0"; note="(unknown chip in serial path; defaulting to V2.0) ${note}"
    fi
    cfg_path="${MCU_CFG_DIR}/${folder}/.config"
    if [[ -f "$cfg_path" ]]; then
      echo "$cfg_path|ok|BTT Manta M8P ${folder#BTT_Manta_M8P_} ${note}"
      return 0
    fi
  fi

  # Fallback: unknown
  echo "|unknown|No matching board profile for MCU '$name' (id: $id) ${note}"
}

# Verify passwordless sudo (no prompt) for 'make'.
check_passwordless_sudo() {
  if sudo -n true 2>/dev/null && (cd "$KLIPPER_DIR" && sudo -n make --version >/dev/null 2>&1); then
    return 0
  fi
  return 1
}

# ------------- Discovery -------------
requires awk; requires sed; requires grep; requires make

# Katapult detection (for CAN bus flashing)
KATAPULT_DIR="${HOME}/katapult"
KATAPULT_FLASH="${KATAPULT_DIR}/scripts/flash_can.py"
KATAPULT_FOUND=0
if [[ -f "$KATAPULT_FLASH" ]]; then
  KATAPULT_FOUND=1
fi

# Helper: parse a single serial cfg file for name + id (POSIX-safe; no awk regex captures)
# Outputs: name|type|id|file (or nothing if not found)
parse_serial_cfg_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local name id type
  # Extract the [mcu] or [mcu Name] first occurrence
  name=$(sed -n \
    -e 's/#.*$//' \
    -e '/^[[:space:]]*\[mcu/!d' \
    -e 's/^[[:space:]]*\[mcu[[:space:]]*//' \
    -e 's/\].*$//' \
    -e 'p;q' "$f")
  [[ -z "$name" ]] && name="mcu"

  # serial or canbus_uuid (first match wins)
  id=$(sed -n \
    -e 's/#.*$//' \
    -e '/^[[:space:]]*serial[[:space:]]*:/!d' \
    -e 's/^[^:]*:[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 'p;q' "$f")
  if [[ -n "$id" ]]; then
    type="serial"
  else
    id=$(sed -n \
      -e 's/#.*$//' \
      -e '/^[[:space:]]*canbus_uuid[[:space:]]*:/!d' \
      -e 's/^[^:]*:[[:space:]]*//' \
      -e 's/[[:space:]]*$//' \
      -e 'p;q' "$f")
    if [[ -n "$id" ]]; then
      type="canbus"
    else
      return 0
    fi
  fi
  echo "${name}|${type}|${id}|${f}"
}

# Determine which serial cfg files are actually included by printer.cfg
# Strategy:
# 1) Use recursive include resolver and keep only files under SERIALS_DIR
# 2) Additionally, parse include lines in printer.cfg and all top-level cfgs under CONFIG_DIR
#    to find includes that reference 02__Boards_Serials, to handle cases when recursive
#    resolution misses them due to path/working-dir peculiarities.
mapfile -t RESOLVED_CFGS < <(list_resolved_cfgs | awk '!seen[$0]++')

# Helper: extract serial include targets from a single cfg file
extract_serial_includes_from_file() {
  local root="$1"
  [[ -f "$root" ]] || return 0
  local base
  base=$(dirname -- "$root")
  # Grab only include lines that reference 02__Boards_Serials
  while IFS= read -r inc; do
    # Normalize quotes
    inc=${inc%]}            # drop trailing ] if any leftover
    inc=${inc#*[include }   # drop prefix up to include
    inc=${inc#*[include	}  # tabs variant (harmless if not present)
    inc=${inc//\"/}
    inc=${inc//\'/}
    # Only consider entries that contain the serials folder
    [[ "$inc" == *"02__Boards_Serials/"* ]] || continue
    # If absolute path
    if [[ "$inc" = /* ]]; then
      [[ -f "$inc" ]] && echo "$inc"
    else
      # Remove leading ./ if present
      inc=${inc#./}
      [[ -f "$base/$inc" ]] && echo "$base/$inc"
      [[ -f "$CONFIG_DIR/$inc" ]] && echo "$CONFIG_DIR/$inc"
    fi
  done < <(sed -n -e 's/#.*$//' -e '/^[[:space:]]*\[include[[:space:]]\{1,\}[^]]*02__Boards_Serials\//p' "$root")
}

# Collect included serial files
INCLUDED_SERIAL_FILES=()
# 1) From resolved includes tree (be tolerant of path forms like /./ in the path)
for f in "${RESOLVED_CFGS[@]}"; do
  # Normalize simple /./ occurrences
  fnorm=${f//\/\.\//\/}
  # Accept any path that contains the serials subfolder
  if [[ "$fnorm" == *"/02__Boards_Serials/"* ]]; then
    INCLUDED_SERIAL_FILES+=("$f")
  fi
done
# 2) From direct parsing of include lines in printer.cfg
while IFS= read -r p; do INCLUDED_SERIAL_FILES+=("$p"); done < <(extract_serial_includes_from_file "$PRINTER_CFG")
# 3) From direct parsing of include lines in all top-level *.cfg files under CONFIG_DIR (user provided pattern)
shopt -s nullglob
for top in "$CONFIG_DIR"/*.cfg; do
  while IFS= read -r p; do INCLUDED_SERIAL_FILES+=("$p"); done < <(extract_serial_includes_from_file "$top")
done
shopt -u nullglob

# Deduplicate
mapfile -t INCLUDED_SERIAL_FILES < <(printf '%s\n' "${INCLUDED_SERIAL_FILES[@]}" | awk 'NF&&!seen[$0]++')

if [[ ${#INCLUDED_SERIAL_FILES[@]} -eq 0 ]]; then
  warn "No serial cfg files from ${SERIALS_DIR} are included by ${PRINTER_CFG}."
fi

# Build map of MCUs strictly from included serial cfg files
declare -A MCU_TYPE MCU_ID MCU_CFGFILE MCU_SOURCE MCU_BOARD_HINT

# Extract optional board hint from a serial cfg file.
# Supports either a comment:  # board: Fysetc_H36
# or a key:                   board_profile: Fysetc_H36
extract_board_hint() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # Try key first
  local hint
  hint=$(sed -n \
    -e 's/#.*$//' \
    -e '/^[[:space:]]*board_profile[[:space:]]*:/!d' \
    -e 's/^[^:]*:[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 'p;q' "$f")
  if [[ -n "$hint" ]]; then echo "$hint"; return 0; fi
  # Then comment form
  hint=$(sed -n \
    -e '/^[[:space:]]*#[[:space:]]*board[[:space:]]*:/!d' \
    -e 's/^[^:]*:[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 'p;q' "$f")
  [[ -n "$hint" ]] && echo "$hint" || true
}

# Return full path to the board profile's klipper config file.
# Preference order inside a profile folder: klipper.config, .config
profile_config_path() {
  local profile="$1"
  local dir="${MCU_CFG_DIR}/${profile}"
  if [[ -d "$dir" ]]; then
    if [[ -f "$dir/klipper.config" ]]; then
      echo "$dir/klipper.config"; return 0
    fi
    if [[ -f "$dir/.config" ]]; then
      echo "$dir/.config"; return 0
    fi
  fi
  return 1
}

PARSE_DEBUG_LINES=()
for f in "${INCLUDED_SERIAL_FILES[@]}"; do
  line=$(parse_serial_cfg_file "$f" || true)
  if [[ -z "$line" ]]; then
    PARSE_DEBUG_LINES+=("$f => <no id found>")
    continue
  fi
  IFS='|' read -r name type id file <<< "$line"
  MCU_TYPE["$name"]="$type"
  MCU_ID["$name"]="$id"
  MCU_CFGFILE["$name"]="$file"
  MCU_SOURCE["$name"]="$file"
  # Capture optional board hint
  bhint=$(extract_board_hint "$file" || true)
  if [[ -n "$bhint" ]]; then
    MCU_BOARD_HINT["$name"]="$bhint"
    PARSE_DEBUG_LINES+=("$f => name=$name type=$type id=$id board=$bhint")
  else
    PARSE_DEBUG_LINES+=("$f => name=$name type=$type id=$id")
  fi

done

# Active MCUs are those included serial cfgs we parsed
ACTIVE_MCU_LIST=()
for n in "${!MCU_TYPE[@]}"; do
  ACTIVE_MCU_LIST+=("$n")
done

# If specific targets are provided, use those; else default to active list
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("${ACTIVE_MCU_LIST[@]}")
fi

# Debug info on discovery
if [[ $DEBUG -eq 1 ]]; then
  echo "[DEBUG] Resolved config files:"
  list_resolved_cfgs | sed 's/^/  - /'
  echo "[DEBUG] Included serial cfgs:"
  for f in "${INCLUDED_SERIAL_FILES[@]}"; do echo "  - $f"; done
  # Per-file parse results
  if [[ ${#PARSE_DEBUG_LINES[@]} -gt 0 ]]; then
    echo "[DEBUG] Parsed serial cfgs:"
    for l in "${PARSE_DEBUG_LINES[@]}"; do echo "  - $l"; done
  fi
  echo "[DEBUG] Active MCUs discovered (name -> source):"
  for n in "${ACTIVE_MCU_LIST[@]}"; do
    echo "  - $n -> ${MCU_SOURCE[$n]:-unknown}"
  done
fi

# Deduplicate targets while preserving order
DEDUP_TARGETS=()
seen="|"
for t in "${TARGETS[@]}"; do
  [[ -z "$t" ]] && continue
  if [[ "$seen" != *"|$t|"* ]]; then DEDUP_TARGETS+=("$t"); seen+="$t|"; fi
done
TARGETS=("${DEDUP_TARGETS[@]}")

# Build final plan per target
PLAN_ROWS=()
for name in "${TARGETS[@]}"; do
  if is_forbidden_mcu_name "$name"; then
    PLAN_ROWS+=("$name|skip|forbidden by policy (beacon/cartographer)")
    continue
  fi
  if [[ -z "${MCU_TYPE[$name]:-}" ]]; then
    PLAN_ROWS+=("$name|skip|no serial cfg found in ${SERIALS_DIR}")
    continue
  fi
  prof=$(resolve_board_profile "$name" "${MCU_TYPE[$name]}" "${MCU_ID[$name]}" "${MCU_CFGFILE[$name]}")
  IFS='|' read -r cfg_path status detail <<< "$prof"
  if [[ "$status" != "ok" ]]; then
    PLAN_ROWS+=("$name|skip|$detail")
    continue
  fi
  # Enforce Katapult for CAN devices
  if [[ "${MCU_TYPE[$name]}" == "canbus" ]]; then
    if [[ $KATAPULT_FOUND -ne 1 ]]; then
      PLAN_ROWS+=("$name|skip|Katapult not found at ${KATAPULT_FLASH}; required for CAN flashing")
      continue
    fi
  fi
  PLAN_ROWS+=("$name|flash|$cfg_path|${MCU_TYPE[$name]}|${MCU_ID[$name]}|$detail")
done

# ------------- Dry run output -------------
print_plan() {
  echo "Detected targets:" 
  for row in "${PLAN_ROWS[@]}"; do
    IFS='|' read -r name action a b c d <<< "$row"
    local src="${MCU_SOURCE[$name]:-unknown}"
    if [[ "$action" == "flash" ]]; then
      local cfg="$a"; local type="$b"; local id="$c"; local board="$d"
      echo "  - $name => FLASH"
      echo "      source: $src"
      echo "      board: $board"
      echo "      config: $cfg"
      echo "      bus: $type"
      if [[ "$type" == "serial" ]]; then
        echo "      device: $id"
        echo "      flash: Klipper make flash"
      elif [[ "$type" == "canbus" ]]; then
        echo "      canbus_uuid: $id"
        if [[ $KATAPULT_FOUND -eq 1 ]]; then
          echo "      flash: Katapult (${KATAPULT_FLASH})"
        else
          echo "      flash: MISSING Katapult at ${KATAPULT_FLASH} (required)"
        fi
      fi
    else
      echo "  - $name => SKIP"
      echo "      source: $src"
      echo "      reason: $a"
    fi
  done
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY RUN] No changes will be made."
  print_plan
  exit 0
fi

# ------------- Pre-checks -------------
if [[ ${#PLAN_ROWS[@]} -eq 0 ]]; then
  echo "Nothing to do. No valid targets resolved."
  exit 0
fi

# Determine if any CAN devices will be flashed and validate Katapult/python3
HAS_CAN_FLASH=0
for row in "${PLAN_ROWS[@]}"; do
  IFS='|' read -r _ action _ type _ _ <<< "$row"
  if [[ "$action" == "flash" && "$type" == "canbus" ]]; then
    HAS_CAN_FLASH=1; break
  fi
done
if [[ $HAS_CAN_FLASH -eq 1 ]]; then
  if [[ $KATAPULT_FOUND -ne 1 ]]; then
    err "Katapult required for CAN flashing but not found at ${KATAPULT_FLASH}. Aborting."
    exit 11
  fi
  requires python3
fi

# Require passwordless sudo
if ! check_passwordless_sudo; then
  err "Passwordless sudo for 'make' is required. Configure your user in sudoers, e.g.:
  <username> ALL=(ALL) NOPASSWD: /usr/bin/make
Then re-run this script. Aborting."
  exit 10
fi

# ------------- Flashing -------------

stop_klipper() {
  if systemctl is-active --quiet klipper; then
    sudo -n systemctl stop klipper || sudo -n service klipper stop || true
  fi
}
start_klipper() {
  sudo -n systemctl start klipper 2>/dev/null || sudo -n service klipper start 2>/dev/null || true
}

if [[ $KEEP_KLIPPER_RUNNING -eq 0 ]]; then
  log "Stopping Klipper service..."
  stop_klipper
fi

mkdir -p "$KLIPPER_DIR"

overall_ok=0
for row in "${PLAN_ROWS[@]}"; do
  IFS='|' read -r name action cfg type id board <<< "$row"
  if [[ "$action" != "flash" ]]; then
    log "Skipping $name: $cfg"
    continue
  fi

  if [[ ! -f "$cfg" ]]; then
    warn "Config not found for $name: $cfg"
    continue
  fi

  log "\n=== $name: Building firmware (${board}) ==="
  cp -f "$cfg" "$KLIPPER_DIR/.config"
  pushd "$KLIPPER_DIR" >/dev/null
  make olddefconfig
  make clean
  make -j$(nproc)

  log "Flashing $name ..."
  if [[ "$type" == "serial" ]]; then
    sudo -n make flash FLASH_DEVICE="$id"
  elif [[ "$type" == "canbus" ]]; then
    FW_BIN="$KLIPPER_DIR/out/klipper.bin"
    if [[ ! -f "$FW_BIN" ]]; then
      warn "Firmware binary not found for $name at $FW_BIN; skipping"
      popd >/dev/null
      continue
    fi
    log "Using Katapult to flash CAN device (uuid=$id)"
    python3 "$KATAPULT_FLASH" -u "$id" "$FW_BIN"
  else
    warn "Unknown bus type for $name; skipping"
    popd >/dev/null
    continue
  fi
  popd >/dev/null
  overall_ok=1
  # small delay between flashes
  sleep 3

done

if [[ $KEEP_KLIPPER_RUNNING -eq 0 ]]; then
  log "Starting Klipper service..."
  start_klipper
fi

print_plan

if [[ $overall_ok -eq 1 ]]; then
  log "\nFirmware flashing complete."
else
  log "\nNo firmware was flashed."
fi
