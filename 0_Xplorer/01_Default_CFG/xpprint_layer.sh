#!/bin/bash

# Paths
CONFIG_FILE="/home/biqu/printer_data/config/variables.cfg"

# Extract file path and name from variables.cfg
filepath=$(sed -n "s/.*filepath *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")
last_file=$(sed -n "s/.*last_file *= *'\([^']*\)'.*/\1/p" "$CONFIG_FILE")

# Validate G-code file
if [ ! -f "$filepath" ]; then
  echo "Error: G-code file not found at $filepath"
  exit 1
fi

# Extract precise lines
first_layer_height=$(grep -E '^;[ ]*first_layer_height[ ]*=' "$filepath" | head -1 | sed -n 's/^;[ ]*first_layer_height[ ]*=[ ]*\(.*\)/\1/p')
layer_height=$(grep -E '^;[ ]*layer_height[ ]*=' "$filepath" | head -1 | sed -n 's/^;[ ]*layer_height[ ]*=[ ]*\(.*\)/\1/p')

# Validate extracted values
if [ -z "$first_layer_height" ] || [ -z "$layer_height" ]; then
  echo "Error: Failed to extract one or both layer height values."
  exit 1
fi

# Remove any previous entries
sed -i '/^first_layer_height *=/d' "$CONFIG_FILE"
sed -i '/^layer_height *=/d' "$CONFIG_FILE"

# Append new values
echo "first_layer_height = $first_layer_height" >> "$CONFIG_FILE"
echo "layer_height = $layer_height" >> "$CONFIG_FILE"

echo "Extracted from: $last_file"
echo "Saved to variables.cfg:"
echo "  first_layer_height = $first_layer_height"
echo "  layer_height = $layer_height"
