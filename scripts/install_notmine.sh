#!/usr/bin/env bash
# Installs NotMine/xplorer.py into $HOME/klipper/klippy/extras
# and NotMine/variables.cfg into $HOME/printer_data/config/.
# If destination has a different version, back it up into NotMine/backup with a timestamp.
# Empty destination files are NOT backed up.

set -euo pipefail

# Resolve project directories
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)
SRC_DIR="$PROJECT_ROOT/NotMine"
BACKUP_DIR="$SRC_DIR/backup"

# Targets
HOME_DIR="${HOME}"
EXTRAS_DIR="$HOME_DIR/klipper/klippy/extras"
CONFIG_DIR="$HOME_DIR/printer_data/config"

mkdir -p "$BACKUP_DIR"

install_file() {
  local src="$1"
  local dest="$2"
  local name
  name=$(basename "$src")

  if [[ ! -f "$src" ]]; then
    echo "ERROR: Source file not found: $src" >&2
    return 1
  fi

  mkdir -p "$(dirname "$dest")"

  if [[ -e "$dest" ]]; then
    if ! cmp -s "$src" "$dest"; then
      if [[ -s "$dest" ]]; then
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        local backup_path="$BACKUP_DIR/${name}.${ts}.bak"
        cp -f -- "$dest" "$backup_path"
        echo "Backed up $dest to $backup_path"
      else
        echo "Destination $dest is empty; skipping backup."
      fi
      cp -f -- "$src" "$dest"
      echo "Updated $dest from $src"
    else
      echo "No changes for $name; already up to date."
    fi
  else
    cp -f -- "$src" "$dest"
    echo "Installed $dest"
  fi
}

# Install files
install_file "$SRC_DIR/xplorer.py" "$EXTRAS_DIR/xplorer.py"
install_file "$SRC_DIR/variables.cfg" "$CONFIG_DIR/variables.cfg"

echo "Installation complete."