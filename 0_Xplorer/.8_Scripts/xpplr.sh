#!/bin/bash

# Extract Z height from variables.cfg and slice G-code from that layer onward,
# while preserving the thumbnail block.

CONFIG_FILE="/home/biqu/printer_data/config/variables.cfg"
PLR_DIR="/home/biqu/printer_data/gcodes/plr/"
TMP_FILE="/home/biqu/plrtmpA.$$"
TMP_THUMB="/home/biqu/plrthumb.$$"
TMP_RESUME="/home/biqu/plrresume.$$"

mkdir -p "$PLR_DIR"

# Get file info
filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
resume_z=$(sed -n "s/.*z_pos *= *\([^ ]*\)/\1/p" "$CONFIG_FILE")

if [ ! -f "$filepath" ]; then
  echo "Error: G-code file not found: $filepath"
  exit 1
fi
if [ -z "$last_file" ] || [ -z "$resume_z" ]; then
  echo "Error: Missing last_file or z_pos"
  exit 1
fi

cp "$filepath" "$TMP_FILE"

# Preserve thumbnail block if it exists
awk '/; THUMBNAIL_BLOCK_START/,/; THUMBNAIL_BLOCK_END/' "$TMP_FILE" > "$TMP_THUMB"

# Slice from the target Z height to the end
Z_PATTERN=$(printf ";Z:%.1f" "$resume_z")
awk -v z="$Z_PATTERN" '
  found { print }
  !found && index($0, z) { found=1; print }
' "$TMP_FILE" > "$TMP_RESUME"

# Concatenate thumbnail + resume portion
cat "$TMP_THUMB" "$TMP_RESUME" > "${PLR_DIR}/${last_file}"

# Clean up
rm -f "$TMP_FILE" "$TMP_THUMB" "$TMP_RESUME"

# Final check
if [ ! -s "${PLR_DIR}/${last_file}" ]; then
  echo "Warning: Output is empty. Possibly no matching Z pattern."
else
  echo "Resume G-code with thumbnail saved to: ${PLR_DIR}/${last_file}"
fi
