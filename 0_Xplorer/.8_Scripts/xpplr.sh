#!/bin/bash

# Extract Z height and file info for resume processing

CONFIG_FILE="/home/biqu/printer_data/config/variables.cfg"
PLR_DIR="/home/biqu/printer_data/gcodes/plr/"
TMP_FILE="/home/biqu/plrtmpA.$$"
TMP_RESUME="/home/biqu/plrresume.$$"

mkdir -p "$PLR_DIR"

# Use params if given, else fallback to variables.cfg
resume_z="$1"
last_file="$2"

if [ -z "$resume_z" ]; then
    resume_z=$(sed -n "s/.*z_pos *= *\([^ ]*\)/\1/p" "$CONFIG_FILE")
fi
if [ -z "$last_file" ]; then
    last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
fi

filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")

# Validate
if [ ! -f "$filepath" ]; then
  echo "Error: G-code file not found: $filepath"
  exit 1
fi
if [ -z "$last_file" ] || [ -z "$resume_z" ]; then
  echo "Error: Missing last_file or resume_z"
  exit 1
fi

cp "$filepath" "$TMP_FILE"

# Slice from the exact ;Z:<resume_z> line onward
awk -v z=";Z:$resume_z" '
  $0 == z { found = 1 }
  found
' "$TMP_FILE" > "$TMP_RESUME"

# Output to final file
cp "$TMP_RESUME" "${PLR_DIR}/${last_file}"

# Clean up
rm -f "$TMP_FILE" "$TMP_RESUME"

# Confirm
if [ ! -s "${PLR_DIR}/${last_file}" ]; then
  echo "Warning: Output is empty. Possibly no matching Z pattern for: ;Z:$resume_z"
else
  echo "Resume G-code saved to: ${PLR_DIR}/${last_file}"
fi
