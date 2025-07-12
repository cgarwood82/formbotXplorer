#!/bin/bash

CONFIG_FILE="/home/biqu/printer_data/config/variables.cfg"
PLR_DIR="/home/biqu/printer_data/gcodes/plr/"
TMP_FILE="/home/biqu/plrtmpA.$$"
TMP_STAGE1="/home/biqu/plrstage1.$$"
TMP_STAGE2="/home/biqu/plrstage2.$$"
TMP_ZLIST="/home/biqu/plrzlist.$$"

mkdir -p "$PLR_DIR"

# Get inputs or fallback to variables.cfg
resume_z="$1"
last_file="$2"

[ -z "$resume_z" ] && resume_z=$(sed -n "s/.*z_pos *= *\([^ ]*\)/\1/p" "$CONFIG_FILE")
[ -z "$last_file" ] && last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")

x_pos=$(sed -n "s/.*x_pos *= *\([^ ]*\)/\1/p" "$CONFIG_FILE")
y_pos=$(sed -n "s/.*y_pos *= *\([^ ]*\)/\1/p" "$CONFIG_FILE")

# Validate
if [ ! -f "$filepath" ]; then
  echo "Error: G-code file not found: $filepath"
  exit 1
fi
if [ -z "$resume_z" ] || [ -z "$last_file" ]; then
  echo "Error: Missing resume_z or last_file"
  exit 1
fi

cp "$filepath" "$TMP_FILE"

# --- Stage 1: Find closest ;Z:<value> and cut from there ---

awk -F ':' '/^;Z:/ { print $2 }' "$TMP_FILE" > "$TMP_ZLIST"

closest_z=$(awk -v target="$resume_z" '
BEGIN { closest = -1; min_diff = 1e9 }
{
    val = $1 + 0
    diff = (val - target)
    if (diff < 0) diff = -diff
    if (diff < min_diff) {
        min_diff = diff
        closest = val
    }
}
END { print closest }
' "$TMP_ZLIST")

echo "Requested Z: $resume_z --> Closest ;Z: $closest_z"

# Stage 1 cut
awk -v z=";Z:$closest_z" '
  $0 == z { found = 1 }
  found
' "$TMP_FILE" > "$TMP_STAGE1"

# --- Stage 2: Find next ;Z: and search only between for best X/Y match ---

awk -v xt="$x_pos" -v yt="$y_pos" '
BEGIN {
  best_line = 0
  best_score = 1e9
  in_layer = 1
}
{
  if ($0 ~ /^;Z:/ && NR != 1) {
    in_layer = 0
  }
  if (in_layer) {
    if ($0 ~ /^G[01]/ && $0 ~ /X/ && $0 ~ /Y/) {
      x = y = 0
      if (match($0, /X[0-9.\-]+/)) x = substr($0, RSTART+1, RLENGTH-1)
      if (match($0, /Y[0-9.\-]+/)) y = substr($0, RSTART+1, RLENGTH-1)
      dx = x - xt
      dy = y - yt
      score = dx*dx + dy*dy
      if (score < best_score) {
        best_score = score
        best_line = NR
      }
    }
  }
  lines[NR] = $0
}
END {
  for (i = best_line; i <= NR; i++) {
    print lines[i]
  }
}
' "$TMP_STAGE1" > "$TMP_STAGE2"

# Save final output
cp "$TMP_STAGE2" "${PLR_DIR}/${last_file}"

# Cleanup
rm -f "$TMP_FILE" "$TMP_STAGE1" "$TMP_STAGE2" "$TMP_ZLIST"

# Confirmation
if [ ! -s "${PLR_DIR}/${last_file}" ]; then
  echo "Warning: Output is empty. Possibly no matching Z or XY in layer"
else
  echo "Resume G-code saved to: ${PLR_DIR}/${last_file}"
fi