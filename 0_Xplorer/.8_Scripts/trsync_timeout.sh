#!/bin/bash

KLIPPER_DIR="/home/biqu/klipper"
TARGET_FILE="$KLIPPER_DIR/klippy/mcu.py"

if grep -q "TRSYNC_TIMEOUT = 0.025" "$TARGET_FILE"; then
  echo "[PATCH] Applying TRSYNC_TIMEOUT = 0.050..."
  sed -i 's/TRSYNC_TIMEOUT = 0.025/TRSYNC_TIMEOUT = 0.050/' "$TARGET_FILE"
else
  echo "[PATCH] Already applied. Skipping."
fi
