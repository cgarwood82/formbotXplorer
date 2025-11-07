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
SERIALS_DIR="${HOME}/printer_data/config/02__Boards_Serials"
KLIPPER_DIR="${HOME}/klipper"

# ------------- Argument parsing -------------
DRY_RUN=0
TARGETS=()
KEEP_KLIPPER_RUNNING=0

print_usage() {
  cat <<'USAGE'
Usage: flash_mcus.sh [options] [mcu_name ...]

Options:
  --targets list    Comma-separated list of MCU names to flash (alternative to positional names)
  --dry-run         Do not flash; print detected MCUs, board mapping, config used, and actions
  --keep-klipper    Do not stop/start Klipper (useful for dry-run or manual control)
  -h, --help        Show this help

Notes:
- Active MCUs are discovered by reading ~/printer_data/config/printer.cfg.
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

# Extract active MCU names from printer.cfg ([mcu] and [mcu name])
get_active_mcus_from_printer_cfg() {
  [[ -f "$PRINTER_CFG" ]] || { err "printer.cfg not found at $PRINTER_CFG"; return 1; }
  awk '
    BEGIN{insec=0}
    /^\s*\[/ {insec=1; sec=$0}
    insec && /^\s*\[mcu(\s|\])/ {
      # [mcu] => name="mcu" ; [mcu foo] => name=foo
      name="mcu"
      if ($0 ~ /\[mcu[[:space:]]+/) {
        sub(/^\[mcu[[:space:]]+/, "", $0)
        sub(/\].*$/, "", $0)
        name=$0
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      print name
      insec=0
    }
  ' "$PRINTER_CFG" | sed '/^$/d' | sort -u
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

  # Heuristics by serial cfg filename
  local basefile
  basefile=$(basename -- "$serial_cfg_file" 2>/dev/null || echo "")
  local basefile_lc="$(sanitize_name "$basefile")"

  # Toolboards (EBB36)
  if [[ "$name_lc" == tool* || "$basefile_lc" == tool* || "$name_lc" == *ebb* ]]; then
    cfg_path="${MCU_CFG_DIR}/BTT_EBB36/.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|BTT EBB36"; return 0; }
  fi

  # Fysetc Hexa probes
  if [[ "$name_lc" == *hexa* || "$basefile_lc" == *hexa* ]]; then
    # Prefer klipper.config for normal flashing
    cfg_path="${MCU_CFG_DIR}/Fysetc_Hexa/klipper.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|Fysetc Hexa"; return 0; }
  fi

  # Fysetc H36
  if [[ "$name_lc" == *h36* || "$basefile_lc" == *h36* ]]; then
    cfg_path="${MCU_CFG_DIR}/Fysetc_H36/klipper.config"
    [[ -f "$cfg_path" ]] && { echo "$cfg_path|ok|Fysetc H36"; return 0; }
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
      folder="BTT_Manta_M8P_V2.0"; note="(unknown chip in serial path; defaulting to V2.0)"
    fi
    cfg_path="${MCU_CFG_DIR}/${folder}/.config"
    if [[ -f "$cfg_path" ]]; then
      echo "$cfg_path|ok|BTT Manta M8P ${folder#BTT_Manta_M8P_} ${note}"
      return 0
    fi
  fi

  # Fallback: unknown
  echo "|unknown|No matching board profile for MCU '$name' (id: $id)"
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

# Build map of serial configs
declare -A MCU_TYPE MCU_ID MCU_CFGFILE
while IFS='|' read -r name type id file; do
  [[ -z "$name" ]] && continue
  MCU_TYPE["$name"]="$type"
  MCU_ID["$name"]="$id"
  MCU_CFGFILE["$name"]="$file"
done < <(collect_mcu_serials)

if [[ ${#MCU_TYPE[@]} -eq 0 ]]; then
  warn "No MCU serial config files found in $SERIALS_DIR"
fi

# Determine active MCUs from printer.cfg
ACTIVE_MCU_LIST=()
while IFS= read -r n; do ACTIVE_MCU_LIST+=("$n"); done < <(get_active_mcus_from_printer_cfg || true)

if [[ ${#ACTIVE_MCU_LIST[@]} -eq 0 ]]; then
  warn "No active MCUs found in $PRINTER_CFG; nothing to do unless targets are provided."
fi

# If specific targets are provided, use those; else default to active list
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("${ACTIVE_MCU_LIST[@]}")
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
    if [[ "$action" == "flash" ]]; then
      local cfg="$a"; local type="$b"; local id="$c"; local board="$d"
      echo "  - $name => FLASH"
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
