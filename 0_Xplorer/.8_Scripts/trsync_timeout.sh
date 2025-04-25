#!/bin/bash

KLIPPER_DIR="/home/pi/klipper"
PATCH_FILE="$KLIPPER_DIR_TRSYNC.patch"
TARGET_FILE="$KLIPPER_DIR/klippy/mcu.py"

# Define the patch content inline (clean and Git-friendly)
cat << 'EOF' > "$PATCH_FILE"
diff --git a/klippy/mcu.py b/klippy/mcu.py
index 3f19471..xxxxxxx 100644
--- a/klippy/mcu.py
+++ b/klippy/mcu.py
@@ -xxx,7 +xxx,7 @@ class MCU:
 
-TRSYNC_TIMEOUT = 0.025
+TRSYNC_TIMEOUT = 0.050
EOF

# Only apply if it's not already patched
if grep -q "TRSYNC_TIMEOUT = 0.025" "$TARGET_FILE"; then
    echo "[PATCH] Applying TRSYNC_TIMEOUT patch..."
    git -C "$KLIPPER_DIR" apply "$PATCH_FILE"
else
    echo "[PATCH] Already applied. Skipping."
fi
