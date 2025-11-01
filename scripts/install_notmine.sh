#!/usr/bin/env bash
# Wrapper script for backward compatibility.
# This now delegates to scripts/deploy_to_printer.sh --notmine
# so NotMine artifacts are deployed with the unified workflow
# (including backups, dry-run, verbosity, etc.).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

DEPLOY="$PROJECT_ROOT/scripts/deploy_to_printer.sh"

if [[ ! -x "$DEPLOY" ]]; then
  echo "ERROR: deploy_to_printer.sh not found or not executable: $DEPLOY" >&2
  echo "Please ensure the file exists and is executable." >&2
  exit 1
fi

echo "[install_notmine] This script is deprecated; forwarding to deploy_to_printer.sh --notmine"
exec "$DEPLOY" --notmine "$@"